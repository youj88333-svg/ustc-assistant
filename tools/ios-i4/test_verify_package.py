"""Synthetic-only tests for the I4 unsigned IPA package contract."""

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


verifier = _load_module("ios_i4_verify_package", HERE / "verify_package.py")
i3_fixtures = _load_module(
    "ios_i4_reused_i3_fixture_helpers", ROOT / "tools" / "ios-i3" / "test_verify_package.py"
)
i2_fixtures = i3_fixtures.i2_fixtures

REVISION = "0123456789abcdef0123456789abcdef01234567"
OTHER_REVISION = "89abcdef0123456789abcdef0123456789abcdef"
APP_ROOT = "Payload/Runner.app"
INFO_PATH = verifier._I1.APP_INFO_PATH
I3_MANIFEST_PATH = verifier._I1.I3_MANIFEST_PATH
MANIFEST_PATH = verifier._I1.I4_MANIFEST_PATH
AGENT_PRODUCT_SURFACE_MARKERS = verifier._I1.I4_AGENT_PRODUCT_SURFACE_MARKERS
AGENT_IMAGE_DISPATCH_MARKERS = verifier._I1.I4_AGENT_IMAGE_DISPATCH_MARKERS

WIRING_MARKERS = (
    verifier._I1.I3_NOTIFICATION_WIRING_MARKERS
    + verifier._I1.I3_DIAGNOSTIC_EXPORT_WIRING_MARKERS
    + verifier._I1.I4_AGENT_IMAGE_WIRING_MARKERS
)
RUNNER_NATIVE_PAYLOAD = b"\n".join(WIRING_MARKERS)


def manifest(
    *,
    revision: str = REVISION,
    updates: dict[str, Any] | None = None,
) -> bytes:
    value: dict[str, Any] = {
        "schemaVersion": 1,
        "kind": "ios-i4-unsigned-ipa-v1",
        "sourceRevision": revision,
        "flutterVersion": "3.47.7",
        "xcodeVersion": "27.1",
        "buildMode": "release",
        "bundleId": verifier._I1.APP_BUNDLE_ID,
        "scope": "i4-agent-images",
        "widget": False,
        "speech": False,
        "authentication": "manual",
        "schoolStore": "wk-uuid-v1",
        "schoolScripts": i2_fixtures.source_hashes(),
        "notificationBackend": "user-notifications-v1",
        "notificationCapacity": 60,
        "dailyAuthentication": "manual",
        "foregroundOnly": True,
        "diagnosticExport": "system-documents-v1",
        "agentInterface": "single-conversation-v1",
        "imagePicker": "photosui-imageio-v1",
    }
    value.update(updates or {})
    return json.dumps(value, separators=(",", ":")).encode("utf-8")


def fixture_members(
    *,
    manifest_revision: str = REVISION,
    manifest_updates: dict[str, Any] | None = None,
    i1_revision: str = REVISION,
    i2_revision: str = REVISION,
    i3_revision: str = REVISION,
    i4_revision: str = REVISION,
    info_extras: dict[str, Any] | None = None,
    runner_payload: bytes = RUNNER_NATIVE_PAYLOAD,
    runner_signature: bytes | None = None,
    app_framework_payload: bytes | None = None,
    script_updates: dict[str, bytes] | None = None,
    omit_scripts: set[str] | None = None,
    extra_members: list[tuple[str, bytes, int | None]] | None = None,
) -> list[tuple[str, bytes, int | None]]:
    if app_framework_payload is None:
        app_framework_payload = (
            b"aot:"
            + REVISION.encode("ascii")
            + b"|"
            + b"\n".join(AGENT_PRODUCT_SURFACE_MARKERS + AGENT_IMAGE_DISPATCH_MARKERS)
        )
    base_members = i3_fixtures.fixture_members(
        i1_revision=i1_revision,
        i2_revision=i2_revision,
        i3_revision=i3_revision,
        runner_payload=runner_payload,
        runner_signature=runner_signature,
        app_framework_payload=app_framework_payload,
        script_updates=script_updates,
        omit_scripts=omit_scripts,
    )
    result: list[tuple[str, bytes, int | None]] = []
    for name, data, attr in base_members:
        if name == I3_MANIFEST_PATH:
            result.append((
                MANIFEST_PATH,
                manifest(revision=manifest_revision, updates=manifest_updates),
                attr,
            ))
        elif name == INFO_PATH:
            info = plistlib.loads(data)
            info["I4SourceRevision"] = i4_revision
            info.update(info_extras or {})
            result.append((name, plistlib.dumps(info, fmt=plistlib.FMT_BINARY), attr))
        else:
            result.append((name, data, attr))
    result.extend(extra_members or [])
    return result


