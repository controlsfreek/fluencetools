"""MQTT client, CLI, and live HMI loop."""

from __future__ import annotations

import argparse
import fcntl
import os
import select
import sys
import termios
import time
import tty

import paho.mqtt.client as mqtt

from .screen import DeviceState, Screen, identify_m10
from .sparkplug import decode_payload, parse_topic

STALE_AFTER = 5.0
SUBSCRIBE_ONLY_TYPES = {"NBIRTH", "DBIRTH", "NDATA", "DDATA", "NDEATH", "DDEATH", "STATE"}


class ReadOnlyMqttClient(mqtt.Client):
    """MQTT client that cannot publish or set a last will."""

    def publish(self, *args, **kwargs):
        raise RuntimeError("epc-m10-hmi is subscribe-only; MQTT publish is disabled")

    def will_set(self, *args, **kwargs):
        raise RuntimeError("epc-m10-hmi is subscribe-only; MQTT last-will is disabled")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="epc-m10-hmi",
        description="Read-only terminal HMI for EPC M10 inverters (Sparkplug B over MQTT). Subscribes only; never publishes.",
    )
    p.add_argument("--host", default=os.environ.get("M10_MQTT_HOST"), help="MQTT broker IP or hostname")
    p.add_argument("--port", type=int, default=int(os.environ.get("M10_MQTT_PORT", "1883")), help="MQTT broker port (default 1883)")
    p.add_argument("--group", default=os.environ.get("M10_SPARKPLUG_GROUP"), help="Sparkplug group ID (omit to accept any)")
    p.add_argument("--node", default=os.environ.get("M10_SPARKPLUG_NODE"), help="Sparkplug edge node ID (omit to accept any)")
    p.add_argument("--device", default=os.environ.get("M10_SPARKPLUG_DEVICE"), help="Open this M10 directly, skipping the list")
    p.add_argument("--username", default=os.environ.get("M10_MQTT_USERNAME"), help="MQTT username")
    p.add_argument("--password", default=os.environ.get("M10_MQTT_PASSWORD"), help="MQTT password")
    p.add_argument("--client-id", default=os.environ.get("M10_MQTT_CLIENT_ID", "fluencetools-m10-hmi"), help="MQTT client id")
    p.add_argument("--topic", default="spBv1.0/#", help="Subscribe topic (default spBv1.0/#)")
    p.add_argument("--demo", action="store_true", help="Simulate several M10s (and one non-M10) without a broker")
    return p


