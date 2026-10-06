#!/usr/bin/env bash
# usage: run-logged <label> <command...>
# Streams the command's output, reports duration, and on failure prints the tail of the
# log plus the lines that look like errors, so the cause is at the bottom of the build log.
label="$1"; shift
log="/tmp/${label}.log"
now() { date -u +%H:%M:%S; }
echo "[$(now)] >>> ${label}: started"
start=$(date +%s)
"$@" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
dur=$(( $(date +%s) - start ))
if [ "$rc" -eq 0 ]; then
  echo "[$(now)] <<< ${label}: OK in ${dur}s"
  exit 0
fi
echo
echo "================ ${label} FAILED (exit ${rc}) after ${dur}s ================"
echo "---- last 120 lines ----"
tail -n 120 "$log"
echo "---- lines that look like errors (last 40) ----"
grep -nEi '(^|[^a-z])(error|fatal|undefined reference|cannot find|no such file|not found|failed)' "$log" | tail -n 40 || true
echo "================ end of ${label} failure report ================"
exit "$rc"
