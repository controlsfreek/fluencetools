#!/usr/bin/env bash
# ANSI terminal HMI — list selector + detail panels.

SCREEN_STARTED=0
TERM_COLS=100
TERM_ROWS=32

screen_enter() {
  if (( ! SCREEN_STARTED )); then
    printf '%s' "${ALT_ON}${HIDE}${CLEAR}"
    SCREEN_STARTED=1
  fi
}

screen_leave() {
  if (( SCREEN_STARTED )); then
    printf '%s' "${ALT_OFF}${SHOW}${RESET}"
    SCREEN_STARTED=0
  fi
}

screen_size() {
  local c r
  c=$(tput cols 2>/dev/null || echo 100)
  r=$(tput lines 2>/dev/null || echo 32)
  (( c < 72 )) && c=72
  (( r < 24 )) && r=24
  TERM_COLS=$c
  TERM_ROWS=$r
}

box_top() { printf '%s┌%s┐%s' "$C_FRAME" "$(printf '─%.0s' $(seq 1 $(($1-2))))" "$RESET"; }
box_bot() { printf '%s└%s┘%s' "$C_FRAME" "$(printf '─%.0s' $(seq 1 $(($1-2))))" "$RESET"; }
box_line() {
  local width="$1" inner="$2"
  printf '%s│%s%s│%s' "$C_FRAME" "$(fit_text "$inner" $((width-2)))" "$C_FRAME" "$RESET"
}

screen_header() {
  local cols="$1" host="$2" port="$3" connected="$4" error="$5" demo="$6"
  local clock badge title broker right
  clock=$(date +'%I:%M:%S %p')
  if (( demo )); then
    badge="${C_AMBER}${BOLD} DEMO ${RESET}"
  elif [[ -n "$error" ]]; then
    badge="${C_BAD}${BOLD} FAULT ${RESET}"
  elif (( connected )); then
    badge="${C_OK}${BOLD} LIVE ${RESET}"
  else
    badge="${C_WARN}${BOLD} WAIT ${RESET}"
  fi
  title="${C_TITLE}${BOLD}  EPC M10  ${RESET}${C_HEAD}INVERTER HMI${RESET}  ${C_MUTE}READ ONLY${RESET}"
  broker="${C_MUTE}mqtt://${host}:${port}${RESET}"
  right="${broker}   ${badge}  ${C_VALUE}${clock}${RESET}"
  spread_text "$title" "$right" "$cols"
}

device_health() {
  local key="$1" now="$2"
  local last="${DEV_LAST[$key]:-0}"
  local age=$(( now - last ))
  if [[ "${DEV_ONLINE[$key]}" -ne 1 ]]; then
    printf '%s' "${C_BAD}OFFLINE${RESET}"
  elif (( last > 0 && age > STALE_AFTER )); then
    printf '%s' "${C_WARN}STALE ${age}s${RESET}"
  else
    printf '%s' "${C_OK}ONLINE${RESET}"
  fi
}

count_metrics() {
  local key="$1" n=0 mk
  for mk in "${!METRIC_VAL[@]}"; do
    [[ "$mk" == "$key|"* ]] && n=$((n + 1))
  done
  printf '%d' "$n"
}

pick_metric() {
  # sets PICK_NAME PICK_VAL PICK_UNIT PICK_TS or empties them
  local key="$1" slot="$2"
  PICK_NAME=""; PICK_VAL=""; PICK_UNIT=""; PICK_TS=""
  [[ -n "$key" ]] || return 1
  local mk name best_score=9999 best_name="" best_mk=""
  local n score
  for mk in "${!METRIC_SLOT[@]}"; do
    [[ "$mk" == "$key|"* ]] || continue
    [[ "${METRIC_SLOT[$mk]}" == "$slot" ]] || continue
    name="${mk#*|}"
    n="$(norm_name "$name")"
    score=0
    [[ "$n" == *total* || "$n" == *sum* ]] && score=$((score-2))
    [[ "$n" == *avg* || "$n" == *average* ]] && score=$((score-1))
    local vre='(^| )(ab|bc|l1|a)($| )'
    if [[ "$slot" == v* ]] && [[ "$n" =~ $vre ]]; then
      score=$((score-1))
    fi
    if (( score < best_score )) || { (( score == best_score )) && [[ "$name" < "$best_name" ]]; }; then
      best_score=$score
      best_name="$name"
      best_mk="$mk"
    fi
  done
  if [[ -n "$best_mk" ]]; then
    PICK_NAME="$best_name"
    PICK_VAL="${METRIC_VAL[$best_mk]}"
    PICK_UNIT="${METRIC_UNIT[$best_mk]}"
    PICK_TS="${METRIC_TS[$best_mk]}"
    return 0
  fi
  return 1
}

