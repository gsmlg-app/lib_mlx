"""Regression fixtures for release evidence; never loads a model or starts a build."""
import contextlib
import io
import json
import os
import plistlib
import re
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from tool import release_gate as gate


LOCK = {
    "repository": "mlx-community/gemma-4-e2b-it-4bit",
    "revision": "238767527555cb75a05732a84dff5d6ba0dd6809",
}
DIGEST = "a" * 64
SOURCE_INPUTS = (
    "lib/source.dart", "darwin/source.swift", "Package.swift", "Package.resolved", "pubspec.yaml",
    "example/lib/smoke.dart", "example/ios/Runner.xcodeproj/project.pbxproj",
    "example/macos/Runner.xcodeproj/project.pbxproj", "example/ios/Runner/Debug.entitlements",
    "example/ios/Runner/Release.entitlements", "example/macos/Runner/DebugProfile.entitlements",
    "example/macos/Runner/Release.entitlements",
    "example/pubspec.yaml", "example/pubspec.lock",
    "example/ios/Runner/Info.plist", "example/macos/Runner/Info.plist",
    "example/ios/Flutter/AppFrameworkInfo.plist",
    "example/ios/Flutter/Debug.xcconfig", "example/ios/Flutter/Release.xcconfig",
    "example/macos/Flutter/Flutter-Debug.xcconfig", "example/macos/Flutter/Flutter-Release.xcconfig",
    "example/macos/Runner/Configs/AppInfo.xcconfig", "example/macos/Runner/Configs/Debug.xcconfig",
    "example/macos/Runner/Configs/Release.xcconfig", "example/macos/Runner/Configs/Warnings.xcconfig",
    "example/ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    "example/ios/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    "example/macos/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    "example/macos/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved",
)


def usage(prompt=7, completion=2):
    return {
        "prompt_tokens": prompt, "completion_tokens": completion, "total_tokens": prompt + completion,
        "timings": {"prefill_seconds": 0.25, "generation_seconds": 0.125},
    }


