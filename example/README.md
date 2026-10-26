# lib_mlx Apple example

Enable Flutter Swift Package Manager, run `flutter pub get`, and build the macOS or iOS host. The interactive `lib/main.dart` accepts a verified local E2B model directory, loads the real backend and starts its loopback OpenAI server.

`lib/smoke.dart` runs the public Dart -> FFI -> Swift HTTP -> MLX -> SSE -> Dart acceptance path. It needs the pinned assets produced by `../tool/fetch_model.py`. On iOS place them in the installed application's `Documents/gemma-4-e2b`; run `../tool/device_smoke.sh DEVICE_UDID MODEL_DIRECTORY 4096` from the repository for signed Release build/install/copy/standalone launch/report collection. On macOS use the app's authorized Documents model directory or pass `--dart-define=LIB_MLX_MODEL_PATH=...` with a sandbox-authorized path.

The smoke produces a JSON report with actual text, multi-turn/instructions, thinking, usage, context rejection, cancellation, memory, unload and reload results. A compile or unsigned build alone is not a passed inference smoke. Read [validation](../doc/validation.md) for actual hardware results.

`lib/lifecycle_smoke.dart` is a separate entry point in this same iOS host. Build it in Release with a fresh `LIB_MLX_SMOKE_RUN_ID`, install without deleting app data, and launch. Wait for `Documents/lib_mlx-lifecycle-ready.json` with that run ID, foreground Settings, then reactivate the existing example process without `--terminate-existing`. `Documents/lib_mlx-lifecycle-report.json` must record interruption during inactive state, resumed state, a stopped listener, and a new successful real generation after explicit server restart. This tests foreground/background handling; it does not claim background GPU execution.

macOS sandbox entitlements include network client/server and user-selected file read permission. iOS Release requests ordinary increased memory allowance; no debugging-only entitlement is included. Available memory is still device-dependent. iPadOS uses this iOS host. No tvOS-specific host is included in this round.
