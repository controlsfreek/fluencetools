#!/usr/bin/env bash
# Sparkplug B topic parse + focused protobuf2 Payload/Metric decoder (hex-based).

# Outputs via globals: SP_GROUP SP_MSGTYPE SP_NODE SP_DEVICE SP_KEY SP_KIND
# Returns 0 if parsed, 1 if not a sparkplug topic we care about.
parse_topic() {
  local topic="$1"
  local -a parts=()
  local IFS='/'
  read -ra parts <<< "$topic"
  # filter empties
  local -a p=()
  local x
  for x in "${parts[@]}"; do
    [[ -n "$x" ]] && p+=("$x")
  done

  SP_GROUP=""; SP_MSGTYPE=""; SP_NODE=""; SP_DEVICE=""; SP_KEY=""; SP_KIND=""

  if ((${#p[@]} >= 3)) && [[ "${p[0]}" == "spBv1.0" && "${p[1]}" == "STATE" ]]; then
    SP_GROUP="STATE"; SP_MSGTYPE="STATE"; SP_NODE="${p[2]}"; SP_DEVICE=""
    SP_KEY="STATE/${p[2]}"; SP_KIND="state"
    return 0
  fi
  if ((${#p[@]} < 4)) || [[ "${p[0]}" != "spBv1.0" ]]; then
    return 1
  fi
  SP_GROUP="${p[1]}"
  SP_MSGTYPE="${p[2]}"
  SP_NODE="${p[3]}"
  SP_DEVICE=""
  if ((${#p[@]} >= 5)); then
    SP_DEVICE="${p[4]}"
  fi
  if [[ -n "$SP_DEVICE" ]]; then
    SP_KEY="${SP_GROUP}/${SP_NODE}/${SP_DEVICE}"
  else
    SP_KEY="${SP_GROUP}/${SP_NODE}"
  fi
  case "$SP_MSGTYPE" in
    NBIRTH|DBIRTH) SP_KIND="birth" ;;
    NDATA|DDATA) SP_KIND="data" ;;
    NDEATH|DDEATH) SP_KIND="death" ;;
    STATE) SP_KIND="state" ;;
    NCMD|DCMD) SP_KIND="cmd" ;;
    *) SP_KIND="other" ;;
  esac
  return 0
}

# --- Hex protobuf reader ---
# PB_HEX: contiguous lowercase hex string of bytes
# PB_I: current byte index (0-based)

pb_reset() { PB_HEX="$1"; PB_I=0; PB_LEN=$((${#PB_HEX} / 2)); }
pb_eof() { (( PB_I >= PB_LEN )); }
pb_byte() {
  local off=$((PB_I * 2))
  local h="${PB_HEX:off:2}"
  PB_I=$(( PB_I + 1 ))
  printf '%d' "0x${h:-00}"
}
pb_peek_hex() {
  local n="$1" off=$((PB_I * 2))
  printf '%s' "${PB_HEX:off:$((n*2))}"
}
pb_skip_bytes() { PB_I=$((PB_I + $1)); }

pb_varint() {
  local shift=0 result=0 b
  while :; do
    if (( PB_I >= PB_LEN )); then
      echo "truncated varint" >&2
      return 1
    fi
    b=$(pb_byte)
    result=$(( result | ((b & 127) << shift) ))
    if (( (b & 128) == 0 )); then
      printf '%s' "$result"
      return 0
    fi
    shift=$((shift + 7))
    if (( shift > 70 )); then
      echo "varint too long" >&2
      return 1
    fi
  done
}

pb_skip_wire() {
  local wire="$1" n
  case "$wire" in
    0) pb_varint >/dev/null || return 1 ;;
    1) pb_skip_bytes 8 ;;
    2)
      n=$(pb_varint) || return 1
      pb_skip_bytes "$n"
      ;;
    5) pb_skip_bytes 4 ;;
    *) echo "unsupported wire $wire" >&2; return 1 ;;
  esac
}

pb_bytes_hex() {
  local n off
  n=$(pb_varint) || return 1
  off=$((PB_I * 2))
  printf '%s' "${PB_HEX:off:$((n*2))}"
  PB_I=$((PB_I + n))
}

pb_string() {
  local hx
  hx=$(pb_bytes_hex) || return 1
  # decode hex to text
  if ((${#hx} == 0)); then printf ''; return 0; fi
  printf '%s' "$hx" | sed 's/\(..\)/\\x\1/g' | xargs -0 printf '%b' 2>/dev/null || \
    printf '%s' "$hx" | awk '{
      s=""
      for(i=1;i<=length($0);i+=2){
        c=strtonum("0x" substr($0,i,2))
        if (c>=32 && c<127) s=s sprintf("%c",c)
        else s=s "?"
      }
      printf "%s", s
    }'
}

# IEEE-754 helpers via awk (little-endian hex)
ieee754_f32() {
  local hex="$1"
  awk -v hex="$hex" 'BEGIN{
    b0=strtonum("0x" substr(hex,1,2))
    b1=strtonum("0x" substr(hex,3,2))
    b2=strtonum("0x" substr(hex,5,2))
    b3=strtonum("0x" substr(hex,7,2))
    sign = int(b3 / 128)
    expn = (b3 % 128) * 2 + int(b2 / 128)
    mant = (b2 % 128) * 65536 + b1 * 256 + b0
    if (expn == 255) { print (mant ? "nan" : (sign ? "-inf" : "inf")); exit }
    if (expn == 0) {
      if (mant == 0) { print (sign ? "-0" : "0"); exit }
      val = (mant / 8388608.0) * (2 ^ -126)
    } else {
      val = (1.0 + mant / 8388608.0) * (2 ^ (expn - 127))
    }
    if (sign) val = -val
    printf "%.10g", val
  }'
}

ieee754_f64() {
  local hex="$1"
  awk -v hex="$hex" 'BEGIN{
    split("", b)
    for (i=0; i<8; i++) b[i] = strtonum("0x" substr(hex, i*2+1, 2))
    sign = int(b[7] / 128)
    expn = (b[7] % 128) * 16 + int(b[6] / 16)
    # mantissa 52 bits
    mant = (b[6] % 16)
    for (i=5; i>=0; i--) mant = mant * 256 + b[i]
    two52 = 2 ^ 52
    if (expn == 2047) { print (mant ? "nan" : (sign ? "-inf" : "inf")); exit }
    if (expn == 0) {
      if (mant == 0) { print (sign ? "-0" : "0"); exit }
      val = (mant / two52) * (2 ^ -1022)
    } else {
      val = (1.0 + mant / two52) * (2 ^ (expn - 1023))
    }
    if (sign) val = -val
    printf "%.12g", val
  }'
}

signed_int() {
  local value="$1" bits="$2"
  # pure bash two's complement (mawk has no lshift/and)
  local sign=$((1 << (bits - 1)))
  local mask=$(( (1 << bits) - 1 ))
  local v=$(( value & mask ))
  if (( v & sign )); then
    v=$(( v - (1 << bits) ))
  fi
  printf '%s' "$v"
}

# Decode one Metric from hex blob; append to METRIC_RESULT arrays:
#   MD_NAME MD_ALIAS MD_TS MD_DT MD_NULL MD_VALUE (parallel arrays cleared by caller)
decode_metric_hex() {
  local raw="$1"
  local save_hex="$PB_HEX" save_i="$PB_I" save_len="$PB_LEN"
  pb_reset "$raw"

  local name="" alias="" ts="" dt="" is_null=0
  local int_v="" long_v="" float_v="" double_v="" bool_v="" string_v=""
  local tag field wire tmp

  while ! pb_eof; do
    tag=$(pb_varint) || break
    field=$((tag >> 3))
    wire=$((tag & 7))
    case "$field:$wire" in
      1:2) name=$(pb_string) || break ;;
      2:0) alias=$(pb_varint) || break ;;
      3:0) ts=$(pb_varint) || break ;;
      4:0) dt=$(pb_varint) || break ;;
      7:0)
        tmp=$(pb_varint) || break
        (( tmp != 0 )) && is_null=1
        ;;
      10:0) int_v=$(pb_varint) || break ;;
      11:0) long_v=$(pb_varint) || break ;;
      12:5)
        tmp=$(pb_peek_hex 4)
        pb_skip_bytes 4
        float_v=$(ieee754_f32 "$tmp")
        ;;
      13:1)
        tmp=$(pb_peek_hex 8)
        pb_skip_bytes 8
        double_v=$(ieee754_f64 "$tmp")
        ;;
      14:0)
        tmp=$(pb_varint) || break
        bool_v=$([[ "$tmp" != "0" ]] && echo true || echo false)
        ;;
      15:2) string_v=$(pb_string) || break ;;
      *) pb_skip_wire "$wire" || break ;;
    esac
  done

  PB_HEX="$save_hex"; PB_I="$save_i"; PB_LEN="$save_len"

  local value=""
  if (( is_null )); then
    value="null"
  elif [[ -n "$string_v" ]]; then
    value="$string_v"
  elif [[ -n "$bool_v" && ( -z "$dt" || "$dt" == "11" ) ]]; then
    value="$bool_v"
  elif [[ -n "$float_v" ]]; then
    value="$float_v"
  elif [[ -n "$double_v" ]]; then
    value="$double_v"
  elif [[ -n "$long_v" ]]; then
    if [[ "$dt" == "4" ]]; then
      value=$(signed_int "$long_v" 64)
    else
      value="$long_v"
    fi
  elif [[ -n "$int_v" ]]; then
    case "$dt" in
      1) value=$(signed_int "$int_v" 8) ;;
      2) value=$(signed_int "$int_v" 16) ;;
      3) value=$(signed_int "$int_v" 32) ;;
      *) value="$int_v" ;;
    esac
  elif [[ -n "$bool_v" ]]; then
    value="$bool_v"
  fi

  MD_NAME+=("$name")
  MD_ALIAS+=("$alias")
  MD_TS+=("$ts")
  MD_DT+=("$dt")
  MD_NULL+=("$is_null")
  MD_VALUE+=("$value")
}

# Decode payload hex into:
#   PL_TIMESTAMP PL_SEQ PL_UUID
#   and metric arrays via decode_metric_hex
decode_payload_hex() {
  local raw="$1"
  PL_TIMESTAMP=""; PL_SEQ=""; PL_UUID=""
  MD_NAME=(); MD_ALIAS=(); MD_TS=(); MD_DT=(); MD_NULL=(); MD_VALUE=()

  pb_reset "$raw"
  local tag field wire blob
  while ! pb_eof; do
    tag=$(pb_varint) || break
    field=$((tag >> 3))
    wire=$((tag & 7))
    case "$field:$wire" in
      1:0) PL_TIMESTAMP=$(pb_varint) || break ;;
      2:2)
        blob=$(pb_bytes_hex) || break
        decode_metric_hex "$blob"
        ;;
      3:0) PL_SEQ=$(pb_varint) || break ;;
      4:2) PL_UUID=$(pb_string) || break ;;
      *) pb_skip_wire "$wire" || break ;;
    esac
  done
}

# Convert binary stdin to hex
bin_to_hex() {
  od -An -tx1 | tr -d ' \n' | tr 'A-F' 'a-f'
}