def report(platform="macos", context=4096):
    return {
        "status": "passed", "platform": platform, "build_mode": "release", "host": "flutter",
        "signed": True, "signing_kind": "provisioned" if platform == "ios" else "adhoc",
        "standalone_launch": True, "device_udid": "fixture-device" if platform == "ios" else None,
        "run_id": "fixture-run", "model_revision": LOCK["revision"], "source_digest": DIGEST,
        "context_length": context,
        "increased_memory_limit_entitlement": platform == "ios",
        "checks": {
            "loaded_model": LOCK["repository"], "release_ffi_and_listener": "http://127.0.0.1:12345",
            "text_and_token_usage": {"text": "OK", "usage": usage()},
            "multi_turn_instructions": {"output_text": "aqua"},
            "thinking_stream": {"text": "4", "reasoning": "calculate", "deltas": 3,
                                "first_delta_ms": 10, "total_ms": 50},
            "context_probe": usage((context * 9 + 9) // 10, 8),
            "context_admission": "context budget exceeded", "cancel_and_stop": "stopped",
            "unloaded": True, "repeat_load_unload": True, "rejected_invalid_handle": "invalid handle",
            "rejected_invalid_model_assets": "missing model",
            "memory": {"process_physical_footprint_bytes": 1000, "mlx_active_bytes": 500,
                       "mlx_cache_bytes": 0, "mlx_peak_bytes": 700},
        },
    }


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="lib-mlx-gate-report-")
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "report.json"

    def validate(self, value, expected_run_id=None):
        self.path.write_text(json.dumps(value))
        return gate.validate_report(self.path, value["platform"], DIGEST, LOCK, expected_run_id)

    def assert_rejected(self, value, message):
        with self.assertRaisesRegex(gate.GateError, message):
            self.validate(value)

    def test_valid_macos_evidence(self):
        self.assertEqual(self.validate(report())["status"], "passed")

    def test_valid_provisioned_ios_evidence(self):
        self.assertEqual(self.validate(report("ios"))["device_udid"], "fixture-device")

    def test_context_range_boundaries(self):
        for context in (4096, 131072):
            with self.subTest(context=context):
                self.validate(report(context=context))

    def test_rejects_invalid_context_lengths(self):
        for context in (None, 4095, 131073, True, 4096.0, "4096"):
            with self.subTest(context=context):
                value = report(); value["context_length"] = context
                self.assert_rejected(value, "context_length")

    def test_accepts_exact_ninety_percent_context_probe(self):
        value = report(context=40960)
        value["checks"]["context_probe"] = usage(36864, 8)
        self.validate(value)

    def test_rejects_missing_or_unmeasured_context_probe(self):
        for probe in (None, {}, {"prompt_tokens": 3687}):
            with self.subTest(probe=probe):
                value = report(); value["checks"]["context_probe"] = probe
                self.assert_rejected(value, "context_probe")

    def test_rejects_context_probe_below_ninety_percent(self):
        value = report(); value["checks"]["context_probe"] = usage(3686, 8)
        self.assert_rejected(value, "90%")

    def test_rejects_nonpositive_or_boolean_probe_counts(self):
        for field, invalid in (("prompt_tokens", 0), ("completion_tokens", 0), ("prompt_tokens", True),
                               ("completion_tokens", True), ("total_tokens", 1)):
            with self.subTest(field=field, invalid=invalid):
                value = report(); value["checks"]["context_probe"][field] = invalid
                self.assert_rejected(value, "context_probe")

    def test_requires_timings_for_both_usage_records(self):
        for target in ("text_and_token_usage", "context_probe"):
            for timings in (None, {}, "unmeasured"):
                with self.subTest(target=target, timings=timings):
                    value = report()
                    record = value["checks"][target]
                    if target == "text_and_token_usage": record = record["usage"]
                    record["timings"] = timings
                    self.assert_rejected(value, "timings")

    def test_rejects_nonpositive_nonfinite_or_boolean_prefill_seconds(self):
        for target in ("text_and_token_usage", "context_probe"):
            for seconds in (None, 0, -1, True, float("nan"), float("inf"), "0.25", 10 ** 500):
                with self.subTest(target=target, seconds=seconds):
                    value = report()
                    record = value["checks"][target]
                    if target == "text_and_token_usage": record = record["usage"]
                    record["timings"]["prefill_seconds"] = seconds
                    self.assert_rejected(value, "prefill_seconds")

    def test_rejects_negative_nonfinite_or_boolean_generation_seconds(self):
        for target in ("text_and_token_usage", "context_probe"):
            for seconds in (None, -0.1, False, float("nan"), float("inf"), "0", 10 ** 500):
                with self.subTest(target=target, seconds=seconds):
                    value = report()
                    record = value["checks"][target]
                    if target == "text_and_token_usage": record = record["usage"]
                    record["timings"]["generation_seconds"] = seconds
                    self.assert_rejected(value, "generation_seconds")

    def test_accepts_zero_generation_seconds(self):
        value = report()
        value["checks"]["text_and_token_usage"]["usage"]["timings"]["generation_seconds"] = 0
        value["checks"]["context_probe"]["timings"]["generation_seconds"] = 0.0
        self.validate(value)

    def test_ios_rejects_unprovisioned_signing(self):
        for kind in (None, "adhoc", "identity", True):
            with self.subTest(kind=kind):
                value = report("ios"); value["signing_kind"] = kind
                self.assert_rejected(value, "signing_kind")

    def test_ios_requires_device_identity(self):
        for device in (None, "", "  ", 123):
            with self.subTest(device=device):
                value = report("ios"); value["device_udid"] = device
                self.assert_rejected(value, "device_udid")

    def test_ios_requires_true_increased_memory_limit_entitlement(self):
        for entitlement in (False, None, "true", 1):
            with self.subTest(entitlement=entitlement):
                value = report("ios"); value["increased_memory_limit_entitlement"] = entitlement
                self.assert_rejected(value, "increased_memory_limit_entitlement")

    def test_ios_rejects_missing_increased_memory_limit_entitlement(self):
        value = report("ios")
        value.pop("increased_memory_limit_entitlement")
        self.assert_rejected(value, "increased_memory_limit_entitlement")

    def test_run_identity_must_match_invocation(self):
        self.validate(report(), "fixture-run")
        with self.assertRaisesRegex(gate.GateError, "older invocation"):
            self.validate(report(), "different-run")

    def test_rejects_other_release_evidence_regressions(self):
        cases = (("build_mode", "debug"), ("signed", False), ("standalone_launch", False),
                 ("source_digest", "stale"), ("model_revision", "unpinned"))
        for field, invalid in cases:
            with self.subTest(field=field):
                value = report(); value[field] = invalid
                self.assert_rejected(value, field)

    def test_malformed_report_has_clear_error(self):
        self.path.write_text("{broken")
        with self.assertRaisesRegex(gate.GateError, "cannot read JSON"):
            gate.validate_report(self.path, "ios", DIGEST, LOCK)


