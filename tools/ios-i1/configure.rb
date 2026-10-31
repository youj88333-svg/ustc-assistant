#!/usr/bin/env ruby
require 'pathname'
require 'xcodeproj'

abort 'i1 configuration failed: invalid_revision' unless ARGV.length == 1 && ARGV[0].match?(/\A[0-9a-f]{40}\z/)
repo = Pathname.new(__dir__).join('../..').realpath
ios = repo.join('app/ios')
project = Xcodeproj::Project.open(ios.join('Runner.xcodeproj').to_s)
abort 'i1 configuration failed: unexpected_targets' unless project.targets.map(&:name).sort == %w[Runner RunnerTests]
project.build_configurations.each { |c| c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0' }
project.targets.each do |target|
  target.build_configurations.each do |c|
    c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
    c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = target.name == 'Runner' ? 'cn.ustcassistant.ios.private' : 'cn.ustcassistant.ios.private.RunnerTests'
    abort 'i1 configuration failed: unexpected_entitlements' if c.build_settings['CODE_SIGN_ENTITLEMENTS']
  end
end
host = project.targets.find { |t| t.name == 'Runner' }
required = %w[AppDelegate.swift IOSCredentialVault.swift IOSPrivateStorage.swift SceneDelegate.swift]
compiled = host.source_build_phase.files_references.map(&:path)
abort 'i1 configuration failed: missing_native_source' unless (required - compiled).empty?
project.save
info_path = ios.join('Runner/Info.plist')
info = Xcodeproj::Plist.read_from_path(info_path.to_s)
%w[NSMicrophoneUsageDescription NSSpeechRecognitionUsageDescription ALTAppGroups].each do |key|
  abort 'i1 configuration failed: disabled_capability' if info.key?(key)
end
info['I1SourceRevision'] = ARGV[0]
info['CFBundleDisplayName'] = 'USTC Assistant I1'
Xcodeproj::Plist.write_to_path(info, info_path.to_s)
framework_path = ios.join('Flutter/AppFrameworkInfo.plist')
framework_info = Xcodeproj::Plist.read_from_path(framework_path.to_s)
framework_info['MinimumOSVersion'] = '15.0'
Xcodeproj::Plist.write_to_path(framework_info, framework_path.to_s)
puts 'i1 configuration: single Runner, iOS 15+, no Widget/group/audio permissions'
