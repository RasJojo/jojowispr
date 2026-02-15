#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ID="com.jojo.wisprlocal"
PROJECT_PATH="$ROOT_DIR/macos/WisprLocal/WisprLocal.xcodeproj"
TARGET_NAME="WisprLocal"
CONFIGURATION="Release"
BUILD_APP_PATH="$ROOT_DIR/macos/WisprLocal/build/$CONFIGURATION/$TARGET_NAME.app"

DEFAULT_SERVER_URL="https://your-server.example.com/transcribe"
DEFAULT_INSTALL_PATH="/Applications/$TARGET_NAME.app"

log() { printf "[wisprlocal] %s\n" "$*"; }
die() { printf "[wisprlocal] ERROR: %s\n" "$*" >&2; exit 1; }

command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found (install Xcode + command line tools)."
command -v codesign >/dev/null 2>&1 || die "codesign not found."
command -v security >/dev/null 2>&1 || die "security command not found."
command -v defaults >/dev/null 2>&1 || die "defaults command not found."
command -v curl >/dev/null 2>&1 || die "curl not found."
if command -v ruby >/dev/null 2>&1; then
  log "Regenerating Xcode project..."
  if ! ruby "$ROOT_DIR/macos/WisprLocal/generate_xcodeproj.rb" >/dev/null; then
    log "WARN: Failed to regenerate Xcode project (missing ruby gems?). Continuing with existing project."
  fi
else
  log "WARN: ruby not found; skipping Xcode project regeneration."
fi

log "Backend check (health)..."
if curl -fsS "${DEFAULT_SERVER_URL%/transcribe}/health" >/dev/null 2>&1; then
  log "Backend reachable"
else
  log "Backend health check failed (non-blocking). We'll still install the app."
fi

SERVER_URL="${SERVER_URL:-}"
if [[ -z "${SERVER_URL}" ]]; then
  read -r -p "Server URL [/transcribe] (default: ${DEFAULT_SERVER_URL}): " SERVER_URL
  SERVER_URL="${SERVER_URL:-$DEFAULT_SERVER_URL}"
fi

LANGUAGE="${LANGUAGE:-}"
if [[ -z "${LANGUAGE}" ]]; then
  read -r -p "Language (empty=auto, fr/en/es/de/it) [auto]: " LANGUAGE
  LANGUAGE="${LANGUAGE:-}"
fi

API_KEY="${WISPR_API_KEY:-${API_KEY:-}}"
if [[ -z "${API_KEY}" ]]; then
  read -r -s -p "API key (stored in Keychain): " API_KEY
  printf "\n"
fi

log "Writing preferences (UserDefaults) for ${APP_ID}..."
defaults write "${APP_ID}" wispr.server_url -string "${SERVER_URL}"
defaults write "${APP_ID}" wispr.language -string "${LANGUAGE}"
defaults write "${APP_ID}" wispr.pause_media -bool true
defaults write "${APP_ID}" wispr.play_sounds -bool true
defaults write "${APP_ID}" wispr.smart_formatting -bool true

log "Writing API key to Keychain (service=WisprLocal, account=apiKey)..."
security add-generic-password -s "WisprLocal" -a "apiKey" -w "${API_KEY}" -U >/dev/null

log "Building ${TARGET_NAME} (${CONFIGURATION})..."
xcodebuild -project "${PROJECT_PATH}" -target "${TARGET_NAME}" -configuration "${CONFIGURATION}" build >/dev/null
[[ -d "${BUILD_APP_PATH}" ]] || die "Build output not found at ${BUILD_APP_PATH}"

IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "${IDENTITY}" ]]; then
  # Prefer Developer ID if present; otherwise fall back to Apple Development.
  IDENTITY="$(security find-identity -v -p codesigning \
    | awk -F\" '/Developer ID Application/ {print $2; found=1; exit} END{ if(!found){} }' || true)"
  if [[ -z "${IDENTITY}" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning \
      | awk -F\" '/Apple Development/ {print $2; exit}' || true)"
  fi
fi

if [[ -z "${IDENTITY}" ]]; then
  log "No signing identity found. Using ad-hoc signing (may cause repeated permission prompts on rebuild)."
  IDENTITY="-"
else
  log "Using codesign identity: ${IDENTITY}"
fi

log "Codesigning app..."
codesign --force --deep --sign "${IDENTITY}" --timestamp=none "${BUILD_APP_PATH}"
codesign -vv "${BUILD_APP_PATH}" >/dev/null 2>&1 || die "codesign verification failed"

INSTALL_PATH="${INSTALL_PATH:-$DEFAULT_INSTALL_PATH}"
if [[ ! -w "$(dirname "${INSTALL_PATH}")" ]]; then
  INSTALL_PATH="$HOME/Applications/$TARGET_NAME.app"
  mkdir -p "$HOME/Applications"
  log "No permission for /Applications; installing to ${INSTALL_PATH}"
else
  log "Installing to ${INSTALL_PATH}"
fi

# Ensure we restart the app so you're not running an old in-memory binary.
pkill -x "${TARGET_NAME}" >/dev/null 2>&1 || true
sleep 0.3

rm -rf "${INSTALL_PATH}"
cp -R "${BUILD_APP_PATH}" "${INSTALL_PATH}"

log "Launching installed app..."
open "${INSTALL_PATH}"

log "Open Privacy settings (approve once):"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone" || true
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true

cat <<EOF

Installed: ${INSTALL_PATH}

Important:
- Run THIS installed app (not Xcode/DerivedData builds), otherwise macOS will keep reprompting permissions.

EOF
