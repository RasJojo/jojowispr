#!/usr/bin/env bash
set -euo pipefail

SUBSYSTEM="${SUBSYSTEM:-com.jojo.wisprlocal}"
DUR="${DUR:-2m}"
OUT="${OUT:-/tmp/wisprlocal_debug_$(date +%Y%m%d_%H%M%S).log}"

echo "[wisprlocal] Capturing unified logs for subsystem=${SUBSYSTEM}"
echo "[wisprlocal] Duration: ${DUR}"
echo "[wisprlocal] Output:   ${OUT}"
echo
echo "[wisprlocal] Now reproduce the issue (start dictation -> stop -> wait)."
echo "[wisprlocal] This command will stop automatically after ${DUR}."
echo

/usr/bin/log stream \
  --level debug \
  --style compact \
  --timeout "${DUR}" \
  --predicate "subsystem == \"${SUBSYSTEM}\"" \
  | tee "${OUT}"

echo
echo "[wisprlocal] Done. Share the file or run:"
echo "  tail -n 200 ${OUT}"

