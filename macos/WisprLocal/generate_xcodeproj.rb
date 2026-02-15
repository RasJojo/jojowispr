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