def write_ipa(path: Path, members: list[tuple[str, bytes, int | None]]) -> Path:
    return i3_fixtures.write_ipa(path, members)


class VerifyI4PackageTests(unittest.TestCase):
    def setUp(self) -> None:
        temp_parent = ROOT / "app" / "build" / "ios-i4" / "package-tests"
        temp_parent.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="synthetic-", dir=str(temp_parent))
        self.root = Path(self.temp.name)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def ipa(self, name: str = "candidate.ipa", **kwargs: Any) -> Path:
        return write_ipa(self.root / name, fixture_members(**kwargs))

    def assert_reason(self, code: str, callback: Any) -> None:
        with self.assertRaises(verifier.VerificationError) as caught:
            callback()
        self.assertEqual(caught.exception.code, code)

    def test_valid_synthetic_package_report_and_cli(self) -> None:
        ipa = self.ipa(extra_members=[(f"{APP_ROOT}/flutter_assets/AssetManifest.json", b"{}", None)])
        report_path = self.root / "verification.json"
        report = verifier.verify_package(ipa, REVISION, report_path)
        self.assertEqual(report["artifactKind"], "ios-i4-unsigned-ipa-v1")
        self.assertEqual(report["scope"], "i4-agent-images")
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
                "diagnosticExportNativeWiringStringsPresent",
                "agentImageNativeWiringStringsPresent",
                "agentImageDartDispatchStringsPresent",
                "agentProductSurfaceStringsPresent",
                "noI2I3I4FixtureAndLoopbackMarkersInRunnerOrAOT",
                "noBundledPersistentDataAssetFormats",
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

    def test_manifest_and_all_four_info_revisions_are_bound(self) -> None:
        ipa = self.ipa(manifest_revision=OTHER_REVISION)
        self.assert_reason("invalid_manifest", lambda: verifier.verify_package(ipa, REVISION))

        for key in ("i1_revision", "i2_revision", "i3_revision", "i4_revision"):
            with self.subTest(info_revision=key):
                ipa = self.ipa(**{key: OTHER_REVISION})
                self.assert_reason(
                    "source_revision_mismatch",
                    lambda: verifier.verify_package(ipa, REVISION),
                )

    def test_manifest_is_exact_and_fixed_fields_have_exact_types(self) -> None:
        for updates in (
            {"extra": True},
            {"notificationCapacity": True},
            {"notificationCapacity": 61},
            {"notificationBackend": "apns"},
            {"dailyAuthentication": "automatic"},
            {"foregroundOnly": False},
            {"widget": 0},
            {"speech": True},
            {"agentInterface": "multi-agent"},
            {"imagePicker": "camera-roll"},
            {"diagnosticExport": "arbitrary-file"},
            {"schoolScripts": {"jw_probe.js": "0" * 64}},
        ):
            with self.subTest(updates=updates):
                ipa = self.ipa(manifest_updates=updates)
                self.assert_reason(
                    "invalid_manifest",
                    lambda: verifier.verify_package(ipa, REVISION),
                )

    def test_school_scripts_match_source_and_manifest(self) -> None:
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

        ipa = self.ipa(omit_scripts={"young_transport.js"})
        self.assert_reason("missing_required_member", lambda: verifier.verify_package(ipa, REVISION))

    def test_native_image_notification_and_log_wiring_are_required(self) -> None:
        groups = (
            (verifier._I1.I3_NOTIFICATION_WIRING_MARKERS, "notification_native_wiring_missing"),
            (verifier._I1.I3_DIAGNOSTIC_EXPORT_WIRING_MARKERS, "diagnostic_export_native_wiring_missing"),
            (verifier._I1.I4_AGENT_IMAGE_WIRING_MARKERS, "agent_image_native_wiring_missing"),
        )
        for markers, reason in groups:
            with self.subTest(markers=markers):
                payload = b"\n".join(marker for marker in WIRING_MARKERS if marker not in markers)
                ipa = self.ipa(runner_payload=payload)
                self.assert_reason(reason, lambda: verifier.verify_package(ipa, REVISION))

    def test_agent_product_surface_requires_stable_aot_value_keys(self) -> None:
        for omitted_marker in AGENT_PRODUCT_SURFACE_MARKERS:
            with self.subTest(omitted_marker=omitted_marker):
                retained = b"\n".join(
                    marker for marker in AGENT_PRODUCT_SURFACE_MARKERS if marker != omitted_marker
                )
                payload = b"aot:" + REVISION.encode("ascii") + b"|" + retained
                ipa = self.ipa(app_framework_payload=payload)
                self.assert_reason(
                    "agent_product_surface_missing",
                    lambda: verifier.verify_package(ipa, REVISION),
                )

    def test_optimized_native_methods_still_require_linked_types_and_dart_dispatch(self) -> None:
        # Real Swift Release emits the short pickImages method as immediate
        # SmallString instructions. A contiguous native literal is not an ABI.
        self.assertNotIn(b"pickImages", RUNNER_NATIVE_PAYLOAD)
        verifier.verify_package(self.ipa(), REVISION)
        for omitted in verifier._I1.I4_AGENT_IMAGE_WIRING_MARKERS:
            with self.subTest(native=omitted):
                retained = b"\n".join(m for m in WIRING_MARKERS if m != omitted)
                ipa = self.ipa(runner_payload=retained)
                self.assert_reason(
                    "agent_image_native_wiring_missing",
                    lambda: verifier.verify_package(ipa, REVISION),
                )
        for omitted in AGENT_IMAGE_DISPATCH_MARKERS:
            with self.subTest(dispatch=omitted):
                retained = b"\n".join(
                    m for m in AGENT_PRODUCT_SURFACE_MARKERS + AGENT_IMAGE_DISPATCH_MARKERS
                    if m != omitted
                )
                ipa = self.ipa(app_framework_payload=b"aot:" + REVISION.encode() + b"|" + retained)
                self.assert_reason(
                    "agent_image_dart_dispatch_missing",
                    lambda: verifier.verify_package(ipa, REVISION),
                )

    def test_legacy_and_i4_fixture_or_loopback_markers_are_rejected(self) -> None:
        markers = (
            verifier._I1.I2_DEBUG_MARKERS
            + verifier._I1.I3_DEBUG_MARKERS
            + verifier._I1.I4_DEBUG_MARKERS
        )
        for marker in markers:
            with self.subTest(location="Runner", marker=marker):
                ipa = self.ipa(runner_payload=RUNNER_NATIVE_PAYLOAD + b"|" + marker)
                self.assert_reason(
                    "fixture_entry_point_present",
                    lambda: verifier.verify_package(ipa, REVISION),
                )
            with self.subTest(location="AOT", marker=marker):
                payload = b"aot:" + REVISION.encode("ascii") + b"|" + marker
                ipa = self.ipa(app_framework_payload=payload)
                self.assert_reason(
                    "fixture_entry_point_present",
                    lambda: verifier.verify_package(ipa, REVISION),
                )

    def test_i4_debug_fixture_asset_paths_are_rejected(self) -> None:
        for asset_name in (
            "i4-image-fixture.png",
            "i4_image_fixture.png",
            "i4-synthetic-model-fixture.bin",
            "IOSI4LoopbackProbe.json",
        ):
            with self.subTest(asset_name=asset_name):
                path = f"{APP_ROOT}/flutter_assets/assets/{asset_name}"
                ipa = self.ipa(extra_members=[(path, b"synthetic-only", None)])
                self.assert_reason(
                    "fixture_entry_point_present",
                    lambda: verifier.verify_package(ipa, REVISION),
                )

    def test_known_persistent_business_data_asset_formats_are_rejected(self) -> None:
        for asset_name in (
            "local.db",
            "cache.sqlite",
            "snapshot.sqlite3",
            "calendar.db-wal",
            "schedule.sqlite-shm",
            "history.jsonl",
            "events.ics",
            "records.csv",
            "tasks.tsv",
        ):
            with self.subTest(asset_name=asset_name):
                path = f"{APP_ROOT}/flutter_assets/assets/{asset_name}"
                ipa = self.ipa(extra_members=[(path, b"synthetic-only", None)])
                self.assert_reason(
                    "business_data_asset_present",
                    lambda: verifier.verify_package(ipa, REVISION),
                )

    def test_no_ats_background_audio_photo_location_or_remote_notification_gates_are_relaxed(self) -> None:
        cases = (
            ({"NSAppTransportSecurity": {"NSAllowsLocalNetworking": True}}, "transport_override_present"),
            ({"UIBackgroundModes": ["remote-notification"]}, "background_mode_present"),
            ({"NSMicrophoneUsageDescription": "synthetic"}, "audio_permission_present"),
            ({"NSSpeechRecognitionUsageDescription": "synthetic"}, "audio_permission_present"),
            ({"NSCameraUsageDescription": "synthetic"}, "restricted_permission_present"),
            ({"NSLocationWhenInUseUsageDescription": "synthetic"}, "restricted_permission_present"),
            ({"NSPhotoLibraryUsageDescription": "synthetic"}, "restricted_permission_present"),
            ({"NSPhotoLibraryAddUsageDescription": "synthetic"}, "restricted_permission_present"),
        )
        for extras, reason in cases:
            with self.subTest(info_extras=extras):
                ipa = self.ipa(info_extras=extras)
                self.assert_reason(reason, lambda: verifier.verify_package(ipa, REVISION))

        entitlements = plistlib.dumps({"aps-environment": "development"})
        ipa = self.ipa(extra_members=[(f"{APP_ROOT}/Runner.entitlements", entitlements, None)])
        self.assert_reason(
            "remote_notifications_entitlement_present",
            lambda: verifier.verify_package(ipa, REVISION),
        )

        signed_entitlements = i2_fixtures.fixtures.signature_superblob(
            entitlements={"aps-environment": "development"}
        )
        ipa = self.ipa(runner_signature=signed_entitlements)
        self.assert_reason(
            "remote_notifications_entitlement_present",
            lambda: verifier.verify_package(ipa, REVISION),
        )

    def test_no_extensions_plugins_app_groups_models_or_private_files(self) -> None:
        cases = (
            ([(f"{APP_ROOT}/Widget.appex/Info.plist", b"synthetic", None)], "extension_present"),
            ([(f"{APP_ROOT}/PlugIns/Marker", b"synthetic", None)], "plugin_directory_present"),
            ([(f"{APP_ROOT}/Runner.entitlements", plistlib.dumps({"com.apple.security.application-groups": ["group.fixture"]}), None)], "app_group_entitlement_present"),
            ([(f"{APP_ROOT}/models/fixture.onnx", b"synthetic", None)], "model_asset_present"),
            ([(f"{APP_ROOT}/fixture.p8", b"synthetic", None)], "prohibited_package_asset"),
        )
        for members, reason in cases:
            with self.subTest(member=members[0][0]):
                ipa = self.ipa(extra_members=members)
                self.assert_reason(reason, lambda: verifier.verify_package(ipa, REVISION))


if __name__ == "__main__":
    unittest.main()
