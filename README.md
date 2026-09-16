# fluencetools

Tools for site and inverter work.

## EPC M10 terminal HMI

`bin/epc-m10-hmi` is a **read-only** full-screen terminal HMI for [EPC Power M10](https://www.epcpower.com/products/m-system) inverters. It is implemented in **pure bash** (no Python, no `paho-mqtt`, no virtualenv).

It opens an MQTT 3.1.1 session over bash `/dev/tcp`, subscribes to Sparkplug B, watches `NBIRTH` / `DBIRTH` (and death) to build a list of M10s, and opens the operator screen for the inverter you select.

Other device types on the same broker are ignored (for example a BMS on the demo fleet).

It never publishes. There is no MQTT PUBLISH path and no last will; it does not send Sparkplug `NCMD` / `DCMD`, and it does not act as a primary host (`STATE` is ignored). Nothing in the HMI can command an M10 or any other device on the broker.

An M10 is recognized from its Sparkplug path or birth tags (device / node / model / type containing `M10`).

The M10’s native control interface is Modbus TCP. Sparkplug B usually comes from a gateway in front of it, so metric names are taken from birth messages (with aliases honored on later data) rather than a hardcoded register map.

### Run

Requires bash 4+ with `/dev/tcp` (bash’s built-in TCP). No packages to install for the demo; live mode talks to the broker with `/dev/tcp` only (no mosquitto client).

```bash
# preview the selector and screen with three simulated M10s (+ one filtered BMS)
./bin/epc-m10-hmi --demo

# live broker — starts on the inverter list
./bin/epc-m10-hmi --host 10.0.0.20 --port 1883

# skip the list and open one device
./bin/epc-m10-hmi --host 10.0.0.20 --port 1883 --device M10-A
```

Optional: `--group`, `--node`, `--username`, `--password`, `--client-id`, `--topic`.

Same values can be set with env vars: `M10_MQTT_HOST`, `M10_MQTT_PORT`, `M10_MQTT_USERNAME`, `M10_MQTT_PASSWORD`, `M10_MQTT_CLIENT_ID`, `M10_SPARKPLUG_GROUP`, `M10_SPARKPLUG_NODE`, `M10_SPARKPLUG_DEVICE`.

Default subscribe topic is `spBv1.0/#`. Tags go stale after about 5 seconds without an update.

### Keys

On the list: `↑` `↓` or `j` `k` move, `Enter` opens, `q` quits.

On the HMI: `Esc` back to the list, `q` quits.

### Layout

- Selector: device, node, group, online / stale / offline (M10 only; UI shows **READ ONLY**)
- HMI: connection badge, KPIs, DC / battery, thermal / state, alarms

### Notes

The previous Python / `paho-mqtt` implementation was removed. MQTT QoS is subscribe QoS 0; PUBLISH packets with QoS &gt; 0 are parsed for topic/payload but not acknowledged. The Sparkplug decoder covers the focused Metric types used by the HMI (int/float/double/bool/string); datasets, templates, and bytes are skipped.