class App:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.screen = Screen()
        self.devices: dict[str, DeviceState] = {}
        self.selected: str | None = None
        self.cursor = 0
        self.mode = "detail" if args.device else "list"
        self.connected = False
        self.error: str | None = None
        self.running = True
        self.client: mqtt.Client | None = None

    def wanted(self, topic) -> bool:
        if self.args.group and topic.group_id != self.args.group:
            return False
        if self.args.node and topic.edge_node_id != self.args.node:
            return False
        return True

    def device_for(self, topic) -> DeviceState:
        key = topic.key
        if key not in self.devices:
            self.devices[key] = DeviceState(
                key=key,
                group=topic.group_id,
                node=topic.edge_node_id,
                device=topic.device_id,
            )
        return self.devices[key]

    def inverters(self) -> list[DeviceState]:
        found = [d for d in self.devices.values() if d.is_m10]
        found.sort(key=lambda d: ((d.device or d.node).lower(), d.key))
        return found

    def _classify(self, dev: DeviceState) -> None:
        dev.is_m10 = identify_m10(dev)
        if (
            self.mode == "detail"
            and self.selected is None
            and self.args.device
            and dev.is_m10
            and (dev.device or "") == self.args.device
        ):
            self.selected = dev.key

    def on_connect(self, client, userdata, flags, reason_code, properties=None) -> None:
        rc = int(getattr(reason_code, "value", reason_code))
        if rc == 0:
            self.connected = True
            self.error = None
            client.subscribe(self.args.topic, qos=0)
        else:
            self.connected = False
            self.error = f"MQTT connect failed (rc={rc})"

    def on_disconnect(self, client, userdata, flags, reason_code, properties=None) -> None:
        self.connected = False
        if not self.error:
            self.error = "broker disconnected"

    def on_message(self, client, userdata, msg) -> None:
        topic = parse_topic(msg.topic)
        if topic is None or not self.wanted(topic):
            return
        if topic.message_type not in SUBSCRIBE_ONLY_TYPES or topic.kind == "cmd":
            return
        now = time.time()
        if topic.kind == "state":
            return
        dev = self.device_for(topic)
        if topic.kind == "death":
            dev.online = False
            dev.last_msg = now
            return
        try:
            payload = decode_payload(msg.payload)
        except Exception as exc:
            self.error = f"decode: {exc}"
            return
        if topic.kind == "birth":
            dev.online = True
            dev.born = True
            if topic.message_type == "DBIRTH" or topic.device_id:
                dev.aliases.clear()
                dev.metrics.clear()
        elif topic.kind == "data":
            dev.online = True
        dev.last_msg = now
        if payload.seq is not None:
            dev.seq = payload.seq
        for metric in payload.metrics:
            name = dev.resolve_name(metric.alias, metric.name)
            if not name or metric.is_null:
                continue
            ts = (metric.timestamp or payload.timestamp or int(now * 1000)) / 1000.0
            if ts > 10_000_000_000:
                ts = ts / 1000.0
            if ts > 10_000_000_000:
                ts = now
            if ts > 1_000_000_000_000:
                ts = ts / 1000.0
            dev.upsert(name, metric.value, ts if ts > 1_000_000_000 else now)
        if topic.kind == "birth" or not dev.is_m10:
            self._classify(dev)

    def start_mqtt(self) -> None:
        self.client = ReadOnlyMqttClient(
            mqtt.CallbackAPIVersion.VERSION2,
            client_id=self.args.client_id,
            protocol=mqtt.MQTTv311,
            clean_session=True,
        )
        if self.args.username:
            self.client.username_pw_set(self.args.username, self.args.password or "")
        self.client.on_connect = self.on_connect
        self.client.on_disconnect = self.on_disconnect
        self.client.on_message = self.on_message
        try:
            self.client.connect_async(self.args.host, self.args.port, keepalive=30)
            self.client.loop_start()
        except Exception as exc:
            self.error = str(exc)

    def stop_mqtt(self) -> None:
        if self.client is not None:
            try:
                self.client.loop_stop()
                self.client.disconnect()
            except Exception:
                pass

    def load_demo(self, now: float) -> None:
        fleet = [
            ("Fluence/EDGE-01/M10-A", "Fluence", "EDGE-01", "M10-A", 0.00, True),
            ("Fluence/EDGE-01/M10-B", "Fluence", "EDGE-01", "M10-B", 0.03, True),
            ("Fluence/EDGE-02/M10-C", "Fluence", "EDGE-02", "M10-C", -0.02, True),
            ("Fluence/EDGE-01/BMS-1", "Fluence", "EDGE-01", "BMS-1", 0.00, False),
        ]
        for key, group, node, device, bias, is_m10 in fleet:
            dev = self.devices.get(key)
            if dev is None:
                dev = DeviceState(key=key, group=group, node=node, device=device)
                self.devices[key] = dev
            dev.online = True
            dev.born = True
            dev.last_msg = now
            dev.seq = int(now + bias * 10) % 256
            if not is_m10:
                dev.upsert("BMS/SOC", 81.0, now)
                dev.upsert("BMS/Voltage", 1320.0, now)
                dev.is_m10 = False
                continue
            phase = ((now + bias * 8) % 8.0) / 8.0
            sweep = 0.04 * (phase - 0.5)
            samples = {
                "Properties/Model": "EPC M10",
                "AC/ActivePower": 412.5 * (1 + sweep + bias),
                "AC/VoltageAB": 480.2 + bias,
                "AC/VoltageBC": 479.6,
                "AC/VoltageCA": 480.8,
                "AC/CurrentA": 498.1 * (1 + sweep),
                "AC/Frequency": 60.012,
                "DC/Voltage1": 1184.0 + bias * 10,
                "DC/Voltage2": 1179.5,
                "DC/Current1": 178.4 * (1 + sweep),
                "DC/Power": 418.0 * (1 + sweep + bias),
                "BESS/SOC": 67.4 + bias * 20,
                "Thermal/Heatsink": 41.2 + abs(bias) * 8,
                "Thermal/Cabinet": 32.8,
                "Status/State": "GRID_FOLLOWING",
                "Status/Fault": False,
            }
            for name, value in samples.items():
                dev.upsert(name, value, now)
            self._classify(dev)

    def run(self) -> int:
        if not self.args.demo and not self.args.host:
            print("Need --host (or M10_MQTT_HOST), or pass --demo to preview the screen.", file=sys.stderr)
            return 2

        self.screen.enter()
        fd = sys.stdin.fileno()
        old = None
        if sys.stdin.isatty():
            old = termios.tcgetattr(fd)
            tty.setcbreak(fd)
        try:
            if not self.args.demo:
                self.start_mqtt()
            while self.running:
                now = time.time()
                if self.args.demo:
                    self.load_demo(now)
                fleet = self.inverters()
                if fleet:
                    self.cursor = max(0, min(self.cursor, len(fleet) - 1))
                else:
                    self.cursor = 0
                self.screen.draw(
                    host=self.args.host or "demo",
                    port=self.args.port,
                    connected=self.connected or self.args.demo,
                    error=None if self.args.demo else self.error,
                    devices=self.devices,
                    selected=self.selected,
                    stale_after=STALE_AFTER,
                    now=now,
                    demo=self.args.demo,
                    mode=self.mode,
                    inverters=fleet,
                    cursor=self.cursor,
                )
                self._poll_keys(0.2)
        except KeyboardInterrupt:
            pass
        finally:
            if old is not None:
                termios.tcsetattr(fd, termios.TCSADRAIN, old)
            self.stop_mqtt()
            self.screen.leave()
        return 0

    def _open_cursor(self) -> None:
        fleet = self.inverters()
        if not fleet:
            return
        self.cursor = max(0, min(self.cursor, len(fleet) - 1))
        self.selected = fleet[self.cursor].key
        self.mode = "detail"

    def _read_key(self, fd: int, timeout: float) -> str | None:
        """Read one key. Arrow sequences are decoded to j/k; bare ESC is 'esc'."""
        r, _, _ = select.select([fd], [], [], timeout)
        if not r:
            return None
        data = os.read(fd, 1)
        if not data:
            return None
        if data != b"\x1b":
            return data.decode("utf-8", errors="ignore") or None

        # The rest of CSI/SS3 (e.g. [A, OA) is often already in the kernel
        # buffer. Drain it unbuffered so select() and read() stay in sync —
        # sys.stdin.read() was swallowing [A and making arrows look like ESC.
        seq = data
        select.select([fd], [], [], 0.08)
        flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
        try:
            while True:
                chunk = os.read(fd, 32)
                if not chunk:
                    break
                seq += chunk
        except BlockingIOError:
            pass
        finally:
            fcntl.fcntl(fd, fcntl.F_SETFL, flags)

        if seq == b"\x1b":
            return "esc"
        if seq.endswith(b"A") or seq in {b"\x1b[A", b"\x1bOA"}:
            return "k"
        if seq.endswith(b"B") or seq in {b"\x1b[B", b"\x1bOB"}:
            return "j"
        return None

    def _poll_keys(self, timeout: float) -> None:
        fd = sys.stdin.fileno()
        end = time.time() + timeout
        while time.time() < end:
            ch = self._read_key(fd, max(0.0, end - time.time()))
            if ch is None:
                return
            if ch == "esc":
                if self.mode == "detail":
                    self.mode = "list"
                return
            if ch in {"q", "Q", "\x03"}:
                self.running = False
                return
            if self.mode == "list":
                if ch in {"j", "J"}:
                    if self.inverters():
                        self.cursor = min(self.cursor + 1, len(self.inverters()) - 1)
                elif ch in {"k", "K"}:
                    self.cursor = max(0, self.cursor - 1)
                elif ch in {"\r", "\n", " "}:
                    self._open_cursor()


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return App(args).run()
