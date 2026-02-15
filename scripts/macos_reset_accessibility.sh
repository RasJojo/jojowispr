#!/usr/bin/env bash
set -euo pipefail

APP_ID="com.jojo.wisprlocal"
APP_PATH="/Applications/WisprLocal.app"

log() { printf "[wisprlocal] %s\n" "$*"; }

log "Stopping WisprLocal..."
pkill -f "$APP_PATH/Contents/MacOS/WisprLocal" 2>/dev/null || true
sleep 0.3

log "Resetting Accessibility permission for ${APP_ID}..."
tccutil reset Accessibility "${APP_ID}" || true

log "Restarting tccd (flush privacy cache)..."
killall tccd 2>/dev/null || true
sleep 0.5

log "Launching app..."
open "${APP_PATH}"

log "Opening Accessibility privacy pane..."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true

cat <<EOF

Now:
1) In Privacy & Security -> Accessibility, enable "WisprLocal"
2) Quit WisprLocal (menu bar -> Quit) and re-open it

EOF

