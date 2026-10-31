#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$repo"
[[ "$(uname -s)" == Darwin ]] || { echo 'i1 build failed: macos_required' >&2; exit 2; }
revision="$(git rev-parse --verify HEAD)"
[[ "$revision" =~ ^[0-9a-f]{40}$ && ( -z "${CM_COMMIT:-}" || "$CM_COMMIT" == "$revision" ) ]] || exit 2
output="$repo/app/build/ios-i1/artifacts"
mkdir -p "$output" "$repo/app/build/ios-i1/temp"
export TMPDIR="$repo/app/build/ios-i1/temp/"
export PYTHONDONTWRITEBYTECODE=1
exec > >(tee "$output/i1-build.log") 2>&1
flutter_version="$(flutter --version --machine | python3 -c 'import json,sys; print(json.load(sys.stdin)["frameworkVersion"])')"
[[ "$flutter_version" == '3.47.7' ]] || { echo 'i1 build failed: unexpected_flutter'; exit 2; }
xcodebuild -version | tee "$output/i1-xcode.txt"
grep -q '^Xcode 27.1$' "$output/i1-xcode.txt" || exit 2
clang -std=c11 -Wall -Wextra -Werror -O2 app/native/directory_darwin.c verification/ios-i1/directory_darwin_test.c -o "$TMPDIR/i1-owner-test"
"$TMPDIR/i1-owner-test"
swiftc app/ios/Runner/IOSCredentialVault.swift verification/ios-i1/vault_main.swift -o "$TMPDIR/i1-vault-test"
"$TMPDIR/i1-vault-test"
python3 tools/ios-i1/test_verify_package.py
ruby tools/ios-i1/configure.rb "$revision"
cd "$repo/app"
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub test/platform/ios*test.dart

# Create only this job's synthetic simulator. No user or pre-existing device.
xcrun simctl list runtimes -j > "$TMPDIR/runtimes.json"
xcrun simctl list devicetypes -j > "$TMPDIR/device-types.json"
read -r runtime device_type < <(python3 - "$TMPDIR" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
r = [x for x in json.loads((p/'runtimes.json').read_text())['runtimes'] if x.get('isAvailable') and x['identifier'].startswith('com.apple.CoreSimulator.SimRuntime.iOS-27')]
d = json.loads((p/'device-types.json').read_text())['devicetypes']
device = next((x for x in d if x['identifier'].endswith('.iPhone-15-Pro')), None)
assert r and device, 'i1 simulator requirements unavailable'
print(sorted(r, key=lambda x: x['version'], reverse=True)[0]['identifier'], device['identifier'])
PY
)
simulator="$(xcrun simctl create USTC-I1-synthetic "$device_type" "$runtime")"
[[ "$simulator" =~ ^[0-9A-Fa-f-]{36}$ ]] || exit 2
trap 'xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true; xcrun simctl delete "$simulator" >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$simulator"
xcrun simctl bootstatus "$simulator" -b
flutter test --no-pub integration_test/ios_i1_platform_test.dart -d "$simulator" --dart-define="USTC_BUILD_REVISION=$revision" 2>&1 | tee "$output/i1-simulator-test.log"
xcrun simctl shutdown "$simulator"
xcrun simctl delete "$simulator"
trap - EXIT
base_number="${PROJECT_BUILD_NUMBER:-${BUILD_NUMBER:-1}}"
[[ "$base_number" =~ ^[0-9]{1,8}$ ]] || exit 2
build_number="$((1000 + 10#$base_number))"
flutter build ios --release --no-codesign --no-pub -t lib/ios_i1_entry.dart --dart-define="USTC_BUILD_REVISION=$revision" --build-name=0.1.0 --build-number="$build_number"
export I1_REVISION="$revision" I1_OUTPUT="$output" I1_APP="$repo/app/build/ios/iphoneos/Runner.app"
python3 - <<'PY'
import json, os, pathlib, zipfile
app = pathlib.Path(os.environ['I1_APP']); out = pathlib.Path(os.environ['I1_OUTPUT'])
assert app.is_dir() and not (app/'PlugIns').exists()
manifest = dict(schemaVersion=1, kind='ios-i1-unsigned-ipa-v1', sourceRevision=os.environ['I1_REVISION'], flutterVersion='3.47.7', xcodeVersion='27.1', buildMode='release', bundleId='cn.ustcassistant.ios.private', scope='i1-storage-bootstrap', widget=False, speech=False)
(app/'ios-i1-provenance.json').write_text(json.dumps(manifest, sort_keys=True, indent=2)+'\n')
(out/'ios-i1-provenance.json').write_text(json.dumps(manifest, sort_keys=True, indent=2)+'\n')
target = out/'ios-i1-unsigned.ipa'
assert not target.exists()
with zipfile.ZipFile(target, 'x', zipfile.ZIP_DEFLATED) as z:
    for p in sorted(app.rglob('*')):
        assert not p.is_symlink(), 'unexpected bundle symlink'
        if p.is_file(): z.write(p, 'Payload/Runner.app/'+p.relative_to(app).as_posix())
PY
cd "$repo"
python3 tools/ios-i1/verify_package.py --ipa "$output/ios-i1-unsigned.ipa" --expected-revision "$revision" --report "$output/ios-i1-verification.json"