metrics_in_slots() {
  # fills MET_LIST as name|val|unit|ts|slot sorted
  local key="$1"; shift
  MET_LIST=()
  [[ -n "$key" ]] || return 0
  local -A want=()
  local s mk name
  for s in "$@"; do want[$s]=1; done
  local -a rows=()
  for mk in "${!METRIC_SLOT[@]}"; do
    [[ "$mk" == "$key|"* ]] || continue
    s="${METRIC_SLOT[$mk]}"
    [[ -n "$s" && -n "${want[$s]+x}" ]] || continue
    name="${mk#*|}"
    rows+=("${s}|${name,,}|${name}|${METRIC_VAL[$mk]}|${METRIC_UNIT[$mk]}|${METRIC_TS[$mk]}")
  done
  if ((${#rows[@]})); then
    local line
    while IFS= read -r line; do
      # drop first two sort keys
      local rest="${line#*|}"
      rest="${rest#*|}"
      MET_LIST+=("$rest")
    done < <(printf '%s\n' "${rows[@]}" | sort)
  fi
}

kpi_tile() {
  # prints 4 lines for one tile into TILE_LINES
  local width="$1" label="$2" unit="$3" now="$4"
  local w=$width
  local top bot mid1 mid2 val shown u color
  top="${C_FRAME}┌$(printf '─%.0s' $(seq 1 $((w-2))))┐${RESET}"
  bot="${C_FRAME}└$(printf '─%.0s' $(seq 1 $((w-2))))┘${RESET}"
  mid1="${C_FRAME}│${RESET}$(fit_text "${C_LABEL}${label}${RESET}" $((w-2)))${C_FRAME}│${RESET}"
  if [[ -z "$PICK_NAME" ]]; then
    val="${C_MUTE}$(printf '%*s' $((w-8)) '—')${RESET} ${C_UNIT}${unit}${RESET}"
  else
    if (( now - ${PICK_TS:-0} > STALE_AFTER )); then color="$C_MUTE"; else color="$C_VALUE"; fi
    shown=$(fmt_value "$PICK_VAL")
    u="${PICK_UNIT:-$unit}"
    val="${color}${BOLD}${shown}${RESET} ${C_UNIT}${u}${RESET}"
  fi
  mid2="${C_FRAME}│${RESET}$(fit_text "$val" $((w-2)))${C_FRAME}│${RESET}"
  TILE_LINES=("$top" "$mid1" "$mid2" "$bot")
}

draw_kpi_row() {
  local cols="$1" key="$2" now="$3"
  local slots=("AC POWER:pac:kW" "AC VOLTAGE:vac:V" "AC CURRENT:iac:A" "FREQUENCY:freq:Hz" "DC VOLTAGE:vdc:V")
  local n=${#slots[@]} gap=1
  local width=$(( (cols - gap*(n-1)) / n ))
  (( width < 14 )) && width=14
  local -a t0=() t1=() t2=() t3=()
  local item label slot unit gsp
  gsp=$(printf '%*s' "$gap" '')
  for item in "${slots[@]}"; do
    IFS=':' read -r label slot unit <<< "$item"
    pick_metric "$key" "$slot" || { PICK_NAME=""; }
    kpi_tile "$width" "$label" "$unit" "$now"
    t0+=("${TILE_LINES[0]}")
    t1+=("${TILE_LINES[1]}")
    t2+=("${TILE_LINES[2]}")
    t3+=("${TILE_LINES[3]}")
  done
  local out r
  for r in 0 1 2 3; do
    local -n arr="t$r"
    out="${arr[0]}"
    local k
    for ((k=1; k<${#arr[@]}; k++)); do
      out+="${gsp}${arr[$k]}"
    done
    KPI_LINES+=("$out")
  done
}

draw_list_panel() {
  local width="$1" title="$2" now="$3"
  # uses MET_LIST
  PANEL_LINES=()
  PANEL_LINES+=("$(box_top "$width")")
  PANEL_LINES+=("$(box_line "$width" " ${C_HEAD}${BOLD}${title}${RESET}")")
  PANEL_LINES+=("$(box_line "$width" " ${C_FRAME}$(printf '─%.0s' $(seq 1 $((width-4))))${RESET}")")
  local value_w=10 unit_w=4
  local name_w=$(( width - 2 - value_w - unit_w - 2 ))
  (( name_w < 8 )) && name_w=8
  local rows=("${MET_LIST[@]:0:8}")
  if ((${#rows[@]} == 0)); then rows=(""); fi
  local row name val unit ts color inner
  for row in "${rows[@]}"; do
    if [[ -z "$row" ]]; then
      inner=" ${C_MUTE}no tags yet${RESET}"
    else
      IFS='|' read -r name val unit ts <<< "$row"
      if (( now - ${ts:-0} > STALE_AFTER )); then color="$C_MUTE"; else color="$C_VALUE"; fi
      inner=" $(fit_text "${C_LABEL}${name}${RESET}" "$name_w") $(fit_text "${color}$(fmt_value "$val")${RESET}" "$value_w") $(fit_text "${C_UNIT}${unit}${RESET}" "$unit_w")"
    fi
    PANEL_LINES+=("$(box_line "$width" "$inner")")
  done
}

screen_draw() {
  local host="$1" port="$2" connected="$3" error="$4" demo="$5" now="$6" mode="$7" selected="$8" cursor="$9"
  screen_size
  local cols=$TERM_COLS rows=$TERM_ROWS
  local -a lines=()

  if [[ "$mode" == "list" ]]; then
    screen_draw_list "$host" "$port" "$connected" "$error" "$demo" "$now" "$cursor" "$cols" "$rows"
    return
  fi

  lines+=("$(screen_header "$cols" "$host" "$port" "$connected" "$error" "$demo")")
  local bar="${C_FRAME}$(printf '─%.0s' $(seq 1 "$cols"))${RESET}"
  if [[ -z "$selected" || -z "${DEV_GROUP[$selected]+x}" ]]; then
    lines+=("$bar")
    lines+=("${C_MUTE}  Waiting for Sparkplug NBIRTH / DBIRTH …${RESET}")
  else
    local path health seq ntags
    path="${DEV_GROUP[$selected]} / ${DEV_NODE[$selected]}"
    [[ -n "${DEV_DEVICE[$selected]}" ]] && path+=" / ${DEV_DEVICE[$selected]}"
    health=$(device_health "$selected" "$now")
    if [[ -n "${DEV_SEQ[$selected]}" ]]; then seq="seq ${DEV_SEQ[$selected]}"; else seq="seq —"; fi
    ntags=$(count_metrics "$selected")
    lines+=("$bar")
    lines+=("$(spread_text "${C_LABEL}  DEVICE  ${RESET}${C_VALUE}${path}${RESET}   ${health}" "${C_MUTE}${seq}   ${ntags} tags${RESET}" "$cols")")
  fi
  lines+=("")

  KPI_LINES=()
  draw_kpi_row "$cols" "$selected" "$now"
  lines+=("${KPI_LINES[@]}")
  lines+=("")

  local gap=1 left_w right_w
  left_w=$(( (cols - gap) / 2 ))
  (( left_w < 28 )) && left_w=28
  right_w=$(( cols - left_w - gap ))
  metrics_in_slots "$selected" pdc vdc idc soc
  draw_list_panel "$left_w" "DC / BATTERY" "$now"
  local -a dc_lines=("${PANEL_LINES[@]}")
  metrics_in_slots "$selected" temp state
  draw_list_panel "$right_w" "THERMAL / STATE" "$now"
  local -a th_lines=("${PANEL_LINES[@]}")
  local h=${#dc_lines[@]}
  (( ${#th_lines[@]} > h )) && h=${#th_lines[@]}
  while ((${#dc_lines[@]} < h)); do dc_lines+=("$(box_line "$left_w" "")"); done
  while ((${#th_lines[@]} < h)); do th_lines+=("$(box_line "$right_w" "")"); done
  dc_lines[-1]="$(box_bot "$left_w")"
  th_lines[-1]="$(box_bot "$right_w")"
  local gsp i
  gsp=$(printf '%*s' "$gap" '')
  for ((i=0; i<h; i++)); do
    lines+=("${dc_lines[$i]}${gsp}${th_lines[$i]}")
  done
  lines+=("")

  # alarms
  metrics_in_slots "$selected" fault
  local alarm_txt color
  if ((${#MET_LIST[@]} == 0)); then
    alarm_txt="no active fault tags"
    color="$C_OK"
  else
    color="$C_BAD"
    alarm_txt=""
    local j=0 row name val
    for row in "${MET_LIST[@]}"; do
      j=$((j + 1)); (( j > 4 )) && break
      IFS='|' read -r name val _ <<< "$row"
      [[ -n "$alarm_txt" ]] && alarm_txt+=", "
      alarm_txt+="${name}=$(fmt_value "$val")"
    done
  fi
  lines+=("${C_LABEL}  ALARMS  ${RESET}${color}${alarm_txt}${RESET}")
  local seen=""
  local k
  for k in "${DEV_ORDER[@]}"; do
    [[ -n "$seen" ]] && seen+=", "
    seen+="$k"
  done
  [[ -z "$seen" ]] && seen="—"
  lines+=("${C_MUTE}  nodes seen: ${seen}${RESET}")
  lines+=("")

  # other tags
  local -a others=()
  if [[ -n "$selected" ]]; then
    local mk name
    for mk in "${!METRIC_SLOT[@]}"; do
      [[ "$mk" == "$selected|"* ]] || continue
      [[ -z "${METRIC_SLOT[$mk]}" ]] || continue
      name="${mk#*|}"
      others+=("${name,,}|${name}|${METRIC_VAL[$mk]}|${METRIC_UNIT[$mk]}|${METRIC_TS[$mk]}")
    done
  fi
  if ((${#others[@]})); then
    lines+=("${C_LABEL}  OTHER TAGS${RESET}")
    local sorted_o line name val unit ts
    mapfile -t sorted_o < <(printf '%s\n' "${others[@]}" | sort | head -6)
    for line in "${sorted_o[@]}"; do
      IFS='|' read -r _ name val unit ts <<< "$line"
      if (( now - ${ts:-0} > STALE_AFTER )); then color="$C_MUTE"; else color="$C_VALUE"; fi
      lines+=("    ${C_LABEL}$(printf '%-28s' "$name")${RESET} ${color}$(printf '%10s' "$(fmt_value "$val")")${RESET} ${C_UNIT}${unit}${RESET}")
    done
  fi

  local footer="${C_FRAME}$(printf '─%.0s' $(seq 1 "$cols"))${RESET}"$'\n'"${C_MUTE}  Esc list · q quit · tags from DBIRTH/DDATA · READ ONLY${RESET}"
  local body_limit=$((rows - 2))
  local -a body=("${lines[@]:0:$body_limit}")
  while ((${#body[@]} < body_limit)); do body+=(""); done
  local frame="${HOME_C}"
  local ln
  for ln in "${body[@]}"; do
    frame+="$(fit_text "$ln" "$cols")"$'\n'
  done
  frame+="$footer${CLEAR_DOWN}"
  printf '%s' "$frame"
}

screen_draw_list() {
  local host="$1" port="$2" connected="$3" error="$4" demo="$5" now="$6" cursor="$7" cols="$8" rows="$9"
  list_inverters
  local -a lines=()
  lines+=("$(screen_header "$cols" "$host" "$port" "$connected" "$error" "$demo")")
  lines+=("${C_FRAME}$(printf '─%.0s' $(seq 1 "$cols"))${RESET}")

  local online=0 stale=0 off=0
  local key age last
  for key in "${INVERTERS[@]}"; do
    last="${DEV_LAST[$key]:-0}"
    age=$(( now - last ))
    if [[ "${DEV_ONLINE[$key]}" -ne 1 ]]; then
      off=$((off + 1))
    elif (( last > 0 && age > STALE_AFTER )); then
      stale=$((stale + 1))
    else
      online=$((online + 1))
    fi
  done
  lines+=("$(spread_text "${C_LABEL}  SELECT INVERTER${RESET}  ${C_MUTE}EPC M10 only · listening for DBIRTH${RESET}" "${C_OK}${online} online${RESET}  ${C_WARN}${stale} stale${RESET}  ${C_MUTE}${off} off${RESET}  ${C_VALUE}${#INVERTERS[@]} total${RESET}" "$cols")")
  lines+=("")

  local box_h=$(( rows - 8 ))
  (( box_h < 6 )) && box_h=6
  local inner_rows=$(( box_h - 3 ))
  lines+=("$(box_top "$cols")")
  lines+=("$(box_line "$cols" "  ${C_MUTE}$(printf '%-2s %-22s %-16s %-12s %-10s %s' '' DEVICE NODE GROUP STATE TAGS)${RESET}")")

  if ((${#INVERTERS[@]} == 0)); then
    local wait="  waiting for M10 birth messages …"
    if (( ! connected && ! demo )); then wait="  connecting to broker …"; fi
    lines+=("$(box_line "$cols" "${C_MUTE}${wait}${RESET}")")
    local _
    for ((_=1; _<inner_rows; _++)); do lines+=("$(box_line "$cols" "")"); done
  else
    local start=0
    if (( cursor >= inner_rows )); then start=$(( cursor - inner_rows + 1 )); fi
    local idx offset=0 name state sc mark row ntags
    for ((idx=start; idx<${#INVERTERS[@]} && offset<inner_rows; idx++, offset++)); do
      key="${INVERTERS[$idx]}"
      last="${DEV_LAST[$key]:-0}"
      age=$(( now - last ))
      if [[ "${DEV_ONLINE[$key]}" -ne 1 ]]; then
        state="OFFLINE"; sc="$C_BAD"
      elif (( last > 0 && age > STALE_AFTER )); then
        state="STALE ${age}s"; sc="$C_WARN"
      else
        state="ONLINE"; sc="$C_OK"
      fi
      if (( idx == cursor )); then mark="${C_AMBER}${BOLD}▶${RESET}"; else mark=" "; fi
      name="${DEV_DEVICE[$key]:-${DEV_NODE[$key]}}"
      ntags=$(count_metrics "$key")
      row="  ${mark} ${C_VALUE}$(printf '%-22s' "$name")${RESET} ${C_LABEL}$(printf '%-16s' "${DEV_NODE[$key]}")${RESET} ${C_MUTE}$(printf '%-12s' "${DEV_GROUP[$key]}")${RESET} ${sc}$(printf '%-10s' "$state")${RESET} ${C_MUTE}${ntags}${RESET}"
      lines+=("$(box_line "$cols" "$row")")
    done
    while (( offset < inner_rows )); do
      lines+=("$(box_line "$cols" "")")
      offset=$((offset + 1))
    done
  fi
  lines+=("$(box_bot "$cols")")

  local footer="${C_FRAME}$(printf '─%.0s' $(seq 1 "$cols"))${RESET}"$'\n'"${C_MUTE}  ↑↓ / j k move · Enter open · Esc back · q quit · READ ONLY${RESET}"
  local body_limit=$((rows - 2))
  local -a body=("${lines[@]:0:$body_limit}")
  while ((${#body[@]} < body_limit)); do body+=(""); done
  local frame="${HOME_C}" ln
  for ln in "${body[@]}"; do
    frame+="$(fit_text "$ln" "$cols")"$'\n'
  done
  frame+="$footer${CLEAR_DOWN}"
  printf '%s' "$frame"
}
