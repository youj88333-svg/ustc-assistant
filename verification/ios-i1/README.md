# iOS storage and bootstrap checks

The `ios-i1-foundation` Codemagic workflow builds the same Flutter application with a synthetic storage entry point. It does not contact school services or model providers. No Apple account, signing certificate or device profile is used in CI.

`tools/ios-i1/build.sh` runs the Darwin directory-owner harness, the CryptoKit credential-vault harness, Dart port tests and the iOS Simulator integration test before producing a device Release/AOT package. Flutter and Xcode versions are pinned in `codemagic.yaml`. The Python package verifier also runs on Windows with Python 3.10+:

The iOS workflow uses `tools/ios-i1/pubspec.lock` with its pinned Flutter SDK. It copies that lock into the disposable CI checkout and enforces it; the Windows/Android lock at `app/pubspec.lock` stays unchanged. Do not copy the iOS lock into a maintenance checkout using another SDK.

```text
python tools/ios-i1/test_verify_package.py
python tools/ios-i1/verify_package.py --ipa <file> --expected-revision <40-character Git revision> --report <new report path>
```

The package contains one Runner, with no Widget, App Groups request, microphone permission or recognition-model weights. Its base bundle identifier is `cn.ustcassistant.ios.private`. The verifier checks archive structure, device architecture, source provenance and prohibited assets; it does not validate an Apple signature or prove installation and device behavior.

After local signing, the synthetic screen can write and reread a test marker and a synthetic encrypted value. Force-close/reopen, background return and a second installation over the same signed identity must preserve that marker. Do not uninstall between preservation checks. Actual device results and seven-day renewal are separate from simulator/build results.
