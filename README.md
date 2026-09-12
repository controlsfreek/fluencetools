# fluencetools

Tools for site and inverter work.

## EPC M10 terminal HMI

`bin/epc-m10-hmi` is a **read-only** full-screen terminal HMI for [EPC Power M10](https://www.epcpower.com/products/m-system) inverters. It subscribes to Sparkplug B on an MQTT broker, watches `NBIRTH` / `DBIRTH` (and death) to build a list of M10s, and opens the operator screen for the inverter you select.

Other device types on the same broker are ignored.

It never publishes. MQTT publish and last-will are disabled in the client, it does not send Sparkplug `NCMD` / `DCMD`, and it does not act as a primary host (`STATE`). Nothing in the HMI can command an M10 or any other device on the broker.

An M10 is recognized from its Sparkplug path or birth tags (device / node / model / type containing `M10`).

The M10’s native control interface is Modbus TCP. Sparkplug B usually comes from a gateway in front of it, so metric names are taken from birth messages (with aliases honored on later data) rather than a hardcoded register map.

### Run

Needs Python 3.11+ (3.14 is fine). The script creates a local `.venv` and installs `paho-mqtt` the first time.

```bash
# preview the selector and screen with three simulated M10s
./bin/epc-m10-hmi --demo

# live broker — starts on the inverter list
./bin/epc-m10-hmi --host 10.0.0.20 --port 1883

# skip the list and open one device
./bin/epc-m10-hmi --host 10.0.0.20 --port 1883 --device M10-A
```

Optional: `--group`, `--node`, `--username`, `--password`. Same values can be set with `M10_MQTT_*` and `M10_SPARKPLUG_*` env vars.

Default subscribe topic is `spBv1.0/#`.

### Keys

On the list: `↑` `↓` or `j` `k` move, `Enter` opens, `q` quits.

On the HMI: `Esc` back to the list, `q` quits.

### Layout

- Selector: device, node, group, online / stale / offline
- HMI: connection badge, KPIs, DC / battery, thermal / state, alarms
