#!/usr/bin/env bash
# Shared constants, ANSI palette, CLI parsing, device state helpers.

STALE_AFTER=5

RESET=$'\033[0m'
BOLD=$'\033[1m'
HIDE=$'\033[?25l'
SHOW=$'\033[?25h'
ALT_ON=$'\033[?1049h'
ALT_OFF=$'\033[?1049l'
HOME_C=$'\033[H'
CLEAR=$'\033[2J'
CLEAR_DOWN=$'\033[J'

C_FRAME=$'\033[38;5;24m'
C_TITLE=$'\033[38;5;159m'
C_LABEL=$'\033[38;5;109m'
C_VALUE=$'\033[38;5;230m'
C_UNIT=$'\033[38;5;66m'
C_OK=$'\033[38;5;84m'
C_WARN=$'\033[38;5;220m'
C_BAD=$'\033[38;5;203m'
C_MUTE=$'\033[38;5;59m'
C_AMBER=$'\033[38;5;178m'
C_HEAD=$'\033[38;5;81m'

# Device / metric state (associative)
declare -A DEV_GROUP DEV_NODE DEV_DEVICE DEV_ONLINE DEV_LAST DEV_SEQ DEV_IS_M10 DEV_BORN
declare -A METRIC_VAL METRIC_UNIT METRIC_SLOT METRIC_TS
declare -A ALIAS_MAP
declare -a DEV_ORDER=()

ARGS_HOST=""
ARGS_PORT=1883
ARGS_GROUP=""
ARGS_NODE=""
ARGS_DEVICE=""
ARGS_USERNAME=""
ARGS_PASSWORD=""
ARGS_CLIENT_ID="fluencetools-m10-hmi"
ARGS_TOPIC="spBv1.0/#"
ARGS_DEMO=0

APP_CONNECTED=0
APP_ERROR=""
APP_RUNNING=1
APP_MODE="list"
APP_SELECTED=""
APP_CURSOR=0

now_epoch() { date +%s; }
now_epoch_ms() { date +%s%3N 2>/dev/null || echo $(( $(date +%s) * 1000 )); }

norm_name() {
  local s="${1,,}"
  s="${s//[^a-z0-9]/ }"
  s="${s//  / }"
  s="${s## }"; s="${s%% }"
  printf '%s' "$s"
}

classify_slot() {
  local n; n="$(norm_name "$1")"
  [[ -z "$n" ]] && { printf ''; return; }
  local re
  re='(fault|trip|alarm|error|warn)'
  if [[ "$n" =~ $re ]]; then printf 'fault'; return; fi
  re='(^| )(state|status|mode|run|online|enabled)($| )'
  if [[ "$n" =~ $re ]]; then printf 'state'; return; fi
  re='(soc|state of charge)'
  if [[ "$n" =~ $re ]]; then printf 'soc'; return; fi
  re='(temp|temperature|heatsink|coolant|igbt)'
  if [[ "$n" =~ $re ]]; then printf 'temp'; return; fi
  re='(freq|frequency|hertz|(^| )hz($| ))'
  if [[ "$n" =~ $re ]]; then printf 'freq'; return; fi
  re='(dc).*(volt|vdc)|(^| )vdc($| )|dc voltage'
  if [[ "$n" =~ $re ]]; then printf 'vdc'; return; fi
  re='(dc).*(curr|amp|idc)|(^| )idc($| )|dc current'
  if [[ "$n" =~ $re ]]; then printf 'idc'; return; fi
  re='(dc).*(power|kw|watt)|(^| )pdc($| )|dc power'
  if [[ "$n" =~ $re ]]; then printf 'pdc'; return; fi
  re='(ac).*(volt|vac)|volt|vab|vbc|vca|van|vbn|vcn|(^| )vac($| )'
  if [[ "$n" =~ $re ]]; then printf 'vac'; return; fi
  re='(ac).*(curr|amp)|current|(^| )iac($| )|(^| )amps?($| )'
  if [[ "$n" =~ $re ]]; then printf 'iac'; return; fi
  re='(active|real|output|ac)? ?power|(^| )pac($| )|(^| )kw($| )|(^| )kwe($| )'
  if [[ "$n" =~ $re ]]; then printf 'pac'; return; fi
  printf ''
}

