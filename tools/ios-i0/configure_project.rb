#!/usr/bin/env ruby
# Configure a generated Flutter shell, never the production app project.
require 'fileutils'
require 'open3'
require 'pathname'
require 'xcodeproj'

def fail_i0(reason)
  abort "i0 configuration failed: #{reason}"
end

unless ARGV.length == 2 && ARGV[1].match?(/\A[0-9a-f]{40}\z/)
  fail_i0('invalid_arguments')
end

repo = Pathname.new(__dir__).join('../..').realpath
generated = Pathname.new(ARGV[0]).realpath
expected = repo.join('app/build/ios-i0/flutter_probe')
fail_i0('unexpected_generated_directory') unless generated == expected
revision = ARGV[1]
ios = generated.join('ios')
seed = repo.join('verification/ios-private-probe/native')
project_path = ios.join('Runner.xcodeproj')
project = Xcodeproj::Project.open(project_path.to_s)
host = project.targets.find { |target| target.name == 'Runner' }
fail_i0('runner_missing') unless host
fail_i0('widget_already_configured') if project.targets.any? { |target| target.name == 'I0Widget' }

group_id = 'group.cn.ustcassistant.ios.i0'
app_id = 'cn.ustcassistant.ios.i0'
widget_id = "#{app_id}.widget"

FileUtils.cp(seed.join('AppDelegate.swift'), ios.join('Runner/AppDelegate.swift'))
shared_path = ios.join('I0Shared')
widget_path = ios.join('I0Widget')
FileUtils.mkdir_p([shared_path, widget_path])
FileUtils.cp(seed.join('I0SharedSnapshot.swift'), shared_path.join('I0SharedSnapshot.swift'))
FileUtils.cp(seed.join('ProbeWidget.swift'), widget_path.join('ProbeWidget.swift'))

host_info_path = ios.join('Runner/Info.plist')
host_info = Xcodeproj::Plist.read_from_path(host_info_path.to_s)
host_info.merge!(
  'CFBundleDisplayName' => 'USTC I0',
  'I0SourceRevision' => revision,
  'I0AppGroupBaseIdentifier' => group_id,
  'FlutterDeepLinkingEnabled' => false,
  'CFBundleURLTypes' => [{
    'CFBundleURLName' => app_id,
    'CFBundleURLSchemes' => ['ustc-ios-i0']
  }]
)
# Preserve the SDK template's UIScene manifest and FlutterSceneDelegate.
fail_i0('scene_template_missing') unless host_info['UIApplicationSceneManifest'].is_a?(Hash)
Xcodeproj::Plist.write_to_path(host_info, host_info_path.to_s)

widget_info = {
  'CFBundleDevelopmentRegion' => '$(DEVELOPMENT_LANGUAGE)',
  'CFBundleDisplayName' => 'I0 Shared Marker',
  'CFBundleExecutable' => '$(EXECUTABLE_NAME)',
  'CFBundleIdentifier' => '$(PRODUCT_BUNDLE_IDENTIFIER)',
  'CFBundleInfoDictionaryVersion' => '6.0',
  'CFBundleName' => '$(PRODUCT_NAME)',
  'CFBundlePackageType' => 'XPC!',
  'CFBundleShortVersionString' => '$(FLUTTER_BUILD_NAME)',
  'CFBundleVersion' => '$(FLUTTER_BUILD_NUMBER)',
  'I0SourceRevision' => revision,
  'I0AppGroupBaseIdentifier' => group_id,
  'NSExtension' => { 'NSExtensionPointIdentifier' => 'com.apple.widgetkit-extension' }
}
Xcodeproj::Plist.write_to_path(widget_info, widget_path.join('Info.plist').to_s)
entitlements = { 'com.apple.security.application-groups' => [group_id] }
Xcodeproj::Plist.write_to_path(entitlements, ios.join('Runner/Runner.entitlements').to_s)
Xcodeproj::Plist.write_to_path(entitlements, widget_path.join('I0Widget.entitlements').to_s)

shared_group = project.main_group.new_group('I0Shared', 'I0Shared')
shared_file = shared_group.new_file('I0SharedSnapshot.swift')
host.add_file_references([shared_file])
widget_group = project.main_group.new_group('I0Widget', 'I0Widget')
widget_file = widget_group.new_file('ProbeWidget.swift')
widget_group.new_file('Info.plist')
widget_group.new_file('I0Widget.entitlements')
runner_group = project.main_group.groups.find { |group| group.name == 'Runner' || group.path == 'Runner' }
runner_group.new_file('Runner.entitlements') if runner_group

