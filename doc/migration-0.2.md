# Migration from 0.1.1 to 0.2

0.1.1 returned ready for missing paths and generated hard-coded responses. 0.2 loads the pinned, verified Gemma 4 E2B text model. Supply a complete local snapshot using `tool/fetch_model.py`; mocked responses require an explicitly supplied Swift `MlxBackend` and are never a production fallback.

## Apple packaging change

Use Swift Package Manager with Flutter on iOS/iPadOS or macOS. The common source now lives under `darwin/lib_mlx`; both Flutter platform declarations set `sharedDarwinSource`. Flutter generates the real `FlutterFramework` package in its ephemeral integration directory; the plugin manifest references that generated package as required by Flutter tooling. The old source-only placeholder is removed. The Swift core, HTTP and FFI sources have no Flutter import. The root manifest omits the Flutter dependency and exposes the core/server/runtime targets to native hosts and a dynamic `MlxRuntimeFFI` product for Dart ABI verification.

The 0.1.1 CocoaPods target compiled `Sources/**/*` into a single `lib_mlx` module, while Runtime.swift imported separate `MlxCore` and `MlxServer` modules that only its SwiftPM manifest defined. There were no matching pod module targets. Merely removing these imports would leave the real MLX dependency unresolved.

The selected upstream `mlx-swift` 0.32.3 is a Swift tools 6.3 package with a `Cmlx` C++20 target, platform-specific source exclusions, header search paths, link settings, generated bindings and Metal kernel/resource build behavior. `mlx-swift-lm` 3.32.3 and `swift-transformers` 1.3.0 supply additional Swift package targets/resources and transitive dependencies. Their pinned repository trees contain no maintained podspec or published XCFramework contract. CocoaPods' `s.dependency` cannot consume those SwiftPM products. An equivalent pod distribution would require maintaining a second native build or producing and verifying binary XCFrameworks; this package supplies neither. The broken podspec was therefore removed instead of advertising an unbuildable path. This is a compatibility adjustment and the minor version increases to 0.2.0 (currently development prerelease). Existing CocoaPods-only consumers should stay on their existing version until migrated; 0.1.1 itself is not a real inference implementation.

Evidence can be inspected at the exact dependency pins:

- [MLX manifest](https://github.com/ml-explore/mlx-swift/blob/0.32.3/Package.swift)
- [MLX LM manifest](https://github.com/ml-explore/mlx-swift-lm/blob/3.32.3/Package.swift)
- [Transformers manifest](https://github.com/huggingface/swift-transformers/blob/1.3.0/Package.swift)

Run `flutter config --enable-swift-package-manager`, then `flutter pub get` and build an actual Flutter host. The committed example covers both hosts; validation evidence identifies the exact commands, SDKs and configuration. There is no CocoaPods success claim.

## API and behavior changes

- iOS 17 / macOS 14 minimum; Swift tools 6.3 minimum. Xcode 16.4/Swift 5.9 are insufficient.
- Only the pinned E2B checkpoint is accepted. E4B catalog constants do not indicate executable model support.
- The default server ID derives from the loaded model. An optional ID is a service alias; `/v1/models` identifies the resident model separately.
- Non-loopback bind addresses fail. There is no unauthenticated LAN mode.
- Queue limit counts waiting requests; stop/unload closes accepted sockets and waits for generation teardown.
- Bad parameters, unsupported images/audio/tools, damaged/missing assets and context overflow fail explicitly. Stub multimodal/tool responses were removed.
- Context is a device/process budget. Output tokens are separately reserved. There is no universal 128K claim.
- Request KV is isolated and not reused; weights remain resident until unload.
- iOS inactive/background transitions cancel foreground inference. Restart the listener after foreground resume.
- Release entitlements exclude debugger-only memory entitlement. Device validation must use a signed standalone Release launch and verified assets.