infer_unit() {
  local slot="$1" name="$2" value="$3"
  local n; n="$(norm_name "$name")"
  if [[ "$n" == *kw* && "$n" != *kvar* && "$n" != *kva* ]]; then printf 'kW'; return; fi
  if [[ "$n" == *kvar* ]]; then printf 'kVAr'; return; fi
  if [[ "$n" == *kva* ]]; then printf 'kVA'; return; fi
  if [[ "$slot" == "vac" || "$slot" == "vdc" || "$n" == *volt* ]]; then printf 'V'; return; fi
  if [[ "$slot" == "iac" || "$slot" == "idc" || "$n" == *curr* || "$n" == *amp* ]]; then printf 'A'; return; fi
  if [[ "$slot" == "freq" || "$n" == *hz* ]]; then printf 'Hz'; return; fi
  if [[ "$slot" == "temp" || "$n" == *temp* ]]; then printf '°C'; return; fi
  if [[ "$slot" == "soc" ]]; then printf '%%'; return; fi
  if [[ "$slot" == "pac" || "$slot" == "pdc" ]]; then printf 'kW'; return; fi
  if [[ "$value" == "true" || "$value" == "false" ]]; then printf ''; return; fi
  printf ''
}

fmt_value() {
  local value="$1"
  if [[ -z "$value" || "$value" == "null" ]]; then printf '—'; return; fi
  if [[ "$value" == "true" ]]; then printf 'ON'; return; fi
  if [[ "$value" == "false" ]]; then printf 'OFF'; return; fi
  if [[ "$value" =~ ^-?[0-9]+$ ]]; then
    printf '%s' "$value"
    return
  fi
  if [[ "$value" =~ ^-?[0-9]*\.[0-9]+$ || "$value" =~ ^-?[0-9]+\.[0-9]*$ ]]; then
    awk -v v="$value" 'BEGIN{
      av = (v<0)?-v:v
      if (av >= 1000) printf "%.1f", v
      else if (av >= 100) printf "%.1f", v
      else if (av >= 10) printf "%.2f", v
      else printf "%.3f", v
    }'
    return
  fi
  printf '%s' "$value"
}

ensure_device() {
  local key="$1" group="$2" node="$3" device="${4:-}"
  if [[ -z "${DEV_GROUP[$key]+x}" ]]; then
    DEV_GROUP[$key]="$group"
    DEV_NODE[$key]="$node"
    DEV_DEVICE[$key]="$device"
    DEV_ONLINE[$key]=0
    DEV_LAST[$key]=0
    DEV_SEQ[$key]=""
    DEV_IS_M10[$key]=0
    DEV_BORN[$key]=0
    DEV_ORDER+=("$key")
  fi
}

metric_key() { printf '%s|%s' "$1" "$2"; }

upsert_metric() {
  local key="$1" name="$2" value="$3" ts="$4"
  local slot unit mk
  slot="$(classify_slot "$name")"
  unit="$(infer_unit "$slot" "$name" "$value")"
  mk="$(metric_key "$key" "$name")"
  METRIC_VAL[$mk]="$value"
  METRIC_UNIT[$mk]="$unit"
  METRIC_SLOT[$mk]="$slot"
  METRIC_TS[$mk]="$ts"
}

resolve_name() {
  local key="$1" alias="$2" name="$3"
  if [[ -n "$name" ]]; then
    if [[ -n "$alias" ]]; then
      ALIAS_MAP["$key|$alias"]="$name"
    fi
    printf '%s' "$name"
    return
  fi
  if [[ -n "$alias" ]]; then
    printf '%s' "${ALIAS_MAP[$key|$alias]:-}"
    return
  fi
  printf ''
}

identify_m10() {
  local key="$1"
  local blob="${DEV_GROUP[$key]} ${DEV_NODE[$key]} ${DEV_DEVICE[$key]}"
  local re='m[[:space:]_-]*10'
  if [[ "${blob,,}" =~ $re ]]; then
    return 0
  fi
  local mk name val
  for mk in "${!METRIC_VAL[@]}"; do
    [[ "$mk" == "$key|"* ]] || continue
    name="${mk#*|}"
    val="${METRIC_VAL[$mk]}"
    re='m[[:space:]_-]*10'
    if [[ "${name,,}" =~ $re || "${val,,}" =~ $re ]]; then
      return 0
    fi
    local hint='(device.?type|model|product|hw.?type|inverter.?type|manufacturer|vendor|devicetype)'
    if [[ "${name,,}" =~ $hint ]]; then
      if [[ "${val,,}" =~ $re ]]; then
        return 0
      fi
    fi
  done
  return 1
}

classify_device() {
  local key="$1"
  if identify_m10 "$key"; then
    DEV_IS_M10[$key]=1
  else
    DEV_IS_M10[$key]=0
  fi
  if [[ "$APP_MODE" == "detail" && -z "$APP_SELECTED" && -n "$ARGS_DEVICE" \
        && "${DEV_IS_M10[$key]}" -eq 1 && "${DEV_DEVICE[$key]}" == "$ARGS_DEVICE" ]]; then
    APP_SELECTED="$key"
  fi
}

