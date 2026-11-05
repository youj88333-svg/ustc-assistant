#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$repo"
[[ "$(uname -s)" == Darwin ]] || { echo 'i3 build failed: macos_required' >&2; exit 2; }
revision="$(git rev-parse --verify HEAD)"
[[ "$revision" =~ ^[0-9a-f]{40}$ && ( -z "${CM_COMMIT:-}" || "$CM_COMMIT" == "$revision" ) ]] || exit 2
output="$repo/app/build/ios-i3/artifacts"
mkdir -p "$output" "$repo/app/build/ios-i3/temp"
export TMPDIR="$repo/app/build/ios-i3/temp/" PYTHONDONTWRITEBYTECODE=1
exec > >(tee "$output/i3-build.log") 2>&1
swiftc app/ios/Runner/IOSNotificationPolicy.swift verification/ios-i3/policy_main.swift -o "$TMPDIR/i3-policy-test"
"$TMPDIR/i3-policy-test"
python3 tools/ios-i3/test_verify_package.py

# Re-run the unchanged full I1/I2 prerequisite gates on this exact revision,
# including their device AOT and original negative cases. Not a historic pass.
bash tools/ios-i2/build.sh
for name in i2-build.log i2-xcode.txt i2-auth-compatibility-test.log i2-confirm-light.png i2-alert-dark.png i2-simulator-test.log i2-boundaries-test.log i2-persistence-write.log i2-persistence-read.log ios-i2-verification.json ios-i2-pubspec.lock; do
  cp "$repo/app/build/ios-i2/artifacts/$name" "$output/$name"
done
export TMPDIR="$repo/app/build/ios-i3/temp/"
ruby tools/ios-i3/configure.rb "$revision" debug
cd "$repo/app"
flutter test --no-pub test/morning_brief_coordinator_test.dart test/reminder_coordinator_test.dart test/m6_feature_widgets_test.dart test/jobs/young_daily_sync_coordinator_test.dart test/jobs/young_daily_sync_policy_test.dart test/app/young_daily_sync_panel_test.dart 2>&1 | tee "$output/i3-shared-jobs-test.log"
xcrun simctl list runtimes -j > "$TMPDIR/runtimes.json"
xcrun simctl list devicetypes -j > "$TMPDIR/device-types.json"
read -r runtime device_type < <(python3 "$repo/tools/ios-i1/select_simulator.py" --runtimes "$TMPDIR/runtimes.json" --device-types "$TMPDIR/device-types.json")
printf 'i3 simulator: %s %s\n' "$runtime" "$device_type" | tee "$output/i3-simulator-selection.txt"
simulator="$(xcrun simctl create USTC-I3-synthetic "$device_type" "$runtime")"
[[ "$simulator" =~ ^[0-9A-Fa-f-]{36}$ ]] || exit 2
trap 'xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true; xcrun simctl delete "$simulator" >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$simulator"
xcrun simctl bootstatus "$simulator" -b
flutter test --no-pub integration_test/ios_i3_notifications_test.dart -d "$simulator" --dart-define="USTC_BUILD_REVISION=$revision" 2>&1 | tee "$output/i3-notifications-test.log"
# Separate UI journey preserves this job's synthetic installation and no HTTP.
flutter test --no-pub --no-uninstall integration_test/ios_i3_workspace_test.dart -d "$simulator" --dart-define="USTC_BUILD_REVISION=$revision" 2>&1 | tee "$output/i3-workspace-test.log"
synthetic_container="$(xcrun simctl get_app_container "$simulator" cn.ustcassistant.ios.private data)"
for name in i3-workspace i3-reminders; do
  cp "$synthetic_container/Library/Application Support/ustc_assistant_v1/demo_v1/$name.png" "$output/$name.png"
done
xcrun simctl shutdown "$simulator"
xcrun simctl delete "$simulator"
trap - EXIT

cd "$repo"
ruby tools/ios-i3/configure.rb "$revision" release
cd "$repo/app"
base_number="${PROJECT_BUILD_NUMBER:-${BUILD_NUMBER:-1}}"
[[ "$base_number" =~ ^[0-9]{1,8}$ ]] || exit 2
build_number="$((3000 + 10#$base_number))"
flutter build ios --release --no-codesign --no-pub -t lib/ios_i3_entry.dart --dart-define="USTC_BUILD_REVISION=$revision" --build-name=0.3.0 --build-number="$build_number"
export I3_REVISION="$revision" I3_OUTPUT="$output" I3_APP="$repo/app/build/ios/iphoneos/Runner.app" I3_REPO="$repo"
python3 - <<'PY'
import hashlib, json, os, pathlib, zipfile
app = pathlib.Path(os.environ['I3_APP']); out = pathlib.Path(os.environ['I3_OUTPUT'])
source = pathlib.Path(os.environ['I3_REPO'])/'app/android/app/src/main/assets/ustc'
assert app.is_dir() and not (app/'PlugIns').exists()
scripts = {name: hashlib.sha256((source/name).read_bytes()).hexdigest() for name in ('jw_probe.js', 'young_transport.js')}
manifest = dict(schemaVersion=1, kind='ios-i3-unsigned-ipa-v1', sourceRevision=os.environ['I3_REVISION'], flutterVersion='3.47.7', xcodeVersion='27.1', buildMode='release', bundleId='cn.ustcassistant.ios.private', scope='i3-notifications-foreground', widget=False, speech=False, authentication='manual', schoolStore='wk-uuid-v1', schoolScripts=scripts, notificationBackend='user-notifications-v1', notificationCapacity=60, dailyAuthentication='manual', foregroundOnly=True)
(app/'ios-i3-provenance.json').write_text(json.dumps(manifest, sort_keys=True, indent=2)+'\n')
(out/'ios-i3-provenance.json').write_text(json.dumps(manifest, sort_keys=True, indent=2)+'\n')
target = out/'ios-i3-unsigned.ipa'
assert not target.exists()
with zipfile.ZipFile(target, 'x', zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(app.rglob('*')):
        assert not path.is_symlink(), 'unexpected bundle symlink'
        if path.is_file(): archive.write(path, 'Payload/Runner.app/'+path.relative_to(app).as_posix())
PY
cd "$repo"
python3 tools/ios-i3/verify_package.py --ipa "$output/ios-i3-unsigned.ipa" --expected-revision "$revision" --report "$output/ios-i3-verification.json"
