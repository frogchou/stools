#!/usr/bin/env bash

set -o pipefail

API_BASE_URL="${API_BASE_URL:-http://jp.frogchou.com:8000/api/v1/ipsearch}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-5}"
SHOW_ALL=0

if [ "${1:-}" = "--show-all" ] || [ "${1:-}" = "-a" ]; then
  SHOW_ALL=1
fi

is_external_ipv4() {
  local ip="$1"
  local a b c d

  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1

  IFS=. read -r a b c d <<< "$ip"
  for part in "$a" "$b" "$c" "$d"; do
    [[ "$part" =~ ^[0-9]+$ ]] || return 1
    (( part >= 0 && part <= 255 )) || return 1
  done

  (( a == 0 )) && return 1
  (( a == 10 )) && return 1
  (( a == 127 )) && return 1
  (( a == 169 && b == 254 )) && return 1
  (( a == 172 && b >= 16 && b <= 31 )) && return 1
  (( a == 192 && b == 168 )) && return 1
  (( a == 100 && b >= 64 && b <= 127 )) && return 1
  (( a >= 224 )) && return 1
  [[ "$ip" = "255.255.255.255" ]] && return 1

  return 0
}

strip_addr() {
  local value="$1"

  if [[ "$value" =~ ^\[([^]]+)\]:[0-9*]+$ ]]; then
    value="${BASH_REMATCH[1]}"
  fi

  value="${value#::ffff:}"

  if [[ "$value" =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3}):[0-9*]+$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "$value"
  fi
}

get_process_name() {
  local pid="$1"
  local comm

  if [[ -z "$pid" || "$pid" = "-" || "$pid" = "0" ]]; then
    printf '%s\n' "-"
    return
  fi

  if [[ -r "/proc/$pid/comm" ]]; then
    comm="$(tr -d '\0\r\n' < "/proc/$pid/comm")"
    printf '%s\n' "${comm:-"-"}"
  else
    printf '%s\n' "-"
  fi
}

json_location_to_text() {
  local raw="$1"

  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
raw = sys.stdin.read().strip()
try:
    data = json.loads(raw)
except Exception:
    print(raw)
    raise SystemExit
if isinstance(data, list):
    print(" | ".join(str(x) for x in data))
elif isinstance(data, dict) and isinstance(data.get("data"), list):
    print(" | ".join(str(x) for x in data["data"]))
elif isinstance(data, dict) and "data" in data:
    print(data["data"])
else:
    print(data)
' <<< "$raw"
  else
    printf '%s\n' "$raw" | sed -e 's/^\[//' -e 's/\]$//' -e 's/^"//' -e 's/"$//' -e 's/","/ | /g' -e 's/\\"/"/g'
  fi
}

declare -A LOCATION_CACHE

get_ip_location() {
  local ip="$1"
  local raw location

  if [[ -n "${LOCATION_CACHE[$ip]+x}" ]]; then
    printf '%s\n' "${LOCATION_CACHE[$ip]}"
    return
  fi

  if command -v curl >/dev/null 2>&1; then
    raw="$(curl -fsSL --connect-timeout "$TIMEOUT_SECONDS" --max-time "$TIMEOUT_SECONDS" \
      -H 'User-Agent: ip-netstat-linux/1.0' "$API_BASE_URL/$ip" 2>/dev/null)"
  elif command -v wget >/dev/null 2>&1; then
    raw="$(wget -qO- --timeout="$TIMEOUT_SECONDS" --header='User-Agent: ip-netstat-linux/1.0' \
      "$API_BASE_URL/$ip" 2>/dev/null)"
  else
    raw=""
  fi

  if [[ -z "$raw" ]]; then
    location="LookupFailed"
  else
    location="$(json_location_to_text "$raw")"
    [[ -z "$location" ]] && location="-"
  fi

  LOCATION_CACHE[$ip]="$location"
  printf '%s\n' "$location"
}

print_header() {
  printf '%-5s %-24s %-24s %-12s %-8s %-22s %s\n' \
    "Proto" "LocalAddress" "ForeignAddress" "State" "PID" "Process" "Location"
  printf '%-5s %-24s %-24s %-12s %-8s %-22s %s\n' \
    "-----" "------------" "--------------" "-----" "---" "-------" "--------"
}

list_with_ss() {
  local state recvq sendq local_addr peer_addr rest pid proc

  ss -H -tanp 2>/dev/null | while read -r state recvq sendq local_addr peer_addr rest; do
    pid="-"
    proc="-"
    if [[ "$rest" =~ users:\(\(\"([^\"]+)\",pid=([0-9]+) ]]; then
      proc="${BASH_REMATCH[1]}"
      pid="${BASH_REMATCH[2]}"
    fi
    printf 'TCP\t%s\t%s\t%s\t%s\t%s\n' "$local_addr" "$peer_addr" "$state" "$pid" "$proc"
  done
}

list_with_netstat() {
  netstat -antp 2>/dev/null | awk '
    /^tcp/ {
      split($7, p, "/")
      pid=p[1]
      proc=p[2]
      if (pid == "" || pid == "-") pid="-"
      if (proc == "") proc="-"
      print "TCP\t" $4 "\t" $5 "\t" $6 "\t" pid "\t" proc
    }
  '
}

if command -v ss >/dev/null 2>&1; then
  connection_source="$(list_with_ss)"
elif command -v netstat >/dev/null 2>&1; then
  connection_source="$(list_with_netstat)"
else
  echo "Neither ss nor netstat was found."
  exit 1
fi

rows=0
print_header

while IFS=$'\t' read -r proto local_addr foreign_addr state pid process_name; do
  [[ -z "$proto" ]] && continue

  remote_ip="$(strip_addr "$foreign_addr")"

  if (( SHOW_ALL )); then
    if is_external_ipv4 "$remote_ip"; then
      external="true"
    else
      external="false"
    fi
    printf '%-5s %-24s %-24s %-12s %-8s %-22s %s\n' \
      "$proto" "$local_addr" "$foreign_addr" "$state" "$pid" "$process_name" "ExternalIPv4=$external"
    rows=$((rows + 1))
    continue
  fi

  [[ "$state" = "ESTAB" || "$state" = "ESTABLISHED" ]] || continue
  is_external_ipv4 "$remote_ip" || continue

  process_name="${process_name:-$(get_process_name "$pid")}"
  [[ "$process_name" = "-" ]] && process_name="$(get_process_name "$pid")"
  location="$(get_ip_location "$remote_ip")"

  printf '%-5s %-24s %-24s %-12s %-8s %-22s %s\n' \
    "$proto" "$local_addr" "$foreign_addr" "ESTABLISHED" "$pid" "$process_name" "$location"
  rows=$((rows + 1))
done <<< "$connection_source"

if (( rows == 0 )); then
  echo "No established external IPv4 TCP connections found."
  echo "Tip: open a website or keep an app connected, then run again."
  echo "Debug: run ./list_ip_connections_linux.sh --show-all to view all TCP connections."
fi
