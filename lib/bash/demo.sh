#!/usr/bin/env bash
# Simulated fleet: 3 M10s + 1 BMS (BMS must be filtered out of the list).

load_demo() {
  local now="$1"
  local fleet=(
    "Fluence/EDGE-01/M10-A|Fluence|EDGE-01|M10-A|0.00|1"
    "Fluence/EDGE-01/M10-B|Fluence|EDGE-01|M10-B|0.03|1"
    "Fluence/EDGE-02/M10-C|Fluence|EDGE-02|M10-C|-0.02|1"
    "Fluence/EDGE-01/BMS-1|Fluence|EDGE-01|BMS-1|0.00|0"
  )
  local entry key group node device bias is_m10
  local phase sweep
  for entry in "${fleet[@]}"; do
    IFS='|' read -r key group node device bias is_m10 <<< "$entry"
    ensure_device "$key" "$group" "$node" "$device"
    DEV_ONLINE[$key]=1
    DEV_BORN[$key]=1
    DEV_LAST[$key]="$now"
    DEV_SEQ[$key]=$(( (now + ${bias%.*} * 10) % 256 ))
    if [[ "$is_m10" == "0" ]]; then
      upsert_metric "$key" "BMS/SOC" "81.0" "$now"
      upsert_metric "$key" "BMS/Voltage" "1320.0" "$now"
      DEV_IS_M10[$key]=0
      continue
    fi
    phase=$(awk -v n="$now" -v b="$bias" 'BEGIN{printf "%.6f", ((n + b*8) % 8.0) / 8.0}')
    sweep=$(awk -v p="$phase" 'BEGIN{printf "%.6f", 0.04 * (p - 0.5)}')
    upsert_metric "$key" "Properties/Model" "EPC M10" "$now"
    upsert_metric "$key" "AC/ActivePower" "$(awk -v s="$sweep" -v b="$bias" 'BEGIN{printf "%.3f", 412.5*(1+s+b)}')" "$now"
    upsert_metric "$key" "AC/VoltageAB" "$(awk -v b="$bias" 'BEGIN{printf "%.1f", 480.2+b}')" "$now"
    upsert_metric "$key" "AC/VoltageBC" "479.6" "$now"
    upsert_metric "$key" "AC/VoltageCA" "480.8" "$now"
    upsert_metric "$key" "AC/CurrentA" "$(awk -v s="$sweep" 'BEGIN{printf "%.3f", 498.1*(1+s)}')" "$now"
    upsert_metric "$key" "AC/Frequency" "60.012" "$now"
    upsert_metric "$key" "DC/Voltage1" "$(awk -v b="$bias" 'BEGIN{printf "%.1f", 1184.0+b*10}')" "$now"
    upsert_metric "$key" "DC/Voltage2" "1179.5" "$now"
    upsert_metric "$key" "DC/Current1" "$(awk -v s="$sweep" 'BEGIN{printf "%.3f", 178.4*(1+s)}')" "$now"
    upsert_metric "$key" "DC/Power" "$(awk -v s="$sweep" -v b="$bias" 'BEGIN{printf "%.3f", 418.0*(1+s+b)}')" "$now"
    upsert_metric "$key" "BESS/SOC" "$(awk -v b="$bias" 'BEGIN{printf "%.1f", 67.4+b*20}')" "$now"
    upsert_metric "$key" "Thermal/Heatsink" "$(awk -v b="$bias" 'BEGIN{ab=(b<0)?-b:b; printf "%.1f", 41.2+ab*8}')" "$now"
    upsert_metric "$key" "Thermal/Cabinet" "32.8" "$now"
    upsert_metric "$key" "Status/State" "GRID_FOLLOWING" "$now"
    upsert_metric "$key" "Status/Fault" "false" "$now"
    classify_device "$key"
  done
}
