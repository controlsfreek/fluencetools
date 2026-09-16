#!/usr/bin/env bash
# Main loop: draw, keys, MQTT drain / demo refresh.

wanted_topic() {
  if [[ -n "$ARGS_GROUP" && "$SP_GROUP" != "$ARGS_GROUP" ]]; then return 1; fi
  if [[ -n "$ARGS_NODE" && "$SP_NODE" != "$ARGS_NODE" ]]; then return 1; fi
  return 0
}

mqtt_on_publish() {
  local topic="$1" payload_hex="$2"
  parse_topic "$topic" || return 0
  wanted_topic || return 0
  case "$SP_MSGTYPE" in
    NBIRTH|DBIRTH|NDATA|DDATA|NDEATH|DDEATH|STATE) ;;
    *) return 0 ;;
  esac
  [[ "$SP_KIND" == "cmd" ]] && return 0
  [[ "$SP_KIND" == "state" ]] && return 0

  local now
  now=$(now_epoch)
  ensure_device "$SP_KEY" "$SP_GROUP" "$SP_NODE" "$SP_DEVICE"

  if [[ "$SP_KIND" == "death" ]]; then
    DEV_ONLINE[$SP_KEY]=0
    DEV_LAST[$SP_KEY]="$now"
    return 0
  fi

  decode_payload_hex "$payload_hex" || {
    APP_ERROR="decode failed"
    return 0
  }

  if [[ "$SP_KIND" == "birth" ]]; then
    DEV_ONLINE[$SP_KEY]=1
    DEV_BORN[$SP_KEY]=1
    if [[ "$SP_MSGTYPE" == "DBIRTH" || -n "$SP_DEVICE" ]]; then
      # clear aliases and metrics for this device
      local mk a
      for mk in "${!METRIC_VAL[@]}"; do
        if [[ "$mk" == "$SP_KEY|"* ]]; then
          unset "METRIC_VAL[$mk]" "METRIC_UNIT[$mk]" "METRIC_SLOT[$mk]" "METRIC_TS[$mk]"
        fi
      done
      for a in "${!ALIAS_MAP[@]}"; do
        if [[ "$a" == "$SP_KEY|"* ]]; then
          unset "ALIAS_MAP[$a]"
        fi
      done
    fi
  elif [[ "$SP_KIND" == "data" ]]; then
    DEV_ONLINE[$SP_KEY]=1
  fi
  DEV_LAST[$SP_KEY]="$now"
  [[ -n "$PL_SEQ" ]] && DEV_SEQ[$SP_KEY]="$PL_SEQ"

  local i name alias ts value ts_use
  for ((i=0; i<${#MD_NAME[@]}; i++)); do
    name=$(resolve_name "$SP_KEY" "${MD_ALIAS[$i]}" "${MD_NAME[$i]}")
    [[ -z "$name" ]] && continue
    [[ "${MD_NULL[$i]}" == "1" ]] && continue
    value="${MD_VALUE[$i]}"
    ts="${MD_TS[$i]:-${PL_TIMESTAMP:-}}"
    ts_use="$now"
    if [[ -n "$ts" ]]; then
      # sparkplug timestamps are usually ms
      if (( ts > 1000000000000 )); then
        ts_use=$(( ts / 1000 ))
      elif (( ts > 1000000000 )); then
        ts_use=$ts
      fi
    fi
    upsert_metric "$SP_KEY" "$name" "$value" "$ts_use"
  done

  if [[ "$SP_KIND" == "birth" || "${DEV_IS_M10[$SP_KEY]}" -eq 0 ]]; then
    classify_device "$SP_KEY"
  fi
}

open_cursor() {
  list_inverters
  ((${#INVERTERS[@]})) || return 0
  if (( APP_CURSOR < 0 )); then APP_CURSOR=0; fi
  if (( APP_CURSOR >= ${#INVERTERS[@]} )); then APP_CURSOR=$((${#INVERTERS[@]} - 1)); fi
  APP_SELECTED="${INVERTERS[$APP_CURSOR]}"
  APP_MODE="detail"
}

# Read one key; maps arrows to j/k; bare Esc → esc. Drains CSI.
read_key() {
  local timeout="${1:-0.2}"
  local ch
  if ! IFS= read -rsn1 -t "$timeout" ch; then
    printf ''
    return 1
  fi
  if [[ "$ch" != $'\033' ]]; then
    printf '%s' "$ch"
    return 0
  fi
  # drain CSI / SS3
  local seq="$ch" more
  while IFS= read -rsn1 -t 0.08 more; do
    seq+="$more"
    # end of typical CSI
    [[ "$more" =~ [A-Za-z~] ]] && break
  done
  if [[ "$seq" == $'\033' ]]; then
    printf 'esc'
    return 0
  fi
  if [[ "$seq" == *$'\033'[A || "$seq" == *$'\033'OA || "$seq" == *A ]]; then
    # prefer last char check
    :
  fi
  case "$seq" in
    $'\033'[A|$'\033'OA) printf 'k'; return 0 ;;
    $'\033'[B|$'\033'OB) printf 'j'; return 0 ;;
  esac
  # ends with A/B
  if [[ "$seq" == *A ]]; then printf 'k'; return 0; fi
  if [[ "$seq" == *B ]]; then printf 'j'; return 0; fi
  printf ''
  return 1
}

poll_keys() {
  local timeout="$1"
  local ch
  ch=$(read_key "$timeout") || return 0
  [[ -z "$ch" ]] && return 0
  case "$ch" in
    esc)
      [[ "$APP_MODE" == "detail" ]] && APP_MODE="list"
      return 0
      ;;
    q|Q|$'\003')
      APP_RUNNING=0
      return 0
      ;;
  esac
  if [[ "$APP_MODE" == "list" ]]; then
    list_inverters
    case "$ch" in
      j|J)
        if ((${#INVERTERS[@]})); then
          APP_CURSOR=$((APP_CURSOR + 1))
          (( APP_CURSOR >= ${#INVERTERS[@]} )) && APP_CURSOR=$((${#INVERTERS[@]} - 1))
        fi
        ;;
      k|K)
        APP_CURSOR=$((APP_CURSOR - 1))
        (( APP_CURSOR < 0 )) && APP_CURSOR=0
        ;;
      $'\r'|$'\n'|' ')
        open_cursor
        ;;
    esac
  fi
}

app_run() {
  if (( ! ARGS_DEMO )) && [[ -z "$ARGS_HOST" ]]; then
    echo "Need --host (or M10_MQTT_HOST), or pass --demo to preview the screen." >&2
    return 2
  fi

  screen_enter
  local old_stty=""
  if [[ -t 0 ]]; then
    old_stty=$(stty -g)
    stty cbreak -echo 2>/dev/null || stty -echo -icanon
  fi

  trap 'APP_RUNNING=0' INT TERM

  if (( ! ARGS_DEMO )); then
    mqtt_connect "$ARGS_HOST" "$ARGS_PORT" "$ARGS_CLIENT_ID" "$ARGS_USERNAME" "$ARGS_PASSWORD" || true
  fi

  local now host
  host="${ARGS_HOST:-demo}"
  while (( APP_RUNNING )); do
    now=$(now_epoch)
    if (( ARGS_DEMO )); then
      load_demo "$now"
      APP_CONNECTED=1
    else
      mqtt_drain 0.05
    fi
    list_inverters
    if [[ -n "$ARGS_DEVICE" && -z "$APP_SELECTED" ]]; then
      local k
      for k in "${INVERTERS[@]}"; do
        if [[ "${DEV_DEVICE[$k]}" == "$ARGS_DEVICE" ]]; then
          APP_SELECTED="$k"
          APP_MODE="detail"
          break
        fi
      done
    fi
    if ((${#INVERTERS[@]})); then
      if (( APP_CURSOR < 0 )); then APP_CURSOR=0; fi
      if (( APP_CURSOR >= ${#INVERTERS[@]} )); then APP_CURSOR=$((${#INVERTERS[@]} - 1)); fi
    else
      APP_CURSOR=0
    fi
    local err=""
    (( ARGS_DEMO )) || err="$APP_ERROR"
    screen_draw "$host" "$ARGS_PORT" "$APP_CONNECTED" "$err" "$ARGS_DEMO" "$now" "$APP_MODE" "$APP_SELECTED" "$APP_CURSOR"
    poll_keys 0.2
  done

  if (( ! ARGS_DEMO )); then
    mqtt_disconnect
  fi
  if [[ -n "$old_stty" ]]; then
    stty "$old_stty" 2>/dev/null || true
  fi
  screen_leave
  return 0
}
