## 0.2.0-dev.1

- Replace the production stub with pinned Gemma 4 E2B MLX text inference, verified assets, real template/tokenizer usage, reasoning separation and cancellation.
- Add SwiftNIO loopback HTTP framing, bounded streaming/queues, request validation and coordinated resource teardown.
- Preserve ordered message/content/tool semantics and JSON types; reject unsupported tools, images and audio explicitly.
- Add context/output admission, chunked prefill, isolated request KV, device/process budgeting and memory-pressure lifecycle handling.
- Add shared macOS/iOS/iPadOS Flutter SwiftPM integration. Remove the broken CocoaPods path; requires migration and Swift tools 6.3+.
- Add controlled protocol, public Dart/FFI, actual-model and Flutter Release acceptance entry points with evidence-based release gates.
- Add a repeated public-chain allocator recovery regression and release gate; recovery currently fails on the pinned upstream quantization implementation.
- Resolve smoke-report and model locations through the Apple sandbox Documents API.

Development version; consult doc/validation.md for executed checks and blockers. No four-platform, full-modality or universal 128K validation claim.

## 0.1.1

- Add Gemma E2B/E4B model presets and Hugging Face model page URLs.
- Default model configuration to Gemma E2B.

## 0.1.0

- Initial iOS FFI lifecycle and localhost HTTP protocol scaffold (stub backend).
