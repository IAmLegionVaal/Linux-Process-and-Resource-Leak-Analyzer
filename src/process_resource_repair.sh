#!/usr/bin/env bash
set -u

SERVICE=""
PID=""
RENICE_VALUE=""
FORCE=false
DRY_RUN=false
ASSUME_YES=false
OUTPUT_DIR=""
FAILURES=0
ACTIONS=0

usage() {
  cat <<'EOF'
Usage: process_resource_repair.sh [options]

  --restart-service UNIT   Restart and verify one systemd service.
  --reset-failed UNIT      Clear failure state for one systemd service.
  --terminate-pid PID      Send TERM to one non-system user process.
  --renice PID VALUE       Change priority for one non-system user process.
  --force                  Send KILL if a selected process ignores TERM.
  --dry-run                Show commands without changing the system.
  --yes                    Skip confirmation prompts.
  --output DIR             Save logs and before/after evidence in DIR.
EOF
}

ACTION=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --restart-service) ACTION="restart-service"; SERVICE="${2:-}"; shift 2 ;;
    --reset-failed) ACTION="reset-failed"; SERVICE="${2:-}"; shift 2 ;;
    --terminate-pid) ACTION="terminate"; PID="${2:-}"; shift 2 ;;
    --renice) ACTION="renice"; PID="${2:-}"; RENICE_VALUE="${3:-}"; shift 3 ;;
    --force) FORCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    --output) OUTPUT_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$ACTION" ] || { echo "Choose one repair action." >&2; exit 2; }
if [ -n "$SERVICE" ]; then
  command -v systemctl >/dev/null 2>&1 || { echo "systemd is required." >&2; exit 3; }
  systemctl cat "$SERVICE" >/dev/null 2>&1 || { echo "Unit not found: $SERVICE" >&2; exit 2; }
fi
if [ -n "$PID" ]; then
  case "$PID" in ''|*[!0-9]*) echo "PID must be numeric." >&2; exit 2 ;; esac
  [ "$PID" -gt 99 ] || { echo "Refusing low system PID." >&2; exit 2; }
  PROC_UID=$(ps -o uid= -p "$PID" 2>/dev/null | tr -d ' ')
  [ -n "$PROC_UID" ] || { echo "Process not found: $PID" >&2; exit 2; }
  [ "$PROC_UID" -ge 1000 ] || { echo "Use a systemd service action for system-owned processes." >&2; exit 2; }
fi
if [ "$ACTION" = "renice" ]; then
  case "$RENICE_VALUE" in -20|-19|-18|-17|-16|-15|-14|-13|-12|-11|-10|-9|-8|-7|-6|-5|-4|-3|-2|-1|0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19) : ;; *) echo "Nice value must be between -20 and 19." >&2; exit 2 ;; esac
fi

STAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="${OUTPUT_DIR:-./process-repair-$STAMP}"
mkdir -p "$OUTPUT_DIR"
LOG="$OUTPUT_DIR/repair.log"
BEFORE="$OUTPUT_DIR/before.txt"
AFTER="$OUTPUT_DIR/after.txt"
: > "$LOG"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
confirm() { $ASSUME_YES && return 0; read -r -p "$1 [y/N]: " answer; case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac; }
run_action() {
  local description="$1"; shift
  ACTIONS=$((ACTIONS + 1)); log "$description"
  if $DRY_RUN; then
    {
      printf 'DRY-RUN:'
      printf ' %q' "$@"
      printf '\n'
    } >> "$LOG"
    return 0
  fi
  if "$@" >> "$LOG" 2>&1; then log "SUCCESS: $description"; return 0; fi
  FAILURES=$((FAILURES + 1)); log "WARNING: $description failed"; return 1
}
run_root() { local description="$1"; shift; if [ "$(id -u)" -eq 0 ]; then run_action "$description" "$@"; else run_action "$description" sudo "$@"; fi; }
collect_state() {
  local destination="$1"
  {
    echo "Collected: $(date -Is)"
    uptime
    free -h 2>/dev/null || true
    echo
    ps -Ao pid,user,uid,ni,%cpu,%mem,rss,vsz,stat,etime,comm --sort=-%cpu | head -n 40
    echo
    cat /proc/pressure/cpu 2>/dev/null || true
    cat /proc/pressure/memory 2>/dev/null || true
    cat /proc/pressure/io 2>/dev/null || true
    if [ -n "$PID" ]; then echo; ps -p "$PID" -o pid,user,uid,ni,%cpu,%mem,rss,vsz,stat,etime,comm,args 2>&1 || true; fi
    if [ -n "$SERVICE" ]; then echo; systemctl status "$SERVICE" --no-pager -l 2>&1 || true; journalctl -u "$SERVICE" -n 100 --no-pager 2>&1 || true; fi
  } > "$destination"
}

collect_state "$BEFORE"
confirm "Apply process repair action '$ACTION'? Unsaved application work may be lost." || { log "Repair cancelled."; exit 10; }

case "$ACTION" in
  restart-service)
    run_root "Restarting $SERVICE" systemctl restart "$SERVICE" || true
    ;;
  reset-failed)
    run_root "Clearing failed state for $SERVICE" systemctl reset-failed "$SERVICE" || true
    ;;
  terminate)
    run_root "Sending TERM to process $PID" kill -TERM "$PID" || true
    if ! $DRY_RUN; then
      WAITED=0
      while kill -0 "$PID" 2>/dev/null && [ "$WAITED" -lt 10 ]; do sleep 1; WAITED=$((WAITED + 1)); done
      if kill -0 "$PID" 2>/dev/null && $FORCE && confirm "Process $PID did not exit. Send KILL?"; then run_root "Sending KILL to process $PID" kill -KILL "$PID" || true; fi
    fi
    ;;
  renice)
    run_root "Changing process $PID priority to $RENICE_VALUE" renice "$RENICE_VALUE" -p "$PID" || true
    ;;
esac

$DRY_RUN || sleep 2
collect_state "$AFTER"
if [ "$ACTION" = "restart-service" ]; then systemctl is-active --quiet "$SERVICE" || { FAILURES=$((FAILURES + 1)); log "WARNING: $SERVICE is not active after repair."; }; fi
if [ "$ACTION" = "terminate" ] && ! $DRY_RUN && kill -0 "$PID" 2>/dev/null; then FAILURES=$((FAILURES + 1)); log "WARNING: process $PID remains active."; fi
if [ "$FAILURES" -gt 0 ]; then exit 20; fi
log "Process repair completed successfully. Actions performed: $ACTIONS"
exit 0
