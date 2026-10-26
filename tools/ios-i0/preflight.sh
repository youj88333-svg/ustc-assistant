#!/usr/bin/env bash
# Only synthetic source and SDK metadata. Never dump CI environment or credentials.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$repo"

if [[ "$(uname -s)" != Darwin ]]; then
  echo 'i0 preflight failed: macos_required' >&2
  exit 2
fi
revision="$(git rev-parse --verify HEAD)"
if [[ ! "$revision" =~ ^[0-9a-f]{40}$ ]]; then
  echo 'i0 preflight failed: invalid_source_revision' >&2
  exit 2
fi
if [[ -n "${CM_COMMIT:-}" && "$CM_COMMIT" != "$revision" ]]; then
  echo 'i0 preflight failed: checkout_revision_mismatch' >&2
  exit 2
fi
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  echo 'i0 preflight failed: checkout_not_clean' >&2
  exit 2
fi

output="$repo/app/build/ios-i0/artifacts"
mkdir -p "$output"
export I0_SOURCE_REVISION="$revision"
export I0_OUTPUT_DIRECTORY="$output"
python3 - <<'PY'
import json
import os
import pathlib
import subprocess
import sys

try:
    lines = subprocess.check_output(['xcodebuild', '-version'], text=True).splitlines()
    xcode = next(line.split(' ', 1)[1] for line in lines if line.startswith('Xcode '))
    if xcode != '27.1':
        raise ValueError('unexpected_xcode_version')
    sdk = subprocess.check_output(
        ['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], text=True
    ).strip()
    subprocess.run(['ruby', '-c', 'tools/ios-i0/configure_project.rb'], check=True)
    subprocess.run(['ruby', '-e', 'require "xcodeproj"; require "yaml"; '
                    'c = YAML.load_file("codemagic.yaml"); '
                    'abort "workflow_missing" unless c["workflows"].keys.sort == '
                    '["ios-i0-preflight", "ios-i0-probe"]'], check=True)
    xcodeproj = subprocess.check_output(
        ['ruby', '-e', 'require "xcodeproj"; print Xcodeproj::VERSION'], text=True
    ).strip()
    report = {
        'kind': 'ios-i0-preflight-v1',
        'sourceRevision': os.environ['I0_SOURCE_REVISION'],
        'checkoutVerified': True,
        'xcodeVersion': xcode,
        'deviceSdkVersion': sdk,
        'xcodeprojAvailable': True,
        'xcodeprojVersion': xcodeproj,
        'appleCredentialsRequired': False,
    }
    path = pathlib.Path(os.environ['I0_OUTPUT_DIRECTORY']) / 'i0-preflight.json'
    path.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report))
except (OSError, ValueError, StopIteration, subprocess.CalledProcessError):
    print('i0 preflight failed: native_toolchain_unavailable', file=sys.stderr)
    sys.exit(2)
PY
