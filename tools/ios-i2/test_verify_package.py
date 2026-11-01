"""Synthetic-only tests for the I2 unsigned IPA package contract."""

from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import plistlib
import tempfile
import unittest
from pathlib import Path
from typing import Any


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SPEC = importlib.util.spec_from_file_location("ios_i2_verify_package", HERE / "verify_package.py")
assert SPEC is not None and SPEC.loader is not None
verifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verifier)

HELPER_SPEC = importlib.util.spec_from_file_location(
    "ios_i2_reused_i1_fixture_helpers", ROOT / "tools" / "ios-i1" / "test_verify_package.py"
)
assert HELPER_SPEC is not None and HELPER_SPEC.loader is not None
fixtures = importlib.util.module_from_spec(HELPER_SPEC)
HELPER_SPEC.loader.exec_module(fixtures)

REVISION = "0123456789abcdef0123456789abcdef01234567"
OTHER_REVISION = "89abcdef0123456789abcdef0123456789abcdef"
APP_ROOT = "Payload/Runner.app"
RUNNER_PATH = verifier._I1.RUNNER_EXECUTABLE_PATH
INFO_PATH = verifier._I1.APP_INFO_PATH
MANIFEST_PATH = "Payload/Runner.app/ios-i2-provenance.json"
SCRIPT_NAMES = ("jw_probe.js", "young_transport.js")


def source_path(name: str) -> Path:
    return ROOT / "app" / "android" / "app" / "src" / "main" / "assets" / "ustc" / name


def source_bytes(name: str) -> bytes:
    return source_path(name).read_bytes().replace(b"\r\n", b"\n")


def source_hashes() -> dict[str, str]:
    return {name: hashlib.sha256(source_bytes(name)).hexdigest() for name in SCRIPT_NAMES}


def manifest(*, revision: str = REVISION, updates: dict[str, Any] | None = None) -> bytes:
    value: dict[str, Any] = {
        "schemaVersion": 1,
        "kind": "ios-i2-unsigned-ipa-v1",
        "sourceRevision": revision,
        "flutterVersion": "3.47.7",
        "xcodeVersion": "27.1",
        "buildMode": "release",
        "bundleId": "cn.ustcassistant.ios.private",
        "scope": "i2-school-bridges",
        "widget": False,
        "speech": False,
        "authentication": "manual",
        "schoolStore": "wk-uuid-v1",
        "schoolScripts": source_hashes(),
    }
    value.update(updates or {})
    return json.dumps(value, separators=(",", ":")).encode("utf-8")


def runner_info(
    *,
    revision: str = REVISION,
    i1_revision: str | None = None,
    bundle_id: str = "cn.ustcassistant.ios.private",
    supported: list[str] | None = None,
    extras: dict[str, Any] | None = None,
) -> bytes:
    value: dict[str, Any] = {
        "CFBundleIdentifier": bundle_id,
        "CFBundleExecutable": "Runner",
        "CFBundleSupportedPlatforms": supported or ["iPhoneOS"],
        "I1SourceRevision": i1_revision or revision,
        "I2SourceRevision": revision,
    }
    value.update(extras or {})
    return plistlib.dumps(value, fmt=plistlib.FMT_BINARY)


