#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$repo"
[[ "$(uname -s)" == Darwin ]] || { echo 'i2 build failed: macos_required' >&2; exit 2; }
revision="$(git rev-parse --verify HEAD)"
[[ "$revision" =~ ^[0-9a-f]{40}$ && ( -z "${CM_COMMIT:-}" || "$CM_COMMIT" == "$revision" ) ]] || exit 2
output="$repo/app/build/ios-i2/artifacts"
mkdir -p "$output" "$repo/app/build/ios-i2/temp"
export TMPDIR="$repo/app/build/ios-i2/temp/"
export PYTHONDONTWRITEBYTECODE=1
exec > >(tee "$output/i2-build.log") 2>&1
flutter_version="$(flutter --version --machine | python3 -c 'import json,sys; print(json.load(sys.stdin)["frameworkVersion"])')"
[[ "$flutter_version" == '3.47.7' ]] || { echo 'i2 build failed: unexpected_flutter'; exit 2; }
xcodebuild -version | tee "$output/i2-xcode.txt"
grep -q '^Xcode 27.1$' "$output/i2-xcode.txt" || exit 2

# Recheck the proven C sandbox case on this same host before the Swift ledger.
clang -std=c11 -Wall -Wextra -Werror -O2 app/native/directory_darwin.c verification/ios-i1/directory_darwin_test.c -o "$TMPDIR/i2-owner-test"
"$TMPDIR/i2-owner-test"
# The new ledger must work without enumerating the app container's ancestors.
# Its CLI includes a real sandbox child plus atomic-swap failure recovery.
swiftc app/ios/Runner/IOSSchoolPolicy.swift app/ios/Runner/IOSSchoolStoreLedger.swift verification/ios-i2/ledger_main.swift -o "$TMPDIR/i2-ledger-test"
"$TMPDIR/i2-ledger-test"
swiftc app/ios/Runner/IOSSchoolPolicy.swift app/ios/Runner/IOSSchoolScripts.swift verification/ios-i2/scripts_main.swift -o "$TMPDIR/i2-scripts-test"
"$TMPDIR/i2-scripts-test" "$repo"
swiftc app/ios/Runner/IOSCredentialVault.swift verification/ios-i1/vault_main.swift -o "$TMPDIR/i2-vault-test"
"$TMPDIR/i2-vault-test"
python3 tools/ios-i1/test_verify_package.py
python3 tools/ios-i2/test_verify_package.py
python3 tools/ios-i1/test_select_simulator.py
ruby tools/ios-i2/configure.rb "$revision" debug
cd "$repo/app"
# This SDK-specific lock belongs only to the disposable Mac checkout.
cp "$repo/tools/ios-i1/pubspec.lock" pubspec.lock
flutter pub get --enforce-lockfile
cp pubspec.lock "$output/ios-i2-pubspec.lock"
flutter analyze --no-pub
flutter test --no-pub test/platform/ios*test.dart

