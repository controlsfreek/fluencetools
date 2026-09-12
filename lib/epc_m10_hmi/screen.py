"""ANSI terminal HMI for the EPC M10 inverter."""

from __future__ import annotations

import re
import shutil
import time
from dataclasses import dataclass, field
from typing import Any

RESET = "\x1b[0m"
BOLD = "\x1b[1m"
DIM = "\x1b[2m"
HIDE = "\x1b[?25l"
SHOW = "\x1b[?25h"
ALT_ON = "\x1b[?1049h"
ALT_OFF = "\x1b[?1049l"
HOME = "\x1b[H"
CLEAR = "\x1b[2J"
CLEAR_DOWN = "\x1b[J"

# Industrial palette (256-color)
C_FRAME = "\x1b[38;5;24m"
C_TITLE = "\x1b[38;5;159m"
C_LABEL = "\x1b[38;5;109m"
C_VALUE = "\x1b[38;5;230m"
C_UNIT = "\x1b[38;5;66m"
C_OK = "\x1b[38;5;84m"
C_WARN = "\x1b[38;5;220m"
C_BAD = "\x1b[38;5;203m"
C_MUTE = "\x1b[38;5;59m"
C_AMBER = "\x1b[38;5;178m"
C_HEAD = "\x1b[38;5;81m"


