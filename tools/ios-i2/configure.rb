#!/usr/bin/env ruby
require 'pathname'
require 'xcodeproj'

abort 'i2 configuration failed: invalid_revision' unless ARGV.length == 2 && ARGV[0].match?(/\A[0-9a-f]{40}\z/) && %w[debug release].include?(ARGV[1])
repo = Pathname.new(__dir__).join('../..').realpath
ios = repo.join('app/ios')
project = Xcodeproj::Project.open(ios.join('Runner.xcodeproj').to_s)
abort 'i2 configuration failed: unexpected_targets' unless project.targets.map(&:name).sort == %w[Runner RunnerTests]
project.build_configurations.each { |c| c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0' }
project.targets.each do |target|
  target.build_configurations.each do |c|
    c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
    c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = target.name == 'Runner' ? 'cn.ustcassistant.ios.private' : 'cn.ustcassistant.ios.private.RunnerTests'
    abort 'i2 configuration failed: unexpected_entitlements' if c.build_settings['CODE_SIGN_ENTITLEMENTS']
  end
end
host = project.targets.find { |t| t.name == 'Runner' }
required = %w[AppDelegate.swift IOSCredentialVault.swift IOSPrivateStorage.swift SceneDelegate.swift IOSObservationBridge.swift IOSSchoolPolicy.swift IOSSchoolStoreLedger.swift IOSSchoolScripts.swift]
abort 'i2 configuration failed: missing_native_source' unless (required - host.source_build_phase.files_references.map(&:path)).empty?
# Storyboard variant groups have a name but no file path. The fixed readers
# must still appear as actual resource file references with these basenames.
resources = host.resources_build_phase.files_references.filter_map { |r| File.basename(r.path) if r.path }
abort 'i2 configuration failed: missing_fixed_reader' unless (%w[jw_probe.js young_transport.js] - resources).empty?
project.save
info_path = ios.join('Runner/Info.plist')
info = Xcodeproj::Plist.read_from_path(info_path.to_s)
%w[NSMicrophoneUsageDescription NSSpeechRecognitionUsageDescription ALTAppGroups NSLocationWhenInUseUsageDescription NSCameraUsageDescription].each do |key|
  abort 'i2 configuration failed: disabled_capability' if info.key?(key)
end
info['I1SourceRevision'] = ARGV[0]
info['I2SourceRevision'] = ARGV[0]
info['CFBundleDisplayName'] = 'USTC Assistant I2'
if ARGV[1] == 'debug'
  # Test-only loopback HTTP. Never ship an ATS override in the device package.
  info['NSAppTransportSecurity'] = {'NSAllowsLocalNetworking' => true}
else
  info.delete('NSAppTransportSecurity')
end
Xcodeproj::Plist.write_to_path(info, info_path.to_s)
puts "i2 configuration: single Runner, iOS27+ school bridge, #{ARGV[1]} transport policy"
