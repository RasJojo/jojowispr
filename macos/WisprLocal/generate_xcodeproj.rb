#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'xcodeproj'

ROOT = File.expand_path(File.join(__dir__, '..', '..'))
PROJECT_DIR = File.join(ROOT, 'macos', 'WisprLocal')
PROJECT_PATH = File.join(PROJECT_DIR, 'WisprLocal.xcodeproj')
SOURCES_DIR = File.join(PROJECT_DIR, 'WisprLocal')

FileUtils.rm_rf(PROJECT_PATH)

project = Xcodeproj::Project.new(PROJECT_PATH)

main_group = project.main_group
sources_group = main_group.new_group('WisprLocal', 'WisprLocal')

file_refs = []
Dir.glob(File.join(SOURCES_DIR, '*.{swift,plist}')).sort.each do |abs|
  # sources_group already has path "WisprLocal" relative to the project.
  file_refs << sources_group.new_file(File.basename(abs))
end

# Add Assets.xcassets
assets_ref = sources_group.new_file('Assets.xcassets')

target = project.new_target(:application, 'WisprLocal', :osx, '13.0')

swift_refs = file_refs.select { |r| r.path.end_with?('.swift') }
target.add_file_references(swift_refs)
target.add_resources([assets_ref])

bundle_whisper = target.new_shell_script_build_phase('Bundle Whisper Runtime')
bundle_whisper.shell_script = <<~'SH'
  set -euo pipefail

  RES_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
  BUNDLE_CONTENTS_DIR="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}"
  LIB_DIR="${BUNDLE_CONTENTS_DIR}/lib"
  mkdir -p "${RES_DIR}"

  find_whisper() {
    for p in \
      "${WISPR_WHISPER_CLI_PATH:-}" \
      "${PROJECT_DIR}/whisper-cli" \
      "/opt/homebrew/bin/whisper-cli" \
      "/usr/local/bin/whisper-cli" \
      "/opt/homebrew/bin/main" \
      "/usr/local/bin/main"
    do
      if [ -n "${p}" ] && [ -x "${p}" ]; then
        echo "${p}"
        return 0
      fi
    done
    return 1
  }

  if WHISPER_SRC="$(find_whisper)"; then
    cp -f "${WHISPER_SRC}" "${RES_DIR}/whisper-cli"
    chmod 755 "${RES_DIR}/whisper-cli"
    echo "Bundled whisper-cli from ${WHISPER_SRC}"

    resolve_dep() {
      local dep="$1"
      local base
      base="$(basename "${dep}")"
      for d in \
        "${WISPR_WHISPER_LIB_DIR:-}" \
        "$(dirname "${WHISPER_SRC}")/../lib" \
        "$(dirname "${WHISPER_SRC}")/../libexec/lib" \
        "/opt/homebrew/opt/whisper-cpp/lib" \
        "/opt/homebrew/opt/whisper-cpp/libexec/lib" \
        "/usr/local/opt/whisper-cpp/lib" \
        "/usr/local/opt/whisper-cpp/libexec/lib"
      do
        if [ -n "${d}" ] && [ -e "${d}/${base}" ]; then
          echo "${d}/${base}"
          return 0
        fi
      done
      return 1
    }

    mkdir -p "${LIB_DIR}"
    deps_file="$(mktemp)"
    otool -L "${WHISPER_SRC}" | awk 'NR>1 {print $1}' | grep '^@rpath/' > "${deps_file}" || true
    while IFS= read -r dep; do
      [ -n "${dep}" ] || continue
      if SRC_DEP="$(resolve_dep "${dep}")"; then
        cp -fL "${SRC_DEP}" "${LIB_DIR}/$(basename "${dep}")"
        echo "Bundled whisper lib $(basename "${dep}") from ${SRC_DEP}"
      else
        echo "warning: could not resolve whisper dependency ${dep}"
      fi
    done < "${deps_file}"
    rm -f "${deps_file}"
  else
    echo "warning: whisper-cli not found at build time (set WISPR_WHISPER_CLI_PATH to force a custom path)."
  fi

  if [ -n "${WISPR_BUNDLED_MODEL_PATH:-}" ]; then
    if [ -f "${WISPR_BUNDLED_MODEL_PATH}" ]; then
      mkdir -p "${RES_DIR}/Models"
      cp -f "${WISPR_BUNDLED_MODEL_PATH}" "${RES_DIR}/Models/$(basename "${WISPR_BUNDLED_MODEL_PATH}")"
      echo "Bundled model from ${WISPR_BUNDLED_MODEL_PATH}"
    else
      echo "warning: WISPR_BUNDLED_MODEL_PATH points to a missing file: ${WISPR_BUNDLED_MODEL_PATH}"
    fi
  fi
SH

target.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.jojo.wisprlocal'
  config.build_settings['INFOPLIST_FILE'] = 'WisprLocal/Info.plist'
  config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '13.0'
  config.build_settings['SWIFT_VERSION'] = '6.0'
  config.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'

  # Keep local dev friction low; user can set their Team in Xcode.
  config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
  config.build_settings['DEVELOPMENT_TEAM'] = ''
end

project.save

puts "Generated #{PROJECT_PATH}"
