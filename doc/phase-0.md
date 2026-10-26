# Historical Phase 0 scaffold (0.1.1)

This note describes the review baseline `2b84efc27d692c0845fd948dd91ce363ba85f1ab`, not current inference support. The old core accepted nonexistent paths and returned fixed responses; HTTP framing/streaming, lifecycle synchronization and the CocoaPods module layout were incomplete.

The 0.2 implementation replaces that scaffold with a pinned official MLX E2B **text** backend, SwiftNIO transport, demand-driven events, real tokenizer admission and isolated request KV. Image, audio and tool execution are rejected explicitly. The current text path does not depend on the proposed VincentGourbin fork. History reasoning treatment is delegated to the pinned model template, including its tool-turn conditions.

See [README](../README.md), [migration](migration-0.2.md) and [validation](validation.md) for the current architecture, version pins, platform evidence and remaining acceptance gates. The old planned four-platform/full-modality/128K gates are not claims of completed verification.