widget = project.new_target(:app_extension, 'I0Widget', :ios, '17.0', nil, :swift)
widget.add_file_references([widget_file, shared_file])
# Avoid xcodeproj's versioned fallback SDK paths when Xcode gains a new SDK.
sdk_path, sdk_status = Open3.capture2('xcrun', '--sdk', 'iphoneos', '--show-sdk-path')
fail_i0('device_sdk_missing') unless sdk_status.success?
sdk_path = Pathname.new(sdk_path.strip)
framework_references = {}
%w[SwiftUI WidgetKit].each do |name|
  relative = "System/Library/Frameworks/#{name}.framework"
  fail_i0('system_framework_missing') unless sdk_path.join(relative).directory?
  reference = project.frameworks_group.new_file(relative)
  reference.source_tree = 'SDKROOT'
  reference.last_known_file_type = 'wrapper.framework'
  framework_references[name] = reference
  widget.frameworks_build_phase.add_file_reference(reference, true)
end
host.frameworks_build_phase.add_file_reference(framework_references.fetch('WidgetKit'), true)
# new_target also adds Foundation through the helper with a versioned SDK path.
[host, widget].each do |target|
  target.frameworks_build_phase.files.each do |build_file|
    reference = build_file.file_ref
    next unless reference && reference.path
    match = reference.path.match(%r{(?:\A|/)System/Library/Frameworks/([^/]+\.framework)\z})
    next unless match
    relative = "System/Library/Frameworks/#{match[1]}"
    fail_i0('system_framework_missing') unless sdk_path.join(relative).directory?
    reference.path = relative
    reference.source_tree = 'SDKROOT'
  end
end
unless widget.frameworks_build_phase.files.all? { |entry|
  entry.file_ref && entry.file_ref.source_tree == 'SDKROOT' &&
    sdk_path.join(entry.file_ref.path).directory?
}
  fail_i0('widget_framework_reference_invalid')
end
host.add_dependency(widget)
embed = host.new_copy_files_build_phase('Embed App Extensions')
embed.dst_subfolder_spec = '13'
embed.add_file_reference(widget.product_reference, true).settings = {
  'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy']
}
thin_phase = host.build_phases.find { |phase| phase.display_name == 'Thin Binary' }
if thin_phase
  host.build_phases.delete(embed)
  host.build_phases.insert(host.build_phases.index(thin_phase), embed)
end

project.build_configurations.each do |configuration|
  configuration.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
end

[host, widget].each do |target|
  target.build_configurations.each do |configuration|
    settings = configuration.build_settings
    settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
    settings['TARGETED_DEVICE_FAMILY'] = '1'
    settings['SWIFT_VERSION'] = '5.0'
    settings['CODE_SIGNING_ALLOWED'] = 'NO'
    settings['CODE_SIGNING_REQUIRED'] = 'NO'
    settings['CODE_SIGN_IDENTITY'] = ''
    settings['DEVELOPMENT_TEAM'] = ''
    settings['PROVISIONING_PROFILE_SPECIFIER'] = ''
    settings['PRODUCT_BUNDLE_IDENTIFIER'] = target == host ? app_id : widget_id
    settings['CODE_SIGN_ENTITLEMENTS'] = target == host ? 'Runner/Runner.entitlements' : 'I0Widget/I0Widget.entitlements'
    if target == widget
      settings['PRODUCT_NAME'] = 'I0Widget'
      settings['INFOPLIST_FILE'] = 'I0Widget/Info.plist'
      settings['GENERATE_INFOPLIST_FILE'] = 'NO'
      settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
      settings['SKIP_INSTALL'] = 'YES'
      settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
      # Read the Flutter build-number definitions without linking its SPM product.
      flutter_config = host.build_configurations.find { |entry| entry.name == configuration.name }
      configuration.base_configuration_reference = flutter_config.base_configuration_reference
    end
  end
end

project.save
saved = Xcodeproj::Project.open(project_path.to_s)
[saved.targets.find { |target| target.name == 'Runner' },
 saved.targets.find { |target| target.name == 'I0Widget' }].each do |target|
  fail_i0('saved_target_missing') unless target
  target.build_configurations.each do |configuration|
    settings = configuration.build_settings
    source = ios.join(settings.fetch('CODE_SIGN_ENTITLEMENTS'))
    declaration = Xcodeproj::Plist.read_from_path(source.to_s)
    fail_i0('shared_entitlements_mismatch') unless declaration == entitlements
    fail_i0('signing_not_disabled') unless settings['CODE_SIGNING_ALLOWED'] == 'NO'
  end
end
puts 'i0 configuration: runner_and_widget_ready'
