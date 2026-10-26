#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$repo"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'i0 build failed: macos_required' >&2
  exit 2
fi
revision="$(git rev-parse --verify HEAD)"
if [[ ! "$revision" =~ ^[0-9a-f]{40}$ || ( -n "${CM_COMMIT:-}" && "$CM_COMMIT" != "$revision" ) ]]; then
  echo 'i0 build failed: checkout_revision_mismatch' >&2
  exit 2
fi
output="$repo/app/build/ios-i0/artifacts"
generated="$repo/app/build/ios-i0/flutter_probe"
if [[ -e "$generated" || -L "$generated" ]]; then
  echo 'i0 build failed: generated_directory_already_exists' >&2
  exit 2
fi
mkdir -p "$output"
# This log contains only probe builds, never production profiles or account data.
exec > >(tee "$output/i0-build.log") 2>&1

flutter_version="$(flutter --version --machine | python3 -c 'import json,sys; print(json.load(sys.stdin)["frameworkVersion"])')"
if [[ "$flutter_version" != '3.47.7' ]]; then
  echo 'i0 build failed: unexpected_flutter_version' >&2
  exit 2
fi
build_number="${PROJECT_BUILD_NUMBER:-${BUILD_NUMBER:-1}}"
if [[ ! "$build_number" =~ ^[1-9][0-9]{0,8}$ ]]; then
  echo 'i0 build failed: invalid_build_number' >&2
  exit 2
fi

flutter create --platforms=ios --org=cn.ustcassistant --project-name=ios_i0_probe --no-pub --empty "$generated"
cp "$repo/verification/ios-private-probe/pubspec.yaml" "$generated/pubspec.yaml"
cp "$repo/verification/ios-private-probe/analysis_options.yaml" "$generated/analysis_options.yaml"
cp "$repo/verification/ios-private-probe/lib/main.dart" "$generated/lib/main.dart"
mkdir -p "$generated/test"
# Discard only this newly generated template test; it targets the template MyApp.
rm -f "$generated/test/widget_test.dart"
cp "$repo/verification/ios-private-probe/test/"*.dart "$generated/test/"
ruby "$repo/tools/ios-i0/configure_project.rb" "$generated" "$revision"
cp "$generated/ios/Runner/Runner.entitlements" "$output/Runner.entitlements"
cp "$generated/ios/I0Widget/I0Widget.entitlements" "$output/I0Widget.entitlements"

cd "$generated"
flutter pub get
flutter analyze
flutter test --dart-define="I0_SOURCE_REVISION=$revision"
flutter build ios --release --no-codesign --dart-define="I0_SOURCE_REVISION=$revision" --build-name=0.0.1 --build-number="$build_number"

app="$generated/build/ios/iphoneos/Runner.app"
if [[ ! -d "$app/PlugIns/I0Widget.appex" ]]; then
  echo 'i0 build failed: embedded_widget_missing' >&2
  exit 2
fi
for binary in 'Runner' 'PlugIns/I0Widget.appex/I0Widget' 'Frameworks/App.framework/App' 'Frameworks/Flutter.framework/Flutter'; do
  printf 'i0 device binary %s: ' "$binary"
  xcrun lipo -archs "$app/$binary"
done
export I0_SOURCE_REVISION="$revision"
export I0_APP_DIRECTORY="$app"
export I0_OUTPUT_DIRECTORY="$output"
python3 - <<'PY'
import json
import os
from pathlib import Path

manifest = {
    'schemaVersion': 1,
    'kind': 'ios-i0-unsigned-ipa-v1',
    'sourceRevision': os.environ['I0_SOURCE_REVISION'],
    'flutterVersion': '3.47.7',
    'xcodeVersion': '27.1',
    'buildMode': 'release',
    'artifactStatus': 'unsigned-personal-probe',
    'appBundleId': 'cn.ustcassistant.ios.i0',
    'widgetBundleId': 'cn.ustcassistant.ios.i0.widget',
    'appGroupBase': 'group.cn.ustcassistant.ios.i0',
}
text = json.dumps(manifest, indent=2) + '\n'
(Path(os.environ['I0_APP_DIRECTORY']) / 'ios-i0-provenance.json').write_text(text, encoding='utf-8')
(Path(os.environ['I0_OUTPUT_DIRECTORY']) / 'ios-i0-provenance.json').write_text(text, encoding='utf-8')
PY

