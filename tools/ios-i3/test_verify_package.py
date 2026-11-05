"""Synthetic-only tests for the I3 unsigned IPA package contract."""

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


def _load_module(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


verifier = _load_module("ios_i3_verify_package", HERE / "verify_package.py")
i2_fixtures = _load_module(
    "ios_i3_reused_i2_fixture_helpers", ROOT / "tools" / "ios-i2" / "test_verify_package.py"
)

REVISION = "0123456789abcdef0123456789abcdef01234567"
OTHER_REVISION = "89abcdef0123456789abcdef0123456789abcdef"
APP_ROOT = "Payload/Runner.app"
INFO_PATH = verifier._I1.APP_INFO_PATH
RUNNER_PATH = verifier._I1.RUNNER_EXECUTABLE_PATH
APP_FRAMEWORK_EXECUTABLE = verifier._I1.APP_FRAMEWORK_EXECUTABLE
I2_MANIFEST_PATH = "Payload/Runner.app/ios-i2-provenance.json"
MANIFEST_PATH = "Payload/Runner.app/ios-i3-provenance.json"
SCHOOL_SCRIPT_NAMES = ("jw_probe.js", "young_transport.js")
WIRING_MARKERS = verifier._I1.I3_NOTIFICATION_WIRING_MARKERS
RUNNER_NATIVE_PAYLOAD = b"\n".join(WIRING_MARKERS)


def manifest(
    *,
    revision: str = REVISION,
    updates: dict[str, Any] | None = None,
) -> bytes:
    value: dict[str, Any] = {
        "schemaVersion": 1,
        "kind": "ios-i3-unsigned-ipa-v1",
        "sourceRevision": revision,
        "flutterVersion": "3.47.7",
        "xcodeVersion": "27.1",
        "buildMode": "release",
        "bundleId": "cn.ustcassistant.ios.private",
        "scope": "i3-notifications-foreground",
        "widget": False,
        "speech": False,
        "authentication": "manual",
        "schoolStore": "wk-uuid-v1",
        "schoolScripts": i2_fixtures.source_hashes(),
        "notificationBackend": "user-notifications-v1",
        "notificationCapacity": 60,
        "dailyAuthentication": "manual",
        "foregroundOnly": True,
    }
    value.update(updates or {})
    return json.dumps(value, separators=(",", ":")).encode("utf-8")


def runner_info(
    *,
    i1_revision: str = REVISION,
    i2_revision: str = REVISION,
    i3_revision: str = REVISION,
    extras: dict[str, Any] | None = None,
) -> bytes:
    value: dict[str, Any] = {
        "CFBundleIdentifier": "cn.ustcassistant.ios.private",
        "CFBundleExecutable": "Runner",
        "CFBundleSupportedPlatforms": ["iPhoneOS"],
        "I1SourceRevision": i1_revision,
        "I2SourceRevision": i2_revision,
        "I3SourceRevision": i3_revision,
    }
    value.update(extras or {})
    return plistlib.dumps(value, fmt=plistlib.FMT_BINARY)


def fixture_members(
    *,
    manifest_revision: str = REVISION,
    manifest_updates: dict[str, Any] | None = None,
    i1_revision: str = REVISION,
    i2_revision: str = REVISION,
    i3_revision: str = REVISION,
    info_extras: dict[str, Any] | None = None,
    runner_payload: bytes = RUNNER_NATIVE_PAYLOAD,
    runner_signature: bytes | None = None,
    app_framework_payload: bytes | None = None,
    script_updates: dict[str, bytes] | None = None,
    omit_scripts: set[str] | None = None,
    extra_members: list[tuple[str, bytes, int | None]] | None = None,
) -> list[tuple[str, bytes, int | None]]:
    base_members = i2_fixtures.fixture_members(
        i1_revision=i1_revision,
        i2_revision=i2_revision,
        runner_payload=runner_payload,
        script_updates=script_updates,
        omit_scripts=omit_scripts,
    )
    result: list[tuple[str, bytes, int | None]] = []
    for name, data, attr in base_members:
        if name == I2_MANIFEST_PATH:
            result.append((
                MANIFEST_PATH,
                manifest(revision=manifest_revision, updates=manifest_updates),
                attr,
            ))
        elif name == INFO_PATH:
            result.append((
                name,
                runner_info(
                    i1_revision=i1_revision,
                    i2_revision=i2_revision,
                    i3_revision=i3_revision,
                    extras=info_extras,
                ),
                attr,
            ))
        elif name == RUNNER_PATH and runner_signature is not None:
            result.append((
                name,
                i2_fixtures.fixtures.macho(
                    2,
                    platform=2,
                    payload=runner_payload,
                    signature_blob=runner_signature,
                ),
                attr,
            ))
        elif name == APP_FRAMEWORK_EXECUTABLE and app_framework_payload is not None:
            result.append((
                name,
                i2_fixtures.fixtures.macho(
                    6,
                    platform=2,
                    payload=app_framework_payload,
                ),
                attr,
            ))
        else:
            result.append((name, data, attr))
    result.extend(extra_members or [])
    return result


def write_ipa(path: Path, members: list[tuple[str, bytes, int | None]]) -> Path:
    return i2_fixtures.write_ipa(path, members)


class VerifyI3PackageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="ios-i3-test-", dir=str(HERE))
        self.root = Path(self.temp.name)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def ipa(self, name: str = "candidate.ipa", **kwargs: Any) -> Path:
        return write_ipa(self.root / name, fixture_members(**kwargs))

    def assert_reason(self, code: str, callback: Any) -> None:
        with self.assertRaises(verifier.VerificationError) as caught:
            callback()
        self.assertEqual(caught.exception.code, code)

    def test_valid_package_report_and_cli_use_i3_scope(self) -> None:
        ipa = self.ipa()
        report_path = self.root / "verification.json"
        report = verifier.verify_package(ipa, REVISION, report_path)
        self.assertEqual(report["artifactKind"], "ios-i3-unsigned-ipa-v1")
        self.assertEqual(report["scope"], "i3-notifications-foreground")
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
                "notificationNativeWiringStringsPresent",
                "noI3FixtureMarkersInRunnerOrAOT",
                "noBackgroundModesOrRemoteNotificationsEntitlement",
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

    def test_manifest_and_all_three_info_revisions_are_bound(self) -> None:
        ipa = self.ipa(manifest_revision=OTHER_REVISION)
        self.assert_reason("invalid_manifest", lambda: verifier.verify_package(ipa, REVISION))

        for key in ("i1_revision", "i2_revision", "i3_revision"):
            with self.subTest(info_revision=key):
                ipa = self.ipa(**{key: OTHER_REVISION})
                self.assert_reason(
                    "source_revision_mismatch",
                    lambda: verifier.verify_package(ipa, REVISION),
                )

    def test_i3_manifest_is_exact_and_capacity_is_a_fixed_integer(self) -> None:
        for updates in (
            {"extra": True},
            {"notificationCapacity": True},
            {"notificationCapacity": 61},
            {"notificationBackend": "apns"},
            {"dailyAuthentication": "automatic"},
            {"foregroundOnly": False},
        ):
            with self.subTest(updates=updates):
                ipa = self.ipa(manifest_updates=updates)
                self.assert_reason(
                    "invalid_manifest",
                    lambda: verifier.verify_package(ipa, REVISION),
                )

    def test_missing_native_notification_wiring_marker_is_rejected(self) -> None:
        ipa = self.ipa(runner_payload=b"\n".join(WIRING_MARKERS[:-1]))
        self.assert_reason(
            "notification_native_wiring_missing",
            lambda: verifier.verify_package(ipa, REVISION),
        )

    def test_i3_debug_marker_is_rejected_from_runner_and_aot(self) -> None:
        ipa = self.ipa(runner_payload=RUNNER_NATIVE_PAYLOAD + b"|i3Fixture")
        self.assert_reason(
            "fixture_entry_point_present",
            lambda: verifier.verify_package(ipa, REVISION),
        )

        ipa = self.ipa(
            app_framework_payload=b"aot:" + REVISION.encode("ascii") + b"|i3Fixture"
        )
        self.assert_reason(
            "fixture_entry_point_present",
            lambda: verifier.verify_package(ipa, REVISION),
        )

    def test_stage_three_rejects_background_mode_and_remote_push_entitlement(self) -> None:
        ipa = self.ipa(info_extras={"UIBackgroundModes": ["remote-notification"]})
        self.assert_reason("background_mode_present", lambda: verifier.verify_package(ipa, REVISION))

        entitlement = plistlib.dumps({"aps-environment": "development"})
        ipa = self.ipa(extra_members=[(f"{APP_ROOT}/Runner.entitlements", entitlement, None)])
        self.assert_reason(
            "remote_notifications_entitlement_present",
            lambda: verifier.verify_package(ipa, REVISION),
        )

        signature = i2_fixtures.fixtures.signature_superblob(
            entitlements={"aps-environment": "development"}
        )
        ipa = self.ipa(runner_signature=signature)
        self.assert_reason(
            "remote_notifications_entitlement_present",
            lambda: verifier.verify_package(ipa, REVISION),
        )

    def test_school_scripts_must_match_source_bytes_and_manifest(self) -> None:
        changed = i2_fixtures.source_bytes("jw_probe.js") + b"\n// synthetic mutation"
        ipa = self.ipa(script_updates={"jw_probe.js": changed})
        self.assert_reason(
            "fixed_school_reader_mismatch",
            lambda: verifier.verify_package(ipa, REVISION),
        )

        bad_hashes = i2_fixtures.source_hashes()
        bad_hashes["young_transport.js"] = "0" * 64
        ipa = self.ipa(manifest_updates={"schoolScripts": bad_hashes})
        self.assert_reason(
            "fixed_school_reader_mismatch",
            lambda: verifier.verify_package(ipa, REVISION),
        )

    def test_i3_scope_keeps_i2_no_ats_camera_and_location_gates(self) -> None:
        for extras in (
            {"NSAppTransportSecurity": {"NSAllowsLocalNetworking": True}},
            {"NSCameraUsageDescription": "synthetic"},
            {"NSLocationWhenInUseUsageDescription": "synthetic"},
        ):
            with self.subTest(info_extras=extras):
                ipa = self.ipa(info_extras=extras)
                code = (
                    "transport_override_present"
                    if "NSAppTransportSecurity" in extras
                    else "restricted_permission_present"
                )
                self.assert_reason(code, lambda: verifier.verify_package(ipa, REVISION))


if __name__ == "__main__":
    unittest.main()
