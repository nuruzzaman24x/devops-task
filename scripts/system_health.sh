#!/usr/bin/env bash
# system_health.sh - collect basic host health metrics, log them, and exit with a status code.
# Exit codes: 0 = healthy, 1 = warning, 2 = critical.
set -euo pipefail

CPU_T=90
MEM_T=85
DISK_T=80
CRIT_MARGIN=10                  # critical = threshold + 10 points
JSON=0
LOG_FILE="health_log.txt"
MAX_BYTES=1048576               # rotate when the log exceeds 1 MB
KEEP=5                          # number of rotated files to keep

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --cpu N        CPU usage warning threshold in percent (default: ${CPU_T})
  --mem N        Memory usage warning threshold in percent (default: ${MEM_T})
  --disk N       Disk usage warning threshold in percent (default: ${DISK_T})
  --json         Write the log entry as one JSON line instead of plain text
  --log-file F   Log file path (default: ${LOG_FILE})
  -h, --help     Show this help

A value is CRITICAL when it exceeds its threshold by ${CRIT_MARGIN} points or more.
Exit codes: 0 = healthy, 1 = warning, 2 = critical.
USAGE
}

is_num() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 100 ]; }

while [ $# -gt 0 ]; do
  case "$1" in
    --cpu|--mem|--disk|--log-file)
      [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 64; }
      case "$1" in
        --cpu)  is_num "$2" || { echo "--cpu needs 1-100" >&2; exit 64; };  CPU_T=$2 ;;
        --mem)  is_num "$2" || { echo "--mem needs 1-100" >&2; exit 64; };  MEM_T=$2 ;;
        --disk) is_num "$2" || { echo "--disk needs 1-100" >&2; exit 64; }; DISK_T=$2 ;;
        --log-file) LOG_FILE=$2 ;;
      esac
      shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
done

# ---- CPU: two samples of /proc/stat, 1 second apart ----
read_cpu() { awk '/^cpu /{idle=$5+$6; total=0; for(i=2;i<=NF;i++) total+=$i; print idle, total}' /proc/stat; }
read -r idle1 total1 <<<"$(read_cpu)"
sleep 1
read -r idle2 total2 <<<"$(read_cpu)"
dt=$((total2 - total1))
di=$((idle2 - idle1))
if [ "$dt" -gt 0 ]; then CPU=$(( (100 * (dt - di)) / dt )); else CPU=0; fi

# ---- Memory: used = total - available ----
MEM=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{ if (t>0) printf "%d", (t-a)*100/t; else print 0 }' /proc/meminfo)

# ---- Load average ----
read -r L1 L5 L15 _ < /proc/loadavg

# ---- Disk: all real mounted filesystems (skip tmpfs, overlay and similar) ----
DISKS=$(df -P -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs 2>/dev/null \
  | awk 'NR>1 {gsub("%","",$5); print $6, $5}')

# ---- Top 5 processes by memory ----
TOP5=$(ps -eo pid,comm,%mem --sort=-%mem 2>/dev/null | awk 'NR>1 && NR<=6 {printf "%s:%s:%s;", $1, $2, $3}')

STATUS=0
WARNINGS=()

bump() { [ "$STATUS" -lt "$1" ] && STATUS=$1; return 0; }

check() {  # name value threshold
  local name=$1 val=$2 thr=$3
  if [ "$val" -ge $((thr + CRIT_MARGIN)) ]; then
    WARNINGS+=("[CRITICAL] ${name} at ${val}% (threshold ${thr}%)"); bump 2
  elif [ "$val" -gt "$thr" ]; then
    WARNINGS+=("[WARNING] ${name} at ${val}% (threshold ${thr}%)"); bump 1
  fi
}

check "CPU" "$CPU" "$CPU_T"
check "Memory" "$MEM" "$MEM_T"
while read -r mount pct; do
  [ -n "${mount:-}" ] && check "Disk ${mount}" "$pct" "$DISK_T"
done <<<"$DISKS"

if [ "$STATUS" -eq 0 ]; then LABEL="healthy"; elif [ "$STATUS" -eq 1 ]; then LABEL="warning"; else LABEL="critical"; fi
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
HOST=$(hostname)

# ---- Log rotation ----
rotate_log() {
  [ -f "$LOG_FILE" ] || return 0
  local size
  size=$(wc -c < "$LOG_FILE")
  [ "$size" -ge "$MAX_BYTES" ] || return 0
  local i
  for ((i = KEEP - 1; i >= 1; i--)); do
    [ -f "${LOG_FILE}.${i}" ] && mv -f "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
  done
  mv -f "$LOG_FILE" "${LOG_FILE}.1"
}

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# ---- Build the log entry ----
if [ "$JSON" -eq 1 ]; then
  disks_json=""
  while read -r mount pct; do
    [ -n "${mount:-}" ] || continue
    disks_json+="{\"mount\":\"$(json_escape "$mount")\",\"used_percent\":${pct}},"
  done <<<"$DISKS"
  procs_json=""
  IFS=';' read -ra PROCS <<<"$TOP5"
  for p in "${PROCS[@]}"; do
    [ -n "$p" ] || continue
    IFS=':' read -r pid comm pmem <<<"$p"
    procs_json+="{\"pid\":${pid},\"command\":\"$(json_escape "$comm")\",\"mem_percent\":${pmem}},"
  done
  warn_json=""
  for w in "${WARNINGS[@]+"${WARNINGS[@]}"}"; do
    warn_json+="\"$(json_escape "$w")\","
  done
  ENTRY="{\"timestamp\":\"${TS}\",\"host\":\"$(json_escape "$HOST")\",\"status\":\"${LABEL}\",\"exit_code\":${STATUS},\"cpu_percent\":${CPU},\"memory_percent\":${MEM},\"load\":{\"1m\":${L1},\"5m\":${L5},\"15m\":${L15}},\"disks\":[${disks_json%,}],\"top_memory_processes\":[${procs_json%,}],\"warnings\":[${warn_json%,}]}"
else
  ENTRY="${TS} host=${HOST} status=${LABEL} cpu=${CPU}% mem=${MEM}% load=${L1},${L5},${L15}"
  while read -r mount pct; do
    [ -n "${mount:-}" ] && ENTRY+=" disk[${mount}]=${pct}%"
  done <<<"$DISKS"
  ENTRY+=" top_mem=${TOP5%;}"
fi

rotate_log
echo "$ENTRY" >> "$LOG_FILE"

# ---- Console output ----
echo "$ENTRY"
for w in "${WARNINGS[@]+"${WARNINGS[@]}"}"; do echo "$w"; done

exit "$STATUS"
