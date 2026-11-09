#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$repo"
[[ "$(uname -s)" == Darwin ]] || { echo 'i4 build failed: macos_required' >&2; exit 2; }
revision="$(git rev-parse --verify HEAD)"
[[ "$revision" =~ ^[0-9a-f]{40}$ && ( -z "${CM_COMMIT:-}" || "$CM_COMMIT" == "$revision" ) ]] || exit 2
output="$repo/app/build/ios-i4/artifacts"
mkdir -p "$output" "$repo/app/build/ios-i4/temp"
export TMPDIR="$repo/app/build/ios-i4/temp/" PYTHONDONTWRITEBYTECODE=1
exec > >(tee "$output/i4-build.log") 2>&1

# Run the new platform primitive before spending time on prerequisite builds.
swiftc app/ios/Runner/IOSAgentImagePolicy.swift verification/ios-i4/image_policy_main.swift -o "$TMPDIR/i4-image-policy-test"
"$TMPDIR/i4-image-policy-test" | tee "$output/i4-image-policy.log"
python3 tools/ios-i4/test_verify_package.py
bash tools/ios-i3/build.sh
for name in i2-build.log i2-xcode.txt i2-auth-compatibility-test.log i2-confirm-light.png i2-alert-dark.png i2-simulator-test.log i2-boundaries-test.log i2-persistence-write.log i2-persistence-read.log ios-i2-verification.json ios-i2-pubspec.lock i3-build.log i3-notifications-test.log i3-shared-jobs-test.log i3-workspace-test.log i3-workspace.png i3-workspace-large-text.png i3-reminders.png ios-i3-verification.json; do
  cp "$repo/app/build/ios-i3/artifacts/$name" "$output/$name"
done
export TMPDIR="$repo/app/build/ios-i4/temp/"
ruby tools/ios-i4/configure.rb "$revision" debug
cd "$repo/app"
flutter analyze --no-pub 2>&1 | tee "$output/i4-analyze.log"
flutter test --no-pub test/platform/ios_i4_product_surface_test.dart test/platform/ios_i4_entry_test.dart test/platform/ios_agent_image_picker_test.dart test/platform/agent_image_picker_test.dart test/agent/gateway_coordinator_contract_test.dart test/agent/model_provider_gateway_test.dart test/agent/agent_reminder_tools_test.dart test/agent/agent_compact_command_test.dart test/app/agent_approval_visibility_test.dart test/app/agent_reasoning_panel_test.dart 2>&1 | tee "$output/i4-shared-test.log"
xcrun simctl list runtimes -j > "$TMPDIR/runtimes.json"
xcrun simctl list devicetypes -j > "$TMPDIR/device-types.json"
read -r runtime device_type < <(python3 "$repo/tools/ios-i1/select_simulator.py" --runtimes "$TMPDIR/runtimes.json" --device-types "$TMPDIR/device-types.json")
printf 'i4 simulator: %s %s\n' "$runtime" "$device_type" | tee "$output/i4-simulator-selection.txt"
simulator="$(xcrun simctl create USTC-I4-synthetic "$device_type" "$runtime")"
[[ "$simulator" =~ ^[0-9A-Fa-f-]{36}$ ]] || exit 2
trap 'xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true; xcrun simctl delete "$simulator" >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$simulator"
xcrun simctl bootstatus "$simulator" -b
flutter test --no-pub --no-uninstall integration_test/ios_i4_product_test.dart -d "$simulator" --dart-define="USTC_BUILD_REVISION=$revision" 2>&1 | tee "$output/i4-product-test.log"
synthetic_container="$(xcrun simctl get_app_container "$simulator" cn.ustcassistant.ios.private data)"
for name in i4-agent i4-approval-keyboard i4-agent-large-text i4-calendar; do
  cp "$synthetic_container/Library/Application Support/ustc_assistant_v1/demo_v1/$name.png" "$output/$name.png"
done
xcrun simctl shutdown "$simulator"
xcrun simctl delete "$simulator"
trap - EXIT

cd "$repo"
ruby tools/ios-i4/configure.rb "$revision" release
cd "$repo/app"
base_number="${PROJECT_BUILD_NUMBER:-${BUILD_NUMBER:-1}}"
[[ "$base_number" =~ ^[0-9]{1,8}$ ]] || exit 2
build_number="$((4000 + 10#$base_number))"
flutter build ios --release --no-codesign --no-pub -t lib/ios_i4_entry.dart --dart-define="USTC_BUILD_REVISION=$revision" --build-name=0.4.0 --build-number="$build_number"
export I4_REVISION="$revision" I4_OUTPUT="$output" I4_APP="$repo/app/build/ios/iphoneos/Runner.app" I4_REPO="$repo"
python3 - <<'PY'
import hashlib, json, os, pathlib, zipfile
app = pathlib.Path(os.environ['I4_APP']); out = pathlib.Path(os.environ['I4_OUTPUT'])
source = pathlib.Path(os.environ['I4_REPO'])/'app/android/app/src/main/assets/ustc'
assert app.is_dir() and not (app/'PlugIns').exists()
scripts = {name: hashlib.sha256((source/name).read_bytes()).hexdigest() for name in ('jw_probe.js', 'young_transport.js')}
manifest = dict(schemaVersion=1, kind='ios-i4-unsigned-ipa-v1', sourceRevision=os.environ['I4_REVISION'], flutterVersion='3.47.7', xcodeVersion='27.1', buildMode='release', bundleId='cn.ustcassistant.ios.private', scope='i4-agent-images', widget=False, speech=False, authentication='manual', schoolStore='wk-uuid-v1', schoolScripts=scripts, notificationBackend='user-notifications-v1', notificationCapacity=60, dailyAuthentication='manual', foregroundOnly=True, diagnosticExport='system-documents-v1', agentInterface='single-conversation-v1', imagePicker='photosui-imageio-v1')
(app/'ios-i4-provenance.json').write_text(json.dumps(manifest, sort_keys=True, indent=2)+'\n')
(out/'ios-i4-provenance.json').write_text(json.dumps(manifest, sort_keys=True, indent=2)+'\n')
target = out/'ios-i4-unsigned.ipa'
assert not target.exists()
with zipfile.ZipFile(target, 'x', zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(app.rglob('*')):
        assert not path.is_symlink(), 'unexpected bundle symlink'
        if path.is_file(): archive.write(path, 'Payload/Runner.app/'+path.relative_to(app).as_posix())
PY
cd "$repo"
python3 tools/ios-i4/verify_package.py --ipa "$output/ios-i4-unsigned.ipa" --expected-revision "$revision" --report "$output/ios-i4-verification.json"
