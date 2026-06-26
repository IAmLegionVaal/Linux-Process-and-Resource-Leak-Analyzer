#!/usr/bin/env bash
set -u

SAMPLE_SECONDS=5
TOP_N=20
OUTPUT_DIR=""

usage() {
  echo "Usage: process_resource_analyzer.sh [--sample-seconds N] [--top N] [--output DIR]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sample-seconds) SAMPLE_SECONDS="${2:-5}"; shift 2 ;;
    --top) TOP_N="${2:-20}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ "$SAMPLE_SECONDS" =~ ^[0-9]+$ ]] || { echo "--sample-seconds must be numeric" >&2; exit 2; }
[[ "$TOP_N" =~ ^[0-9]+$ ]] || { echo "--top must be numeric" >&2; exit 2; }

STAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${OUTPUT_DIR:-./process-analysis-$STAMP}"
mkdir -p "$OUTPUT_DIR"
REPORT="$OUTPUT_DIR/process-analysis.txt"
CSV="$OUTPUT_DIR/processes.csv"
GROWTH_CSV="$OUTPUT_DIR/rss-growth.csv"
JSON="$OUTPUT_DIR/summary.json"
ERRORS="$OUTPUT_DIR/command-errors.log"
SNAP1="$OUTPUT_DIR/rss-snapshot-1.tsv"
SNAP2="$OUTPUT_DIR/rss-snapshot-2.tsv"
: > "$REPORT"
: > "$ERRORS"

echo 'pid,user,state,cpu_percent,mem_percent,rss_kib,vsz_kib,threads,elapsed_seconds,open_fds,command' > "$CSV"
echo 'pid,command,rss_before_kib,rss_after_kib,growth_kib' > "$GROWTH_CSV"

section() {
  local title="$1"
  shift
  {
    printf '\n===== %s =====\n' "$title"
    "$@"
  } >> "$REPORT" 2>> "$ERRORS" || true
}

csv_escape() {
  local value="$1"
  value="${value//\"/\"\"}"
  printf '"%s"' "$value"
}

have() { command -v "$1" >/dev/null 2>&1; }

section "Collection metadata" bash -c 'date -Is; hostname -f 2>/dev/null || hostname; cat /etc/os-release 2>/dev/null || true; uname -a; uptime'
section "Memory and swap" bash -c 'free -h; swapon --show 2>/dev/null || true'
# Variables expand inside the child bash process.
# shellcheck disable=SC2016
section "Pressure stall information" bash -c 'for f in /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io; do [[ -r "$f" ]] && { echo "--- $f"; cat "$f"; }; done'
section "System limits" bash -c 'ulimit -a; sysctl fs.file-max kernel.pid_max 2>/dev/null || true; cat /proc/sys/fs/file-nr 2>/dev/null || true'
section "Top CPU processes" bash -c "ps -eo pid,user,state,pcpu,pmem,rss,vsz,nlwp,etimes,comm,args --sort=-pcpu | head -n $((TOP_N + 1))"
section "Top memory processes" bash -c "ps -eo pid,user,state,pcpu,pmem,rss,vsz,nlwp,etimes,comm,args --sort=-rss | head -n $((TOP_N + 1))"
# The awk field expression is evaluated by the child shell.
# shellcheck disable=SC2016
section "Zombie and uninterruptible processes" bash -c 'ps -eo pid,ppid,user,state,etimes,comm,args | awk "NR==1 || $4 ~ /^[ZD]/"'
section "Kernel resource warnings" bash -c 'journalctl -k --since "24 hours ago" --no-pager 2>/dev/null | grep -Ei "out of memory|oom-killer|killed process|hung task|blocked for more than|fork: retry|resource temporarily unavailable|too many open files" | tail -n 1000 || true'

ps -eo pid=,user=,state=,pcpu=,pmem=,rss=,vsz=,nlwp=,etimes=,comm= 2>>"$ERRORS" | while read -r pid user state pcpu pmem rss vsz threads elapsed command; do
  [[ -z "$pid" ]] && continue
  open_fds=0
  if [[ -d "/proc/$pid/fd" ]]; then
    open_fds="$(find "/proc/$pid/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
  fi
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$pid" \
    "$(csv_escape "$user")" \
    "$(csv_escape "$state")" \
    "$pcpu" "$pmem" "$rss" "$vsz" "$threads" "$elapsed" "$open_fds" \
    "$(csv_escape "$command")" >> "$CSV"
done

ps -eo pid=,rss=,comm= 2>>"$ERRORS" | awk '{print $1"\t"$2"\t"$3}' > "$SNAP1"
sleep "$SAMPLE_SECONDS"
ps -eo pid=,rss=,comm= 2>>"$ERRORS" | awk '{print $1"\t"$2"\t"$3}' > "$SNAP2"

awk -F'\t' 'NR==FNR {rss[$1]=$2; cmd[$1]=$3; next} ($1 in rss) {growth=$2-rss[$1]; if (growth>0) print $1","cmd[$1]","rss[$1]","$2","growth}' "$SNAP1" "$SNAP2" | sort -t, -k5,5nr >> "$GROWTH_CSV"

if have lsof; then
  section "Processes with most open files" bash -c "lsof -nP 2>/dev/null | awk 'NR>1 {count[\$2]++; name[\$2]=\$1} END {for (pid in count) print count[pid], pid, name[pid]}' | sort -nr | head -n $TOP_N"
fi

if have pidstat; then
  section "pidstat sample" pidstat -durwt 1 3
fi

ZOMBIES="$(ps -eo state= | awk '$1 ~ /^Z/ {count++} END {print count+0}')"
UNINTERRUPTIBLE="$(ps -eo state= | awk '$1 ~ /^D/ {count++} END {print count+0}')"
HIGH_FD="$(awk -F, 'NR>1 && $10>=1024 {c++} END {print c+0}' "$CSV")"
HIGH_THREADS="$(awk -F, 'NR>1 && $8>=500 {c++} END {print c+0}' "$CSV")"
GROWING="$(awk -F, 'NR>1 && $5>=10240 {c++} END {print c+0}' "$GROWTH_CSV")"
MEM_AVAILABLE_KIB="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
SWAP_FREE_KIB="$(awk '/SwapFree:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
LOAD1="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)"

OVERALL="Healthy"
if [[ "$ZOMBIES" -gt 0 || "$HIGH_FD" -gt 0 || "$HIGH_THREADS" -gt 0 || "$GROWING" -gt 0 ]]; then
  OVERALL="Attention required"
fi

cat > "$JSON" <<EOF
{
  "collected_at": "$(date -Is)",
  "hostname": "$(hostname -f 2>/dev/null || hostname)",
  "sample_seconds": $SAMPLE_SECONDS,
  "load_average_1m": $LOAD1,
  "memory_available_kib": ${MEM_AVAILABLE_KIB:-0},
  "swap_free_kib": ${SWAP_FREE_KIB:-0},
  "zombie_processes": $ZOMBIES,
  "uninterruptible_processes": $UNINTERRUPTIBLE,
  "processes_with_1024_or_more_open_fds": $HIGH_FD,
  "processes_with_500_or_more_threads": $HIGH_THREADS,
  "processes_growing_by_10_mib_or_more": $GROWING,
  "overall_status": "$OVERALL"
}
EOF

printf '\nProcess and resource analysis completed: %s\n' "$OUTPUT_DIR" | tee -a "$REPORT"