# Never use a pre-existing/user simulator or connect to a physical device.
xcrun simctl list runtimes -j > "$TMPDIR/runtimes.json"
xcrun simctl list devicetypes -j > "$TMPDIR/device-types.json"
read -r runtime device_type < <(python3 "$repo/tools/ios-i1/select_simulator.py" --runtimes "$TMPDIR/runtimes.json" --device-types "$TMPDIR/device-types.json")
printf 'i2 simulator: %s %s\n' "$runtime" "$device_type" | tee "$output/i2-simulator-selection.txt"
simulator="$(xcrun simctl create USTC-I2-synthetic "$device_type" "$runtime")"
[[ "$simulator" =~ ^[0-9A-Fa-f-]{36}$ ]] || exit 2
trap 'xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true; xcrun simctl delete "$simulator" >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$simulator"
xcrun simctl bootstatus "$simulator" -b
flutter test --no-pub integration_test/ios_i2_boundaries_test.dart -d "$simulator" --dart-define="USTC_BUILD_REVISION=$revision" 2>&1 | tee "$output/i2-boundaries-test.log"
flutter test --no-pub integration_test/ios_i2_school_test.dart -d "$simulator" --dart-define="USTC_BUILD_REVISION=$revision" 2>&1 | tee "$output/i2-simulator-test.log"
# The transaction suite binds a synthetic account. Start the persistence pair
# with a fresh installation on this job-owned simulator, then preserve it
# unchanged between write/read. No existing device or personal app is touched.
xcrun simctl uninstall "$simulator" cn.ustcassistant.ios.private
flutter test --no-pub integration_test/ios_i2_persistence_test.dart -d "$simulator" --dart-define="USTC_BUILD_REVISION=$revision" --dart-define=USTC_I2_PERSISTENCE_PHASE=write 2>&1 | tee "$output/i2-persistence-write.log"
# The first flutter-test process has exited. Explicit termination additionally
# prevents a surviving app process from turning the next phase into a reopen.
xcrun simctl terminate "$simulator" cn.ustcassistant.ios.private >/dev/null 2>&1 || true
flutter test --no-pub integration_test/ios_i2_persistence_test.dart -d "$simulator" --dart-define="USTC_BUILD_REVISION=$revision" --dart-define=USTC_I2_PERSISTENCE_PHASE=read 2>&1 | tee "$output/i2-persistence-read.log"
xcrun simctl shutdown "$simulator"
xcrun simctl delete "$simulator"
trap - EXIT

# The loopback HTTP exception and debug probes must not reach the device IPA.
cd "$repo"
ruby tools/ios-i2/configure.rb "$revision" release
cd "$repo/app"
base_number="${PROJECT_BUILD_NUMBER:-${BUILD_NUMBER:-1}}"
[[ "$base_number" =~ ^[0-9]{1,8}$ ]] || exit 2
build_number="$((2000 + 10#$base_number))"
flutter build ios --release --no-codesign --no-pub -t lib/ios_i2_entry.dart --dart-define="USTC_BUILD_REVISION=$revision" --build-name=0.2.0 --build-number="$build_number"
export I2_REVISION="$revision" I2_OUTPUT="$output" I2_APP="$repo/app/build/ios/iphoneos/Runner.app" I2_REPO="$repo"
python3 - <<'PY'
import hashlib, json, os, pathlib, zipfile
app = pathlib.Path(os.environ['I2_APP']); out = pathlib.Path(os.environ['I2_OUTPUT'])
source = pathlib.Path(os.environ['I2_REPO'])/'app/android/app/src/main/assets/ustc'
assert app.is_dir() and not (app/'PlugIns').exists()
scripts = {name: hashlib.sha256((source/name).read_bytes()).hexdigest() for name in ('jw_probe.js', 'young_transport.js')}
manifest = dict(schemaVersion=1, kind='ios-i2-unsigned-ipa-v1', sourceRevision=os.environ['I2_REVISION'], flutterVersion='3.47.7', xcodeVersion='27.1', buildMode='release', bundleId='cn.ustcassistant.ios.private', scope='i2-school-bridges', widget=False, speech=False, authentication='manual', schoolStore='wk-uuid-v1', schoolScripts=scripts)
(app/'ios-i2-provenance.json').write_text(json.dumps(manifest, sort_keys=True, indent=2)+'\n')
(out/'ios-i2-provenance.json').write_text(json.dumps(manifest, sort_keys=True, indent=2)+'\n')
target = out/'ios-i2-unsigned.ipa'
assert not target.exists()
with zipfile.ZipFile(target, 'x', zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(app.rglob('*')):
        assert not path.is_symlink(), 'unexpected bundle symlink'
        if path.is_file(): archive.write(path, 'Payload/Runner.app/'+path.relative_to(app).as_posix())
PY
cd "$repo"
python3 tools/ios-i2/verify_package.py --ipa "$output/ios-i2-unsigned.ipa" --expected-revision "$revision" --report "$output/ios-i2-verification.json"
