# Phase 0 Notes

This repository currently contains the Phase 0B/0C scaffold: a Swift native
server stub over a structured core stub, plus Dart FFI lifecycle management.

## Current State

- `MlxCore` owns structured events: text deltas, reasoning deltas, tool calls,
  and completion reasons.
- `MlxServer` translates those events to OpenAI-shaped chat completions and
  Responses payloads. The Responses stream currently emits typed lifecycle
  events with sequence numbers for created/completed, output item added/done,
  content part added/done, output text delta/done, reasoning text delta/done,
  and function-call argument delta/done.
- `lib_mlx` exposes only lifecycle functions through `@_cdecl`.
- The Dart client talks to the server over localhost and parses SSE streams.
- Host-side Swift tests start the stub localhost server and validate chat
  reasoning separation, Responses text/reasoning streaming, and Responses
  function-call streaming.

## Blocking Device Work

Phase 0A still requires a physical iPhone 15 Pro or newer with the local pinned
Gemma 4 E2B 4-bit model. The required checks are:

- real MLX load on device with increased memory entitlement
- peak RSS with vision/audio encoders resident
- text, image, audio, tool-call JSON, and reasoning-separation quality gates
- confirmation that prior-turn thinking is stripped before prompt rendering

## Decision To Confirm Before Real Core Work

The kickoff calls out `VincentGourbin/gemma-4-swift-mlx` as the likely starting
point because mainline `mlx-swift-lm` is expected to lack Gemma 4 audio support.
That vendoring decision should be confirmed before replacing the stub core with
real model code.

The host scaffold currently uses a tiny `Network`/`NWListener` HTTP server so
Phase 0B translation can be tested without adding framework dependencies. The
production Swift HTTP framework decision is still open and should be confirmed
before replacing this with Hummingbird, Vapor, or a lower-level SwiftNIO server.