class GateCLITests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="lib-mlx-gate-cli-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "tool").mkdir()
        (self.root / "tool/model-lock.json").write_text(json.dumps(LOCK))
        self.environment = {}
        for platform in ("macos", "ios"):
            path = self.root / f"{platform}.json"
            path.write_text(json.dumps(report(platform)))
            self.environment[f"LIB_MLX_{platform.upper()}_REPORT"] = str(path)

    def invoke(self, arguments=(), manifests_ok=True):
        stdout, stderr = io.StringIO(), io.StringIO()
        result = SimpleNamespace(returncode=0 if manifests_ok else 1, stdout="", stderr="Manifest drift: fixture")
        with patch.object(gate, "ROOT", self.root), patch.object(gate, "source_digest", return_value=DIGEST), \
             patch.object(gate.subprocess, "run", return_value=result) as command, \
             patch.dict(os.environ, self.environment, clear=True), \
             contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = gate.main(list(arguments))
        command.assert_called_once()
        return status, stdout.getvalue(), stderr.getvalue()

    def test_full_gate_accepts_both_platform_reports(self):
        status, stdout, _ = self.invoke()
        self.assertEqual(status, 0)
        self.assertIn("macos, ios", stdout)

    def test_full_gate_requires_both_platform_reports(self):
        del self.environment["LIB_MLX_IOS_REPORT"]
        status, _, stderr = self.invoke()
        self.assertEqual(status, 1)
        self.assertIn("Missing LIB_MLX_IOS_REPORT", stderr)

    def test_full_gate_rejects_standard_memory_diagnostic_ios_report(self):
        path = Path(self.environment["LIB_MLX_IOS_REPORT"])
        value = report("ios"); value["increased_memory_limit_entitlement"] = False
        path.write_text(json.dumps(value))
        status, _, stderr = self.invoke()
        self.assertEqual(status, 1)
        self.assertIn("increased_memory_limit_entitlement", stderr)

    def test_manifest_drift_fails_before_accepting_reports(self):
        status, _, stderr = self.invoke(manifests_ok=False)
        self.assertEqual(status, 1)
        self.assertIn("Manifest drift: fixture", stderr)

    def test_single_platform_checks_invocation_identifier(self):
        arguments = ("--platform", "ios", "--run-id", "old-run", self.environment["LIB_MLX_IOS_REPORT"])
        status, _, stderr = self.invoke(arguments)
        self.assertEqual(status, 1)
        self.assertIn("older invocation", stderr)


class DeviceSigningEvidenceTests(unittest.TestCase):
    def test_report_annotation_uses_actual_signed_entitlements(self):
        script = Path(__file__).with_name("device_smoke.sh").read_text()
        blocks = re.findall(r"<<'PY'\n(.*?)\nPY(?:\n|$)", script, re.S)
        annotation = next(block for block in blocks if "report.update(signed=True" in block)
        program = compile(annotation, "device_smoke.sh report annotation", "exec")
        with tempfile.TemporaryDirectory(prefix="lib-mlx-signed-entitlements-") as temporary:
            root = Path(temporary)
            candidate, output, entitlements = (root / name for name in ("candidate.json", "report.json", "signed.plist"))
            for signed_value in (True, False, None, "true", 1):
                with self.subTest(signed_value=signed_value):
                    # A report's requested/source value must never override the signed binary.
                    value = report("ios"); value["increased_memory_limit_entitlement"] = True
                    candidate.write_text(json.dumps(value))
                    signed = {} if signed_value is None else {"com.apple.developer.kernel.increased-memory-limit": signed_value}
                    entitlements.write_bytes(plistlib.dumps(signed))
                    arguments = ["annotation", str(candidate), str(output), "fixture-run", DIGEST, "fixture-device", str(entitlements)]
                    with patch.object(gate.sys, "argv", arguments):
                        exec(program, {})
                    annotated = json.loads(output.read_text())
                    self.assertIs(annotated["increased_memory_limit_entitlement"], signed_value is True)


class SourceDigestTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="lib-mlx-gate-source-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in SOURCE_INPUTS:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)

    def test_digest_is_stable_and_excludes_generated_outputs(self):
        before = gate.source_digest(self.root)
        generated = self.root / "darwin/lib_mlx/.build/generated.swift"
        generated.parent.mkdir(parents=True); generated.write_text("generated")
        self.assertEqual(gate.source_digest(self.root), before)
        for name in ("example/ios/Flutter/Generated.xcconfig", "example/macos/Flutter/ephemeral/Flutter-Generated.xcconfig"):
            generated = self.root / name
            generated.parent.mkdir(parents=True, exist_ok=True); generated.write_text("generated environment")
        self.assertEqual(gate.source_digest(self.root), before)

    def test_stable_flutter_dependencies_configs_and_plists_affect_digest(self):
        before = gate.source_digest(self.root)
        host_inputs = [name for name in SOURCE_INPUTS if name.startswith("example/") and
                       (name.endswith((".xcconfig", ".plist", "Package.resolved")) or "pubspec" in name)]
        for name in host_inputs:
            with self.subTest(name=name):
                path = self.root / name; original = path.read_text()
                path.write_text("changed host build input")
                self.assertNotEqual(gate.source_digest(self.root), before)
                path.write_text(original)

    def test_flutter_host_signing_and_project_sources_affect_digest(self):
        before = gate.source_digest(self.root)
        for name in ("example/lib/smoke.dart", "example/ios/Runner/Release.entitlements",
                     "example/macos/Runner.xcodeproj/project.pbxproj"):
            with self.subTest(name=name):
                path = self.root / name; original = path.read_text()
                path.write_text("changed")
                self.assertNotEqual(gate.source_digest(self.root), before)
                path.write_text(original)

    def test_missing_or_symlink_source_is_rejected(self):
        source = self.root / "lib/source.dart"
        source.unlink(); source.symlink_to(self.root / "pubspec.yaml")
        with self.assertRaisesRegex(gate.GateError, "symlink"):
            gate.source_digest(self.root)
        (self.root / "Package.resolved").unlink()
        with self.assertRaisesRegex(gate.GateError, "Missing source input"):
            gate.source_digest(self.root)


if __name__ == "__main__":
    unittest.main()