def fixture_members(
    *,
    runner_platform: int = 2,
    app_framework_platform: int = 2,
    flutter_platform: int = 2,
    i1_revision: str = REVISION,
    i2_revision: str = REVISION,
    aot_revision: bool = True,
    runner_supported: list[str] | None = None,
    info_extras: dict[str, Any] | None = None,
    runner_payload: bytes = b"synthetic-runner",
    manifest_updates: dict[str, Any] | None = None,
    script_updates: dict[str, bytes] | None = None,
    omit_scripts: set[str] | None = None,
    extra_members: list[tuple[str, bytes, int | None]] | None = None,
) -> list[tuple[str, bytes, int | None]]:
    base_members = fixtures.fixture_members(
        runner_platform=runner_platform,
        app_framework_platform=app_framework_platform,
        flutter_platform=flutter_platform,
        aot_revision=aot_revision,
        runner_supported=runner_supported,
    )
    result: list[tuple[str, bytes, int | None]] = []
    for name, data, attr in base_members:
        if name == fixtures.MANIFEST_PATH:
            result.append((MANIFEST_PATH, manifest(updates=manifest_updates), attr))
        elif name == INFO_PATH:
            result.append((
                name,
                runner_info(revision=i2_revision, i1_revision=i1_revision, extras=info_extras),
                attr,
            ))
        elif name == RUNNER_PATH:
            result.append((name, fixtures.macho(2, platform=runner_platform, payload=runner_payload), attr))
        else:
            result.append((name, data, attr))

    script_updates = script_updates or {}
    omit_scripts = omit_scripts or set()
    for name in SCRIPT_NAMES:
        if name not in omit_scripts:
            result.append((f"{APP_ROOT}/{name}", script_updates.get(name, source_bytes(name)), None))
    result.extend(extra_members or [])
    return result


def write_ipa(path: Path, members: list[tuple[str, bytes, int | None]]) -> Path:
    return fixtures.write_ipa(path, members)