def _norm(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", name.lower()).strip()


def classify(name: str) -> str | None:
    n = _norm(name)
    if not n:
        return None
    # Order matters: more specific first.
    if re.search(r"\b(fault|trip|alarm|error|warn)", n):
        return "fault"
    if re.search(r"\b(state|status|mode|run|online|enabled)\b", n):
        return "state"
    if re.search(r"\b(soc|state of charge)\b", n):
        return "soc"
    if re.search(r"\b(temp|temperature|heatsink|coolant|igbt)\b", n):
        return "temp"
    if re.search(r"\b(freq|frequency|hertz|\bhz\b)\b", n):
        return "freq"
    if re.search(r"\b(dc).*(volt|vdc)|\bvdc\b|dc voltage", n):
        return "vdc"
    if re.search(r"\b(dc).*(curr|amp|idc)|\bidc\b|dc current", n):
        return "idc"
    if re.search(r"\b(dc).*(power|kw|watt)|\bpdc\b|dc power", n):
        return "pdc"
    if re.search(r"\b(ac).*(volt|vac)|volt(age)?|vab|vbc|vca|van|vbn|vcn|\bvac\b", n):
        return "vac"
    if re.search(r"\b(ac).*(curr|amp)|current|\biac\b|\bamps?\b", n):
        return "iac"
    if re.search(r"\b(active|real|output|ac)? ?power\b|\bpac\b|\bkw\b|\bkwe\b", n):
        return "pac"
    return None


def infer_unit(slot: str, name: str, value: Any) -> str:
    n = _norm(name)
    if "kw" in n:
        return "kW"
    if "kvar" in n:
        return "kVAr"
    if "kva" in n:
        return "kVA"
    if slot in {"vac", "vdc"} or "volt" in n:
        return "V"
    if slot in {"iac", "idc"} or "curr" in n or "amp" in n:
        return "A"
    if slot == "freq" or "hz" in n:
        return "Hz"
    if slot == "temp" or "temp" in n:
        return "°C"
    if slot == "soc":
        return "%"
    if slot in {"pac", "pdc"}:
        return "kW"
    if isinstance(value, bool):
        return ""
    return ""


def fmt_value(value: Any) -> str:
    if value is None:
        return "—"
    if isinstance(value, bool):
        return "ON" if value else "OFF"
    if isinstance(value, float):
        av = abs(value)
        if av >= 1000:
            return f"{value:,.1f}"
        if av >= 100:
            return f"{value:.1f}"
        if av >= 10:
            return f"{value:.2f}"
        return f"{value:.3f}"
    if isinstance(value, int):
        return f"{value:,}"
    return str(value)



_M10_RE = re.compile(r"m[\s_-]*10", re.I)
_TYPE_HINT_RE = re.compile(
    r"(device.?type|model|product|hw.?type|inverter.?type|manufacturer|vendor|devicetype)",
    re.I,
)


def identify_m10(dev: "DeviceState") -> bool:
    """True when Sparkplug identity or birth tags look like an EPC M10."""
    blob = " ".join(x for x in (dev.group, dev.node, dev.device or "") if x)
    if _M10_RE.search(blob):
        return True
    for m in dev.metrics.values():
        name = m.name or ""
        val = "" if m.value is None else str(m.value)
        if _M10_RE.search(name) or _M10_RE.search(val):
            return True
        if _TYPE_HINT_RE.search(name) and _M10_RE.search(val):
            return True
    return False


@dataclass
class LiveMetric:
    name: str
    value: Any
    unit: str
    updated: float
    slot: str | None = None


@dataclass
class DeviceState:
    key: str
    group: str
    node: str
    device: str | None
    online: bool = False
    last_msg: float = 0.0
    seq: int | None = None
    aliases: dict[int, str] = field(default_factory=dict)
    metrics: dict[str, LiveMetric] = field(default_factory=dict)
    born: bool = False
    is_m10: bool = False

    def resolve_name(self, alias: int | None, name: str | None) -> str | None:
        if name:
            if alias is not None:
                self.aliases[alias] = name
            return name
        if alias is not None:
            return self.aliases.get(alias)
        return None

    def upsert(self, name: str, value: Any, ts: float) -> None:
        slot = classify(name)
        unit = infer_unit(slot or "", name, value)
        self.metrics[name] = LiveMetric(
            name=name, value=value, unit=unit, updated=ts, slot=slot
        )


class Screen:
    def __init__(self) -> None:
        self.started = False

    def enter(self) -> None:
        if not self.started:
            print(f"{ALT_ON}{HIDE}{CLEAR}", end="", flush=True)
            self.started = True

    def leave(self) -> None:
        if self.started:
            print(f"{ALT_OFF}{SHOW}{RESET}", end="", flush=True)
            self.started = False

    def draw(
        self,
        *,
        host: str,
        port: int,
        connected: bool,
        error: str | None,
        devices: dict[str, DeviceState],
        selected: str | None,
        stale_after: float,
        now: float,
        demo: bool,
        mode: str = "detail",
        inverters: list[DeviceState] | None = None,
        cursor: int = 0,
    ) -> None:
        cols, rows = shutil.get_terminal_size(fallback=(100, 32))
        cols = max(72, cols)
        rows = max(24, rows)

        if mode == "list":
            self._draw_list(
                cols=cols,
                rows=rows,
                host=host,
                port=port,
                connected=connected,
                error=error,
                inverters=inverters,
                cursor=cursor,
                stale_after=stale_after,
                now=now,
                demo=demo,
            )
            return

        device = devices.get(selected) if selected else None

        lines: list[str] = []
        lines.append(self._header(cols, host, port, connected, error, demo, now))
        lines.append(self._identity(cols, device, now, stale_after))
        lines.append("")
        lines.extend(self._kpi_row(cols, device, now, stale_after))
        lines.append("")
        lines.extend(self._panels(cols, device, now, stale_after))
        lines.append("")
        lines.extend(self._alarms_and_feed(cols, rows, device, devices, now, stale_after, lines))
        footer = self._footer(cols, "Esc list   ·   q quit   ·   tags from DBIRTH/DDATA")
        # pad / trim to fill the screen
        body = lines[: rows - 2]
        while len(body) < rows - 2:
            body.append("")
        body.append(footer)
        frame = HOME + "\n".join(self._clip(line, cols) for line in body) + CLEAR_DOWN
        print(frame, end="", flush=True)

    def _clip(self, line: str, cols: int) -> str:
        return self._fit(line, cols)

    def _vis(self, text: str) -> int:
        n = 0
        i = 0
        while i < len(text):
            if text[i] == "\x1b":
                end = text.find("m", i)
                i = end + 1 if end != -1 else i + 1
                continue
            n += 1
            i += 1
        return n

    def _fit(self, text: str, width: int) -> str:
        """Clip or pad to exactly `width` visible columns, ANSI-safe."""
        out: list[str] = []
        visible = 0
        i = 0
        while i < len(text) and visible < width:
            if text[i] == "\x1b":
                end = text.find("m", i)
                if end == -1:
                    break
                out.append(text[i : end + 1])
                i = end + 1
                continue
            out.append(text[i])
            visible += 1
            i += 1
        if visible < width:
            out.append(" " * (width - visible))
        return "".join(out) + RESET

    def _box_line(self, width: int, inner: str) -> str:
        return f"{C_FRAME}│{RESET}{self._fit(inner, width - 2)}{C_FRAME}│{RESET}"

    def _box_top(self, width: int) -> str:
        return f"{C_FRAME}┌{'─' * (width - 2)}┐{RESET}"

    def _box_bot(self, width: int) -> str:
        return f"{C_FRAME}└{'─' * (width - 2)}┘{RESET}"

    def _header(self, cols: int, host: str, port: int, connected: bool, error: str | None, demo: bool, now: float) -> str:
        clock = time.strftime("%I:%M:%S %p")
        if demo:
            badge = f"{C_AMBER}{BOLD} DEMO {RESET}"
        elif error:
            badge = f"{C_BAD}{BOLD} FAULT {RESET}"
        elif connected:
            badge = f"{C_OK}{BOLD} LIVE {RESET}"
        else:
            badge = f"{C_WARN}{BOLD} WAIT {RESET}"
        title = f"{C_TITLE}{BOLD}  EPC M10  {RESET}{C_HEAD}INVERTER HMI{RESET}  {C_MUTE}READ ONLY{RESET}"
        broker = f"{C_MUTE}mqtt://{host}:{port}{RESET}"
        right = f"{broker}   {badge}  {C_VALUE}{clock}{RESET}"
        return self._spread(title, right, cols)

    def _identity(self, cols: int, device: DeviceState | None, now: float, stale_after: float) -> str:
        bar = f"{C_FRAME}{'─' * cols}{RESET}"
        if not device:
            return f"{bar}\n{C_MUTE}  Waiting for Sparkplug NBIRTH / DBIRTH …{RESET}"
        age = now - device.last_msg if device.last_msg else None
        stale = age is not None and age > stale_after
        if not device.online:
            health = f"{C_BAD}OFFLINE{RESET}"
        elif stale:
            health = f"{C_WARN}STALE {age:.0f}s{RESET}"
        else:
            health = f"{C_OK}ONLINE{RESET}"
        path = f"{device.group} / {device.node}"
        if device.device:
            path += f" / {device.device}"
        seq = f"seq {device.seq}" if device.seq is not None else "seq —"
        left = f"{C_LABEL}  DEVICE  {RESET}{C_VALUE}{path}{RESET}   {health}"
        right = f"{C_MUTE}{seq}   {len(device.metrics)} tags{RESET}"
        return f"{bar}\n{self._spread(left, right, cols)}"

    def _kpi_row(self, cols: int, device: DeviceState | None, now: float, stale_after: float) -> list[str]:
        slots = [
            ("AC POWER", "pac", "kW"),
            ("AC VOLTAGE", "vac", "V"),
            ("AC CURRENT", "iac", "A"),
            ("FREQUENCY", "freq", "Hz"),
            ("DC VOLTAGE", "vdc", "V"),
        ]
        n = len(slots)
        gap = 1
        width = max(14, (cols - gap * (n - 1)) // n)
        tiles = [
            self._tile(width, label, self._pick(device, key), fallback_unit, now, stale_after)
            for label, key, fallback_unit in slots
        ]
        rows = list(zip(*tiles))
        out = []
        for i, parts in enumerate(rows):
            out.append((" " * gap).join(parts))
        return out

    def _tile(self, width: int, label: str, metric: LiveMetric | None, unit: str, now: float, stale_after: float) -> list[str]:
        w = width
        top = f"{C_FRAME}┌{'─' * (w - 2)}┐{RESET}"
        bot = f"{C_FRAME}└{'─' * (w - 2)}┘{RESET}"
        lab = f"{C_LABEL}{label}{RESET}"
        mid1 = f"{C_FRAME}│{RESET}{self._pad(lab, w - 2)}{C_FRAME}│{RESET}"
        if metric is None:
            val = f"{C_MUTE}{'—':>{w - 8}}{RESET} {C_UNIT}{unit}{RESET}"
        else:
            stale = (now - metric.updated) > stale_after
            color = C_MUTE if stale else C_VALUE
            shown = fmt_value(metric.value)
            u = metric.unit or unit
            val = f"{color}{BOLD}{shown:>{max(6, w - 8 - len(u))}}{RESET} {C_UNIT}{u}{RESET}"
        mid2 = f"{C_FRAME}│{RESET}{self._pad(val, w - 2)}{C_FRAME}│{RESET}"
        return [top, mid1, mid2, bot]

    def _panels(self, cols: int, device: DeviceState | None, now: float, stale_after: float) -> list[str]:
        gap = 1
        left_w = max(28, (cols - gap) // 2)
        right_w = cols - left_w - gap
        dc = self._list_panel(left_w, "DC / BATTERY", self._metrics_in(device, {"pdc", "vdc", "idc", "soc"}), now, stale_after)
        th = self._list_panel(right_w, "THERMAL / STATE", self._metrics_in(device, {"temp", "state"}), now, stale_after)
        h = max(len(dc), len(th))
        while len(dc) < h:
            dc.append(self._box_line(left_w, ""))
        while len(th) < h:
            th.append(self._box_line(right_w, ""))
        dc[-1] = self._box_bot(left_w)
        th[-1] = self._box_bot(right_w)
        return [f"{a}{' ' * gap}{b}" for a, b in zip(dc, th)]

    def _list_panel(self, width: int, title: str, metrics: list[LiveMetric], now: float, stale_after: float) -> list[str]:
        value_w = 10
        unit_w = 4
        name_w = max(8, width - 2 - value_w - unit_w - 2)
        lines = [
            self._box_top(width),
            self._box_line(width, f" {C_HEAD}{BOLD}{title}{RESET}"),
            self._box_line(width, f" {C_FRAME}{'─' * max(0, width - 4)}{RESET}"),
        ]
        rows = metrics[:8] or [None]
        for m in rows:
            if m is None:
                inner = f" {C_MUTE}no tags yet{RESET}"
            else:
                stale = (now - m.updated) > stale_after
                color = C_MUTE if stale else C_VALUE
                name = self._fit(f"{C_LABEL}{m.name}{RESET}", name_w)
                value = self._fit(f"{color}{fmt_value(m.value)}{RESET}", value_w)
                unit = self._fit(f"{C_UNIT}{m.unit}{RESET}", unit_w)
                inner = f" {name} {value} {unit}"
                # leading space + fields + two gaps = 1+name_w+1+value_w+1+unit_w
                # _box_line will fit to width-2, so keep inner from overflowing
            lines.append(self._box_line(width, inner))
        return lines

    def _alarms_and_feed(
        self,
        cols: int,
        rows: int,
        device: DeviceState | None,
        devices: dict[str, DeviceState],
        now: float,
        stale_after: float,
        used: list[str],
    ) -> list[str]:
        faults = self._metrics_in(device, {"fault"})
        others = []
        if device:
            others = [m for m in device.metrics.values() if m.slot is None]
            others.sort(key=lambda m: m.name.lower())
        alarm_txt = "no active fault tags" if not faults else ", ".join(
            f"{m.name}={fmt_value(m.value)}" for m in faults[:4]
        )
        color = C_OK if not faults else C_BAD
        line1 = f"{C_LABEL}  ALARMS  {RESET}{color}{alarm_txt}{RESET}"
        extra = f"{C_MUTE}  nodes seen: {', '.join(d.key for d in devices.values()) or '—'}{RESET}"
        feed = []
        if others:
            feed.append(f"{C_LABEL}  OTHER TAGS{RESET}")
            for m in others[:6]:
                stale = (now - m.updated) > stale_after
                color = C_MUTE if stale else C_VALUE
                feed.append(f"    {C_LABEL}{m.name:<28}{RESET} {color}{fmt_value(m.value):>10}{RESET} {C_UNIT}{m.unit}{RESET}")
        return [line1, extra, ""] + feed

    def _footer(self, cols: int, help_txt: str) -> str:
        return f"{C_FRAME}{'─' * cols}{RESET}\n{C_MUTE}  {help_txt}{RESET}"

    def _draw_list(
        self,
        *,
        cols: int,
        rows: int,
        host: str,
        port: int,
        connected: bool,
        error: str | None,
        inverters: list[DeviceState] | None,
        cursor: int,
        stale_after: float,
        now: float,
        demo: bool,
    ) -> None:
        inverters = inverters or []
        online = sum(1 for d in inverters if d.online and (now - d.last_msg) <= stale_after)
        stale = sum(1 for d in inverters if d.online and (now - d.last_msg) > stale_after)
        off = sum(1 for d in inverters if not d.online)
        lines: list[str] = [
            self._header(cols, host, port, connected, error, demo, now),
            f"{C_FRAME}{'─' * cols}{RESET}",
            self._spread(
                f"{C_LABEL}  SELECT INVERTER{RESET}  {C_MUTE}EPC M10 only · listening for DBIRTH{RESET}",
                f"{C_OK}{online} online{RESET}  {C_WARN}{stale} stale{RESET}  {C_MUTE}{off} off{RESET}  {C_VALUE}{len(inverters)} total{RESET}",
                cols,
            ),
            "",
        ]
        box_h = max(6, rows - 8)
        inner_rows = box_h - 3  # top, header, bot
        lines.append(self._box_top(cols))
        hdr = (
            f" {C_MUTE}{'':2}  {'DEVICE':<22}  {'NODE':<16}  {'GROUP':<12}  {'STATE':<10}  TAGS{RESET}"
        )
        lines.append(self._box_line(cols, hdr))
        if not inverters:
            wait = "  waiting for M10 birth messages …"
            if not connected and not demo:
                wait = "  connecting to broker …"
            lines.append(self._box_line(cols, f"{C_MUTE}{wait}{RESET}"))
            for _ in range(inner_rows - 1):
                lines.append(self._box_line(cols, ""))
        else:
            start = 0
            if cursor >= inner_rows:
                start = cursor - inner_rows + 1
            view = inverters[start : start + inner_rows]
            for offset, dev in enumerate(view):
                idx = start + offset
                age = now - dev.last_msg if dev.last_msg else None
                if not dev.online:
                    state, sc = "OFFLINE", C_BAD
                elif age is not None and age > stale_after:
                    state, sc = f"STALE {age:.0f}s", C_WARN
                else:
                    state, sc = "ONLINE", C_OK
                mark = f"{C_AMBER}{BOLD}▶{RESET}" if idx == cursor else " "
                name = dev.device or dev.node
                row = (
                    f" {mark} {C_VALUE}{name:<22}{RESET}  "
                    f"{C_LABEL}{dev.node:<16}{RESET}  "
                    f"{C_MUTE}{dev.group:<12}{RESET}  "
                    f"{sc}{state:<10}{RESET}  {C_MUTE}{len(dev.metrics)}{RESET}"
                )
                if idx == cursor:
                    row = f"{C_FRAME}{row}{RESET}"
                lines.append(self._box_line(cols, row))
            for _ in range(inner_rows - len(view)):
                lines.append(self._box_line(cols, ""))
        lines.append(self._box_bot(cols))
        footer = self._footer(cols, "↑↓ / j k  move   ·   Enter  open   ·   Esc back   ·   q  quit")
        body = lines[: rows - 2]
        while len(body) < rows - 2:
            body.append("")
        body.append(footer)
        frame = HOME + "\n".join(self._clip(line, cols) for line in body) + CLEAR_DOWN
        print(frame, end="", flush=True)

    def _pick(self, device: DeviceState | None, slot: str) -> LiveMetric | None:
        if not device:
            return None
        hits = [m for m in device.metrics.values() if m.slot == slot]
        if not hits:
            return None
        # Prefer a "total" / "ac" flavored name when several match.
        def score(m: LiveMetric) -> tuple[int, str]:
            n = _norm(m.name)
            s = 0
            if "total" in n or "sum" in n:
                s -= 2
            if "avg" in n or "average" in n:
                s -= 1
            if slot.startswith("v") and re.search(r"\b(ab|bc|l1|a)\b", n):
                s -= 1
            return (s, m.name)

        hits.sort(key=score)
        return hits[0]

    def _metrics_in(self, device: DeviceState | None, slots: set[str]) -> list[LiveMetric]:
        if not device:
            return []
        hits = [m for m in device.metrics.values() if m.slot in slots]
        hits.sort(key=lambda m: (m.slot or "", m.name.lower()))
        return hits

    def _spread(self, left: str, right: str, cols: int) -> str:
        pad = max(1, cols - self._vis(left) - self._vis(right))
        return self._fit(left + (" " * pad) + right, cols)

    def _pad(self, s: str, width: int) -> str:
        return self._fit(s, width)

    def _spaces(self, n: int) -> str:
        return " " * max(0, n)
