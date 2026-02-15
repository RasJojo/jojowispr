#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-WisprLocal}"
SUBSYSTEM="${SUBSYSTEM:-com.jojo.wisprlocal}"
SINCE="${SINCE:-20m}"
FULL="${FULL:-0}"

if [[ "${FULL}" == "1" ]]; then
  echo "[wisprlocal] Showing logs for process=${APP_NAME} (FULL=1) since last ${SINCE}..."
else
  echo "[wisprlocal] Showing logs for subsystem=${SUBSYSTEM} since last ${SINCE}..."
fi
echo

if [[ "${FULL}" == "1" ]]; then
  /usr/bin/log show --info --debug --last "${SINCE}" --style compact --predicate "process == \"${APP_NAME}\"" \
    | rg -i "com\\.jojo\\.wisprlocal|CFNetwork|network:|h3stream|quic|timed out|timeout|HTTP|error|failed|invalid|Transcription|Transcribe|URLSession|curl|dictation|paste|Accessibility|Microphone|hotkey|Recorder|Now Playing|MediaRemote|Wispr" \
    | tail -n 300 || true
else
  /usr/bin/log show --info --debug --last "${SINCE}" --style compact --predicate "subsystem == \"${SUBSYSTEM}\"" \
    | tail -n 300 || true
fi

echo
echo "[wisprlocal] Tip: live tail (Ctrl-C to stop)"
if [[ "${FULL}" == "1" ]]; then
  echo "  /usr/bin/log stream --info --debug --style compact --predicate 'process == \"${APP_NAME}\"'"
else
  echo "  /usr/bin/log stream --info --debug --style compact --predicate 'subsystem == \"${SUBSYSTEM}\"'"
fi