class VerifyI2PackageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="ios-i2-test-", dir=str(HERE))
        self.root = Path(self.temp.name)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def ipa(self, name: str = "candidate.ipa", **kwargs: Any) -> Path:
        return write_ipa(self.root / name, fixture_members(**kwargs))

    def assert_reason(self, code: str, callback: Any) -> None:
        with self.assertRaises(verifier.VerificationError) as caught:
            callback()
        self.assertEqual(caught.exception.code, code)

    def test_valid_package_report_and_cli(self) -> None:
        ipa = self.ipa()
        report_path = self.root / "verification.json"
        report = verifier.verify_package(ipa, REVISION, report_path)
        self.assertEqual(report["artifactKind"], "ios-i2-unsigned-ipa-v1")
        self.assertEqual(report["scope"], "i2-school-bridges")
        self.assertEqual(report["sourceRevision"], REVISION)
        self.assertEqual(report["bundleId"], "cn.ustcassistant.ios.private")
        self.assertEqual(report["appleSignatureValidity"], "not-verified")
        self.assertEqual(report["ipaSha256"], hashlib.sha256(ipa.read_bytes()).hexdigest())
        self.assertEqual(report["ipaBytes"], ipa.stat().st_size)
        self.assertTrue(all(report["checks"].values()))
        self.assertEqual(
            set(report["checks"]),
            {
                "archivePathsAndSizes",
                "singleRunnerNoExtensionsOrPlugins",
                "deviceArm64RunnerAndFrameworks",
                "sourceRevisionMatchesRunnerAndAOT",
                "noAppGroupInfoEntitlementFilesOrSignatureEntitlements",
                "noProfilesPrivateKeysOrDebugAssets",
                "noAudioPermissionOrModelWeights",
                "fixedSchoolReadersMatchSource",
                "noFixtureEntryPointsOrTransportOverrides",
            },
        )
        self.assertEqual(json.loads(report_path.read_text(encoding="utf-8")), report)
        self.assertNotIn(str(ipa), report_path.read_text(encoding="utf-8"))

        cli_report = self.root / "cli-report.json"
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = verifier.main([
                "--ipa", str(ipa),
                "--expected-revision", REVISION,
                "--report", str(cli_report),
            ])
        self.assertEqual(result, 0)
        self.assertEqual(stderr.getvalue(), "")
        self.assertEqual(json.loads(stdout.getvalue()), report)
        self.assertEqual(json.loads(cli_report.read_text(encoding="utf-8")), report)

    def test_i2_manifest_is_exact_and_revision_is_bound_to_both_info_keys(self) -> None:
        ipa = self.ipa(manifest_updates={"extra": True})
        self.assert_reason("invalid_manifest", lambda: verifier.verify_package(ipa, REVISION))

        ipa = self.ipa(manifest_updates={"authentication": "automatic"})
        self.assert_reason("invalid_manifest", lambda: verifier.verify_package(ipa, REVISION))

        ipa = self.ipa(manifest_updates={"schoolScripts": {"jw_probe.js": "0" * 64}})
        self.assert_reason("invalid_manifest", lambda: verifier.verify_package(ipa, REVISION))

        ipa = self.ipa(i2_revision=OTHER_REVISION)
        self.assert_reason("source_revision_mismatch", lambda: verifier.verify_package(ipa, REVISION))

        ipa = self.ipa(i1_revision=OTHER_REVISION)
        self.assert_reason("source_revision_mismatch", lambda: verifier.verify_package(ipa, REVISION))

    def test_fixed_reader_bytes_must_match_manifest_and_checkout(self) -> None:
        ipa = self.ipa(manifest_updates={"schoolScripts": {name: "0" * 64 for name in SCRIPT_NAMES}})
        self.assert_reason("fixed_school_reader_mismatch", lambda: verifier.verify_package(ipa, REVISION))

        changed = source_bytes("jw_probe.js") + b"\n// synthetic tamper"
        ipa = self.ipa(script_updates={"jw_probe.js": changed})
        self.assert_reason("fixed_school_reader_mismatch", lambda: verifier.verify_package(ipa, REVISION))

        # Windows checkout line endings do not change the reviewed LF source.
        # The bundle itself may not rewrite bytes, even with a matching digest.
        crlf_bundle = source_bytes("jw_probe.js").replace(b"\n", b"\r\n")
        rewritten_hashes = source_hashes()
        rewritten_hashes["jw_probe.js"] = hashlib.sha256(crlf_bundle).hexdigest()
        ipa = self.ipa(
            script_updates={"jw_probe.js": crlf_bundle},
            manifest_updates={"schoolScripts": rewritten_hashes},
        )
        self.assert_reason("fixed_school_reader_mismatch", lambda: verifier.verify_package(ipa, REVISION))

        ipa = self.ipa(omit_scripts={"young_transport.js"})
        self.assert_reason("missing_required_member", lambda: verifier.verify_package(ipa, REVISION))

    def test_release_info_has_no_ats_camera_or_location_permissions(self) -> None:
        ipa = self.ipa(info_extras={"NSAppTransportSecurity": {"NSAllowsLocalNetworking": True}})
        self.assert_reason("transport_override_present", lambda: verifier.verify_package(ipa, REVISION))

        for key in ("NSCameraUsageDescription", "NSLocationWhenInUseUsageDescription"):
            with self.subTest(key=key):
                ipa = self.ipa(info_extras={key: "synthetic"})
                self.assert_reason("restricted_permission_present", lambda: verifier.verify_package(ipa, REVISION))

    def test_runner_binary_contains_no_i2_only_debug_method_names(self) -> None:
        for marker in (b"i2Fixture", b"i2StoreExists"):
            with self.subTest(marker=marker):
                ipa = self.ipa(runner_payload=b"synthetic-runner-" + marker + b"-tail")
                self.assert_reason("fixture_entry_point_present", lambda: verifier.verify_package(ipa, REVISION))

        split_marker = b"i2StoreExists"
        crossing_payload = b"x" * (64 * 1024 - 4) + split_marker + b"tail"
        ipa = self.ipa(runner_payload=crossing_payload)
        self.assert_reason("fixture_entry_point_present", lambda: verifier.verify_package(ipa, REVISION))

    def test_shared_device_architecture_and_aot_checks_apply_to_i2(self) -> None:
        ipa = self.ipa(runner_platform=7)
        self.assert_reason("macho_platform_mismatch", lambda: verifier.verify_package(ipa, REVISION))

        ipa = self.ipa(aot_revision=False)
        self.assert_reason("aot_revision_missing", lambda: verifier.verify_package(ipa, REVISION))

    def test_only_stage_one_or_two_is_accepted_by_shared_auditor(self) -> None:
        ipa = self.ipa()
        for stage in (0, 3, True, 2.0, "2"):
            with self.subTest(stage=stage):
                self.assert_reason(
                    "invalid_stage",
                    lambda: verifier._I1.verify_package(ipa, REVISION, stage=stage),
                )


if __name__ == "__main__":
    unittest.main()
