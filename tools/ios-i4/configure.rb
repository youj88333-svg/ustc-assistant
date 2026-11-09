#!/usr/bin/env ruby
require 'pathname'
require 'xcodeproj'

abort 'i4 configuration failed: invalid_revision' unless ARGV.length == 2 && ARGV[0].match?(/\A[0-9a-f]{40}\z/) && %w[debug release].include?(ARGV[1])
repo = Pathname.new(__dir__).join('../..').realpath
# Operates only inside the disposable Mac build checkout, retaining the private
# identity, storage, source readers, notifications and diagnostic export.
load repo.join('tools/ios-i3/configure.rb').to_s
project = Xcodeproj::Project.open(repo.join('app/ios/Runner.xcodeproj').to_s)
host = project.targets.find { |target| target.name == 'Runner' }
required = %w[IOSDiagnosticExportPolicy.swift IOSDiagnosticExportBridge.swift IOSAgentImagePolicy.swift IOSAgentImageBridge.swift IOSAgentHostLifecycleBridge.swift]
abort 'i4 configuration failed: missing_native_source' unless (required - host.source_build_phase.files_references.map(&:path)).empty?
info_path = repo.join('app/ios/Runner/Info.plist')
info = Xcodeproj::Plist.read_from_path(info_path.to_s)
%w[NSPhotoLibraryUsageDescription NSPhotoLibraryAddUsageDescription].each do |key|
  abort 'i4 configuration failed: unexpected_photo_permission' if info.key?(key)
end
info['I4SourceRevision'] = ARGV[0]
info['CFBundleDisplayName'] = 'USTC Assistant'
Xcodeproj::Plist.write_to_path(info, info_path.to_s)
puts "i4 configuration: single conversation, system photo picker, #{ARGV[1]}"