# Populate INVERTERS array with M10 keys sorted by device/node
list_inverters() {
  INVERTERS=()
  local key name
  local -a pairs=()
  for key in "${DEV_ORDER[@]}"; do
    [[ "${DEV_IS_M10[$key]}" -eq 1 ]] || continue
    name="${DEV_DEVICE[$key]:-${DEV_NODE[$key]}}"
    pairs+=("${name,,}|$key")
  done
  if ((${#pairs[@]})); then
    local sorted
    mapfile -t sorted < <(printf '%s\n' "${pairs[@]}" | sort)
    for name in "${sorted[@]}"; do
      INVERTERS+=("${name#*|}")
    done
  fi
}

parse_args() {
  ARGS_HOST="${M10_MQTT_HOST:-}"
  ARGS_PORT="${M10_MQTT_PORT:-1883}"
  ARGS_GROUP="${M10_SPARKPLUG_GROUP:-}"
  ARGS_NODE="${M10_SPARKPLUG_NODE:-}"
  ARGS_DEVICE="${M10_SPARKPLUG_DEVICE:-}"
  ARGS_USERNAME="${M10_MQTT_USERNAME:-}"
  ARGS_PASSWORD="${M10_MQTT_PASSWORD:-}"
  ARGS_CLIENT_ID="${M10_MQTT_CLIENT_ID:-fluencetools-m10-hmi}"
  ARGS_TOPIC="spBv1.0/#"
  ARGS_DEMO=0

  while (($#)); do
    case "$1" in
      --host) ARGS_HOST="$2"; shift 2 ;;
      --port) ARGS_PORT="$2"; shift 2 ;;
      --group) ARGS_GROUP="$2"; shift 2 ;;
      --node) ARGS_NODE="$2"; shift 2 ;;
      --device) ARGS_DEVICE="$2"; shift 2 ;;
      --username) ARGS_USERNAME="$2"; shift 2 ;;
      --password) ARGS_PASSWORD="$2"; shift 2 ;;
      --client-id) ARGS_CLIENT_ID="$2"; shift 2 ;;
      --topic) ARGS_TOPIC="$2"; shift 2 ;;
      --demo) ARGS_DEMO=1; shift ;;
      -h|--help)
        cat <<'HELP'
Usage: epc-m10-hmi [--demo] [--host HOST] [--port PORT] [options]

Read-only terminal HMI for EPC M10 inverters (Sparkplug B over MQTT).
Subscribes only; never publishes.

  --demo                 Simulate 3 M10s + 1 BMS (BMS filtered out)
  --host HOST            MQTT broker (or M10_MQTT_HOST)
  --port PORT            MQTT port (default 1883)
  --group/--node/--device Sparkplug filters
  --username/--password  MQTT auth
  --client-id ID         MQTT client id
  --topic TOPIC          Subscribe topic (default spBv1.0/#)
HELP
        exit 0
        ;;
      *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
  done

  if [[ -n "$ARGS_DEVICE" ]]; then
    APP_MODE="detail"
  else
    APP_MODE="list"
  fi
}

vis_len() {
  # visible length ignoring ANSI CSI ... m
  local s="$1" n=0 i=0
  local len=${#s}
  while ((i < len)); do
    if [[ "${s:i:1}" == $'\033' ]]; then
      local rest="${s:i}"
      local j="${rest%%m*}"
      if [[ "$j" == "$rest" ]]; then
        i=$(( i + 1 ))
      else
        i=$((i + ${#j} + 1))
      fi
      continue
    fi
    n=$((n + 1)); i=$((i + 1))
  done
  printf '%d' "$n"
}

fit_text() {
  local text="$1" width="$2"
  local out="" visible=0 i=0
  local len=${#text}
  while ((i < len && visible < width)); do
    if [[ "${text:i:1}" == $'\033' ]]; then
      local rest="${text:i}"
      local j="${rest%%m*}"
      if [[ "$j" == "$rest" ]]; then
        break
      fi
      out+="${text:i:$((${#j}+1))}"
      i=$((i + ${#j} + 1))
      continue
    fi
    out+="${text:i:1}"
    visible=$((visible + 1)); i=$((i + 1))
  done
  while ((visible < width)); do
    out+=" "
    visible=$(( visible + 1 ))
  done
  printf '%s%s' "$out" "$RESET"
}

spread_text() {
  local left="$1" right="$2" cols="$3"
  local lv rv pad
  lv=$(vis_len "$left")
  rv=$(vis_len "$right")
  pad=$((cols - lv - rv))
  ((pad < 1)) && pad=1
  fit_text "${left}$(printf '%*s' "$pad" '')${right}" "$cols"
}