staging="$repo/app/build/ios-i0/package"
mkdir -p "$staging/Payload"
ditto "$app" "$staging/Payload/Runner.app"
ditto -c -k --norsrc --keepParent "$staging/Payload" "$output/ios-i0-unsigned.ipa"
python3 "$repo/tools/ios-i0/verify_package.py" --ipa "$output/ios-i0-unsigned.ipa" --expected-revision "$revision" --report "$output/ios-i0-verification.json"

# Separately approved I0 metadata carrier. Preserve the original signature-less
# package above. This copy makes only a request visible to a local resigner;
# ad-hoc signing uses no Apple identity, certificate, account or device profile.
input_staging="$repo/app/build/ios-i0/signing-input"
input_app="$input_staging/Payload/Runner.app"
mkdir -p "$input_staging/Payload"
ditto "$app" "$input_app"
export I0_SIGNING_INPUT_DIRECTORY="$input_app"
python3 - <<'PY'
import json
import os
import plistlib
from pathlib import Path

root = Path(os.environ['I0_SIGNING_INPUT_DIRECTORY'])
group = 'group.cn.ustcassistant.ios.i0'
for relative in ('Info.plist', 'PlugIns/I0Widget.appex/Info.plist'):
    path = root / relative
    with path.open('rb') as source:
        info = plistlib.load(source)
    assert info['I0AppGroupBaseIdentifier'] == group
    info['ALTAppGroups'] = [group]
    with path.open('wb') as destination:
        plistlib.dump(info, destination, fmt=plistlib.FMT_BINARY)
path = root / 'ios-i0-provenance.json'
manifest = json.loads(path.read_text(encoding='utf-8'))
manifest['kind'] = 'ios-i0-signing-input-v1'
manifest['artifactStatus'] = 'adhoc-request-only'
manifest['metadataCarrier'] = 'adhoc-entitlement-request'
manifest['appleDeveloperSignature'] = False
path.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
PY

for framework in 'App' 'Flutter'; do
  /usr/bin/codesign --force --sign - --timestamp=none "$input_app/Frameworks/$framework.framework"
done
/usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der --entitlements "$generated/ios/I0Widget/I0Widget.entitlements" "$input_app/PlugIns/I0Widget.appex"
/usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der --entitlements "$generated/ios/Runner/Runner.entitlements" "$input_app"

python3 - <<'PY'
import json
import os
import plistlib
import subprocess
from pathlib import Path

root = Path(os.environ['I0_SIGNING_INPUT_DIRECTORY'])
expected = {'com.apple.security.application-groups': ['group.cn.ustcassistant.ios.i0']}
for bundle in (root, root / 'PlugIns/I0Widget.appex'):
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
    output = subprocess.run(
        ['/usr/bin/codesign', '--display', '--entitlements', '-', '--xml', str(bundle)],
        check=True, capture_output=True
    )
    if len(output.stdout) > 16384 or plistlib.loads(output.stdout) != expected:
        raise ValueError('unexpected_requested_entitlements')
    metadata = subprocess.run(
        ['/usr/bin/codesign', '--display', '--verbose=4', str(bundle)],
        check=True, capture_output=True, text=True
    )
    if 'Signature=adhoc' not in metadata.stderr:
        raise ValueError('unexpected_signing_identity')
    if (bundle / 'embedded.mobileprovision').exists():
        raise ValueError('unexpected_apple_profile')
report = {
    'kind': 'ios-i0-entitlement-request-v1',
    'sourceRevision': os.environ['I0_SOURCE_REVISION'],
    'metadataCarrier': 'adhoc-entitlement-request',
    'hostAndWidgetRequestVerified': True,
    'appleCredentialsUsed': False,
    'appleProfilePresent': False,
    'appGroupAuthorizationVerified': False,
}
path = Path(os.environ['I0_OUTPUT_DIRECTORY']) / 'ios-i0-entitlement-request.json'
path.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
print(json.dumps(report))
PY
ditto -c -k --norsrc --keepParent "$input_staging/Payload" "$output/ios-i0-signing-input.ipa"
python3 "$repo/tools/ios-i0/verify_package.py" --ipa "$output/ios-i0-signing-input.ipa" --expected-revision "$revision" --report "$output/ios-i0-signing-input-verification.json"
echo 'i0 build complete: unsigned_probe_verified; signing_and_device_gates_pending'
