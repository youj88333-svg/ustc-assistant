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
echo 'i0 build complete: unsigned_probe_verified; signing_and_device_gates_pending'
