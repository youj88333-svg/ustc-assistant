#!/usr/bin/env ruby
require 'pathname'
require 'xcodeproj'

abort 'i3 configuration failed: invalid_revision' unless ARGV.length == 2 && ARGV[0].match?(/\A[0-9a-f]{40}\z/) && %w[debug release].include?(ARGV[1])
repo = Pathname.new(__dir__).join('../..').realpath
# Preserve the proven private identity, school readers and release transport
# rules; this operates only in the disposable Mac checkout.
load repo.join('tools/ios-i2/configure.rb').to_s
project = Xcodeproj::Project.open(repo.join('app/ios/Runner.xcodeproj').to_s)
host = project.targets.find { |target| target.name == 'Runner' }
required = %w[IOSNotificationPolicy.swift IOSNotificationBridge.swift]
abort 'i3 configuration failed: missing_notification_source' unless (required - host.source_build_phase.files_references.map(&:path)).empty?
info_path = repo.join('app/ios/Runner/Info.plist')
info = Xcodeproj::Plist.read_from_path(info_path.to_s)
abort 'i3 configuration failed: unexpected_background_mode' if info.key?('UIBackgroundModes')
info['I3SourceRevision'] = ARGV[0]
info['CFBundleDisplayName'] = 'USTC Assistant'
Xcodeproj::Plist.write_to_path(info, info_path.to_s)
puts "i3 configuration: UserNotifications, app cap 60, foreground jobs, #{ARGV[1]}"
