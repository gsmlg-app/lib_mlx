#!/usr/bin/env python3
"""Require current signed, standalone Flutter Release smoke evidence before release."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent.parent
EXCLUDED = {".build", "build", ".dart_tool", ".swiftpm", "ephemeral", "Pods", ".git", "xcuserdata", ".DS_Store"}


class GateError(Exception):
    pass


def source_digest(root=ROOT):
    paths = []
    for directory in ("lib", "darwin"):
        base = root / directory
        if not base.is_dir():
            raise GateError(f"Missing source directory: {directory}")
        paths.extend(path for path in base.rglob("*") if path.is_file() and not EXCLUDED.intersection(path.relative_to(base).parts))
    # The concrete Flutter host and signing/link configuration are part of the evidence.
    for name in ("Package.swift", "Package.resolved", "pubspec.yaml", "example/lib/smoke.dart",
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
                 "example/ios/Runner.xcodeproj/project.pbxproj", "example/macos/Runner.xcodeproj/project.pbxproj",
                 "example/ios/Runner/Debug.entitlements", "example/ios/Runner/Release.entitlements",
                 "example/macos/Runner/DebugProfile.entitlements", "example/macos/Runner/Release.entitlements"):
        path = root / name
        if not path.is_file():
            raise GateError(f"Missing source input: {name}")
        paths.append(path)
    digest = hashlib.sha256()
    for path in sorted(paths, key=lambda item: item.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            raise GateError(f"Source input must not be a symlink: {relative}")
        data = path.read_bytes()
        digest.update(relative.encode("utf-8") + b"\0")
        digest.update(str(len(data)).encode("ascii") + b"\0")
        digest.update(data)
    return digest.hexdigest()


def load_object(path, label):
    try:
        value = json.loads(Path(path).read_text())
    except (OSError, ValueError) as error:
        raise GateError(f"{label}: cannot read JSON: {error}") from error
    if not isinstance(value, dict):
        raise GateError(f"{label}: expected a JSON object")
    return value


def validate_report(path, platform, digest, lock, expected_run_id=None):
    label = f"{platform} report ({path})"
    report = load_object(path, label)

    def require(condition, message):
        if not condition:
            raise GateError(f"{label}: {message}")

    def nonempty(value):
        return isinstance(value, str) and bool(value.strip())

    def integer(value, minimum=0):
        return type(value) is int and value >= minimum

    def measured_seconds(value, positive=False):
        if type(value) not in (int, float):
            return False
        try:
            return math.isfinite(value) and (value > 0 if positive else value >= 0)
        except OverflowError:
            return False

    def validate_usage(usage, name):
        require(isinstance(usage, dict), f"{name} must contain measured tokenizer counts")
        require(integer(usage.get("prompt_tokens"), 1) and integer(usage.get("completion_tokens"), 1),
                f"{name} prompt/completion token counts must be positive integers")
        require(integer(usage.get("total_tokens"), 1) and usage["total_tokens"] == usage["prompt_tokens"] + usage["completion_tokens"],
                f"{name}.total_tokens must equal measured prompt plus completion tokens")
        timings = usage.get("timings")
        require(isinstance(timings, dict), f"{name}.timings must contain measured generation timings")
        require(measured_seconds(timings.get("prefill_seconds"), positive=True),
                f"{name}.timings.prefill_seconds must be a positive finite measured duration")
        require(measured_seconds(timings.get("generation_seconds")),
                f"{name}.timings.generation_seconds must be a nonnegative finite measured duration")

    for field, expected in (("status", "passed"), ("platform", platform), ("build_mode", "release"),
                            ("host", "flutter"), ("signed", True), ("standalone_launch", True),
                            ("model_revision", lock["revision"]), ("source_digest", digest)):
        value = report.get(field)
        require(type(value) is type(expected) and value == expected, f"{field} must equal {expected!r}; got {value!r}")
    context_length = report.get("context_length")
    require(integer(context_length, 4096) and context_length <= 131072,
            "context_length must be an integer in 4096...131072")
    if platform == "ios":
        require(report.get("signing_kind") == "provisioned", "signing_kind must equal 'provisioned' for iOS")
        require(nonempty(report.get("device_udid")), "device_udid must identify the physical iOS device")
        require(report.get("increased_memory_limit_entitlement") is True,
                "increased_memory_limit_entitlement must be exactly true for qualifying iOS Release evidence")
    require(nonempty(report.get("run_id")), "run_id must identify the standalone smoke invocation")
    if expected_run_id is not None:
        require(report["run_id"] == expected_run_id, "run_id belongs to an older invocation")
    checks = report.get("checks")
    require(isinstance(checks, dict), "checks must be an object containing runtime evidence")
    require(checks.get("loaded_model") == lock["repository"], "loaded_model must equal the pinned model repository")
    listener = checks.get("release_ffi_and_listener")
    try:
        url = urlparse(listener) if isinstance(listener, str) else None
        local_listener = url and url.scheme == "http" and url.hostname in ("127.0.0.1", "::1") and url.port and url.port > 0
    except ValueError:
        local_listener = False
    require(bool(local_listener), "release_ffi_and_listener must identify an actual loopback listener")
    generated = checks.get("text_and_token_usage")
    require(isinstance(generated, dict) and nonempty(generated.get("text")), "text_and_token_usage must contain generated text")
    require("stub" not in generated["text"].lower(), "stub generation cannot satisfy release evidence")
    validate_usage(generated.get("usage"), "text_and_token_usage.usage")
    probe = checks.get("context_probe")
    validate_usage(probe, "context_probe")
    require(probe["prompt_tokens"] * 10 >= context_length * 9,
            "context_probe.prompt_tokens must cover at least 90% of context_length")
    multi_turn = checks.get("multi_turn_instructions")
    require(isinstance(multi_turn, dict) and "aqua" in json.dumps(multi_turn).lower(), "multi_turn_instructions must retain the smoke codeword")
    thinking = checks.get("thinking_stream")
    require(isinstance(thinking, dict), "thinking_stream must contain incremental evidence")
    require(integer(thinking.get("deltas"), 2) and nonempty(thinking.get("text")) and nonempty(thinking.get("reasoning")), "thinking_stream requires multiple deltas and separate text/reasoning")
    require(integer(thinking.get("first_delta_ms")) and integer(thinking.get("total_ms")) and thinking["first_delta_ms"] <= thinking["total_ms"], "thinking_stream timing must identify the first delta and total duration")
    require(nonempty(checks.get("context_admission")) and "context" in checks["context_admission"].lower(), "context_admission must demonstrate context-budget rejection")
    require(checks.get("cancel_and_stop") == "stopped", "cancel_and_stop must confirm a stopped server")
    require(checks.get("unloaded") is True and checks.get("repeat_load_unload") is True, "unload and repeated load/unload must pass")
    require(nonempty(checks.get("rejected_invalid_handle")), "unloaded handles must be rejected")
    require(any(key.startswith("rejected_") and key != "rejected_invalid_handle" and nonempty(value) for key, value in checks.items()), "invalid model loading must be rejected")
    memory = checks.get("memory")
    require(isinstance(memory, dict), "memory must contain measured allocator and process values")
    for key in ("process_physical_footprint_bytes", "mlx_active_bytes", "mlx_peak_bytes"):
        require(integer(memory.get(key), 1), f"memory.{key} must be a positive measured byte count")
    require(integer(memory.get("mlx_cache_bytes")), "memory.mlx_cache_bytes must be a nonnegative byte count")
    require(memory["mlx_peak_bytes"] >= memory["mlx_active_bytes"], "MLX peak memory must be at least active memory")
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs="*", help="Optional single report with --platform")
    parser.add_argument("--source-digest", action="store_true", help="Print the stable source SHA-256 only")
    parser.add_argument("--platform", choices=("macos", "ios"), help="Validate one platform report")
    parser.add_argument("--run-id", help="Require this invocation identifier for a single report")
    args = parser.parse_args(argv)
    try:
        digest = source_digest()
        if args.source_digest:
            if args.reports or args.platform or args.run_id:
                raise GateError("--source-digest cannot be combined with report validation arguments")
            print(digest)
            return 0
        manifests = subprocess.run([sys.executable, str(ROOT / "tool/package_manifests.py"), "--check"], cwd=ROOT, capture_output=True, text=True)
        if manifests.returncode:
            raise GateError("SwiftPM manifest validation failed: " + (manifests.stderr.strip() or manifests.stdout.strip()))
        lock = load_object(ROOT / "tool/model-lock.json", "model lock")
        if not isinstance(lock.get("repository"), str) or not isinstance(lock.get("revision"), str):
            raise GateError("model lock requires repository and revision strings")
        if args.platform:
            if len(args.reports) != 1:
                raise GateError("--platform requires exactly one report path")
            paths = [(args.platform, args.reports[0])]
        else:
            if args.reports or args.run_id:
                raise GateError("Use --platform for a single report; full release validation reads LIB_MLX_MACOS_REPORT and LIB_MLX_IOS_REPORT")
            paths = []
            for platform in ("macos", "ios"):
                variable = f"LIB_MLX_{platform.upper()}_REPORT"
                path = os.environ.get(variable)
                if not path:
                    raise GateError(f"Missing {variable}: a current signed standalone Flutter Release report is required; publication remains blocked")
                paths.append((platform, path))
        for platform, path in paths:
            validate_report(path, platform, digest, lock, args.run_id)
        print(f"Release evidence gate passed for {', '.join(platform for platform, _ in paths)}; source_digest={digest}")
        return 0
    except GateError as error:
        print(f"Release evidence gate failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
