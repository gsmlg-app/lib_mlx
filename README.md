# lib_mlx

An iOS-only Flutter FFI management bridge for a local Swift MLX inference core and an OpenAI-compatible localhost server.

This library provides a **hybrid lifecycle model** where native code manages the MLX model footprint and the local network listener via a low-level C FFI interface, while inference inputs, outputs, and Server-Sent Events (SSE) stream content are routed over a standard localhost HTTP server to bypass the performance and complexity overhead of cross-FFI binary serialization.

---

## Architecture Overview

Streaming raw audio/video frames, multimodal tokens, reasoning events, and tool calls across Dart FFI requires verbose pointer serialization, custom struct alignment, and memory lifecycle tracking. This project circumvents that complexity:

```text
               +------------------------------------------------------+
               |                     iOS Device                       |
               |                                                      |
               |  +--------------------+      HTTP (Localhost)        |
               |  |    Flutter App     |<==========================+  |
               |  | (OpenAI API Client)|                           |  |
               |  +--------------------+                           |  |
               |         |                                         |  |
               |         | FFI (C ABI)                             |  |
               |         v                                         v  |
               |  +--------------------+                      +---------+
               |  |  @_cdecl Shim      |                      |  Swift  |
               |  | (Lifecycle/Config) |                      | Server  |
               |  +--------------------+                      +---------+
               |         |                                         |  |
               |         v                                         v  |
               |  +-----------------------------------------------------+
               |  |                       MlxCore                       |
               |  |              (Resident Model Handle)                |
               |  +-----------------------------------------------------+
               |                                                      |
               +------------------------------------------------------+
```

### Key Pillars
- **FFI for Lifecycle Management**: FFI calls load and unload model weights into memory, start/stop the localhost server, and poll status using simple, structured JSON-in/JSON-out messages.
- **HTTP for Inference Routing**: The actual inference path is HTTP-only. Structured OpenAI payloads (Chat Completions and Response families) flow through localhost sockets, letting the client easily read standard SSE streams and consume multipart media chunks.
- **Reasoning Separation**: Reasoning tokens are kept separate from assistant content in the native `MlxCore` layer and the SSE streams.
- **Multimodal Preparedness**: Audio/image input arrays bypass FFI entirely, sent as standard multipart payloads to the local server.

---

## Directory Layout

```text
ios/lib_mlx/Sources/MlxCore/   Structured native inference types and stub core
ios/lib_mlx/Sources/MlxServer/ Standalone Swift localhost OpenAI server (using NWListener)
ios/lib_mlx/Sources/lib_mlx/   @_cdecl C lifecycle shim
lib/                           Dart management APIs and the thin OpenAI HTTP client
example/                       iOS runtime Flutter harness app for validation
src/lib_mlx.h                  The ffigen input header describing the lifecycle ABI
Package.swift                  The root SwiftPM package configuration mirroring targets
```

*Note: The Swift package under `ios/lib_mlx` is the CocoaPods-compatible package for Flutter. The root `Package.swift` mirrors the exact same target definitions to allow host-side macOS debugging and tests (`swift test`) without running Xcode or linking to the Flutter SDK.*

---

## Native C API (FFI Lifecycle ABI)

The native interface is defined in [src/lib_mlx.h](src/lib_mlx.h). All methods return dynamically allocated JSON strings that must be freed using `lib_mlx_free`.

### 1. `lib_mlx_load_model`
Loads a local MLX model directory.
- **Signature**: `char *lib_mlx_load_model(const char *config_json)`
- **Request JSON Schema**:
  ```json
  {
    "model_path": "/var/mobile/.../gemma-4-e2b-it-4bit",
    "model_id": "mlx-community/gemma-4-e2b-it-4bit", // Optional
    "revision": null, // Optional string
    "thinking_enabled": true, // Optional (defaults to true)
    "lazy_encoders": true // Optional (defaults to true)
  }
  ```
- **Response JSON Schema**:
  ```json
  {
    "ok": true,
    "handle": 1,
    "status": "ready",
    "model_id": "mlx-community/gemma-4-e2b-it-4bit"
  }
  ```

### 2. `lib_mlx_start_server`
Starts the local OpenAI-compatible HTTP server bound to the specified model handle.
- **Signature**: `char *lib_mlx_start_server(int64_t handle, const char *config_json)`
- **Request JSON Schema**:
  ```json
  {
    "host": "127.0.0.1", // Defaults to "127.0.0.1"
    "port": 0,           // Port to bind. Use 0 for dynamic allocation.
    "model_id": "mlx-community/gemma-4-e2b-it-4bit",
    "queue_limit": 1
  }
  ```
- **Response JSON Schema**:
  ```json
  {
    "ok": true,
    "handle": 1,
    "server": {
      "host": "127.0.0.1",
      "port": 58291,
      "base_url": "http://127.0.0.1:58291",
      "model_id": "mlx-community/gemma-4-e2b-it-4bit",
      "status": "running"
    }
  }
  ```

### 3. `lib_mlx_stop_server`
Stops the server bound to the specified model handle.
- **Signature**: `char *lib_mlx_stop_server(int64_t handle)`
- **Response JSON Schema**:
  ```json
  { "ok": true, "handle": 1, "status": "stopped" }
  ```

### 4. `lib_mlx_server_status`
Returns status info about the model and server.
- **Signature**: `char *lib_mlx_server_status(int64_t handle)`
- **Response JSON Schema**:
  ```json
  {
    "ok": true,
    "handle": 1,
    "model": {
      "status": "ready",
      "model_id": "mlx-community/gemma-4-e2b-it-4bit",
      "model_path": "/var/mobile/.../gemma-4-e2b-it-4bit"
    },
    "server": {
      "status": "running" // Or "stopped"
    }
  }
  ```

### 5. `lib_mlx_unload_model`
Stops the server if running and unloads the loaded model.
- **Signature**: `char *lib_mlx_unload_model(int64_t handle)`
- **Response JSON Schema**:
  ```json
  { "ok": true, "handle": 1, "status": "unloaded" }
  ```

### 6. `lib_mlx_free`
Frees a string pointer allocated by the native runtime.
- **Signature**: `void lib_mlx_free(void *ptr)`

---

## Dart API Reference

Dart wrappers are placed under the [lib/src/](lib/src/) directory.

### Lifecyle Management (`LibMlxRuntime`)
`LibMlxRuntime` wraps the low-level FFI bindings, managing handles and running C calls within Dart `Isolates` to prevent main-thread blockage:

```dart
import 'package:lib_mlx/lib_mlx.dart';

final runtime = LibMlxRuntime();

// 1. Load Model
final handle = await runtime.loadModel(
  const MlxModelConfig(
    modelPath: '/path/to/gemma-4-e2b-it-4bit',
    thinkingEnabled: true,
  ),
);

// 2. Start HTTP Server
final serverInfo = await runtime.startServer(
  handle,
  config: const MlxServerConfig(port: 8080), // Use port 0 for random selection
);
print('Server running on ${serverInfo.baseUrl}');

// 3. Check status
final status = await runtime.serverStatus(handle);
print('Model status: ${status.modelStatus}, Server status: ${status.serverStatus}');

// 4. Unload model & stop server
await runtime.unloadModel(handle);
```

### OpenAI Client (`LibMlxOpenAiClient`)
The client establishes a connection to the local HTTP server. It supports both standard HTTP JSON requests and Server-Sent Events (SSE) streams:

```dart
final client = LibMlxOpenAiClient(baseUri: serverInfo.uri);

// List Models
final models = await client.listModels();

// Chat Completions (REST response)
final response = await client.chatCompletions({
  'model': serverInfo.modelId,
  'messages': [
    {'role': 'user', 'content': 'Is the capital of France Paris? Answer Yes or No.'}
  ],
  'temperature': 0.0,
});
print(response['choices'][0]['message']['content']); // "Yes"

// Chat Completions (SSE Stream)
final stream = client.chatCompletionsStream({
  'model': serverInfo.modelId,
  'messages': [
    {'role': 'user', 'content': 'Describe Paris in 50 words.'}
  ]
});

await for (final event in stream) {
  if (event.done) break;
  // Read chunk delta contents
  final choice = event.data?['choices']?[0] as Map?;
  final delta = choice?['delta'] as Map?;
  if (delta != null) {
    if (delta.containsKey('reasoning_content')) {
      print('[Thinking] ${delta['reasoning_content']}');
    }
    if (delta.containsKey('content')) {
      print('[Content] ${delta['content']}');
    }
  }
}
```

---

## Local Server Endpoint Specs

The localhost server (`LocalOpenAIServer.swift`) exposes the following endpoints:

### 1. `GET /v1/models`
Returns list of models currently loaded.
```json
{
  "object": "list",
  "data": [
    {
      "id": "mlx-community/gemma-4-e2b-it-4bit",
      "object": "model",
      "created": 1717320000,
      "owned_by": "local"
    }
  ]
}
```

### 2. `POST /v1/chat/completions`
Generates text completions matching the OpenAI specification.
- **Request Properties**:
  - `model`: Target model ID string.
  - `messages`: List of message objects.
  - `temperature`: Temperature double.
  - `max_tokens` / `max_output_tokens`: Max number of generated tokens.
  - `thinking`: Boolean flag to toggle reasoning-content output.
  - `stream`: Set `true` to request SSE chunk streaming.
  - `tools`: Structured tool definitions.
- **Response Format (Non-streaming)**:
  ```json
  {
    "id": "chatcmpl_xxxx",
    "object": "chat.completion",
    "created": 1717320000,
    "model": "mlx-community/gemma-4-e2b-it-4bit",
    "choices": [{
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Paris",
        "reasoning_content": "The user is asking for the capital..." // Optional
      },
      "finish_reason": "stop"
    }],
    "usage": {
      "input_tokens": 0,
      "output_tokens": 12,
      "output_tokens_details": { "reasoning_tokens": 8 },
      "total_tokens": 12
    }
  }
  ```

### 3. `POST /v1/responses`
Implements streaming using the OpenAI Responses lifecycle spec. The SSE streaming format (`stream: true`) publishes the following sequence of typed events, each including a `sequence_number`:
1. `response.created`: Initial response object state showing status `"in_progress"`.
2. `response.output_item.added`: Triggered when an output chunk (such as message or tool calls) begins.
3. `response.reasoning_text.delta` & `done`: Streaming and finalization of reasoning tokens.
4. `response.content_part.added`: Triggers when an output text part starts.
5. `response.output_text.delta` & `done`: Streaming and finalization of text content.
6. `response.content_part.done`: Text part emission complete.
7. `response.function_call_arguments.delta` & `done`: Emits structured JSON arguments for requested tool calls.
8. `response.output_item.done`: Marks compilation of the message or tool call.
9. `response.completed`: Terminal event containing the complete, final `Response` payload.

---

## Build, Run & Verification

### Prerequisites
- macOS host running Swift 5.9+ / Xcode 15+
- Flutter SDK configured for iOS development

### iOS Host App Configuration

Set the minimum iOS version in your app's `ios/Podfile`:
```ruby
platform :ios, '17.0'
```

Use static framework linkage in `ios/Podfile`:
```ruby
use_frameworks! :linkage => :static
```

Enable file sharing in `ios/Runner/Info.plist` if the app needs users to import or inspect local model files:
```xml
<key>UIFileSharingEnabled</key>
<true/>
```

Add a local network access description in `ios/Runner/Info.plist` for development builds that expose or discover local inference services:
```xml
<key>NSLocalNetworkUsageDescription</key>
<string>This app requires local network access for model inference services.</string>
```

Optionally disable the minimum frame duration limit in `ios/Runner/Info.plist` for smoother high-refresh-rate UI:
```xml
<key>CADisableMinimumFrameDurationOnPhone</key>
<true/>
```

For large on-device models, add memory entitlements in `ios/Runner/Runner.entitlements`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.developer.kernel.extended-virtual-addressing</key>
  <true/>
  <key>com.apple.developer.kernel.increased-memory-limit</key>
  <true/>
  <key>com.apple.developer.kernel.increased-debugging-memory-limit</key>
  <true/>
</dict>
</plist>
```

No host-side `Podfile` `post_install` hook is required for `lib_mlx`; the package's iOS Swift package and podspec already declare the required iOS platform and native library layout.

### Commands

**1. Re-Generate Dart FFI Bindings**
If you modify `src/lib_mlx.h`, update the Dart bindings:
```bash
dart run ffigen --config ffigen.yaml
```

**2. Verify Host Native Code**
Run SwiftPM tests directly on macOS (without running Xcode or iOS Simulator):
```bash
swift build
swift test
```

**3. Run Dart Unit Tests**
Verify JSON payload encoding/decoding and SSE stream parsing on the host:
```bash
flutter test
```

**4. Run Example Mobile App**
To run the testing harness on an iOS simulator or physical device:
```bash
cd example
flutter run
```

---

## Phase 0 Development Status & Decisions

This repository currently hosts the **Phase 0B/0C host-side scaffold**. It uses a mock native core and custom TCP listener so translation, JSON schemas, SSE stream builders, and Dart layers can be fully validated on a macOS host.

### Remaining Phase 0A Tasks (On-Device Verification)
Device validation requires a physical Apple Silicon device (iPhone 15 Pro, A17 Pro, or Apple Silicon iPad) and the local model binary to confirm:
1. **Dynamic Memory Bounds**: Confirming model weights load inside iOS runtime sandboxes with appropriate memory entitlements.
2. **Vision/Audio Preprocessing**: Integrating image/audio sample buffers into raw token feeds.
3. **Turn-Stripping Logic**: Stripping prior-turn `<thinking>` tags before constructing the next prompt token buffer.

### Key Architecture Decisions
- **MLX Swift Dependency Vendoring**: Mainline `mlx-swift-lm` is expected to lack Gemma 4 audio support. VincentGourbin's `gemma-4-swift-mlx` fork is the current baseline target.
- **Swift HTTP Framework**: The server currently uses a lightweight wrapper over `NWListener`. Before replacing the stubs, final alignment is required on whether to keep `NWListener` or move to a structured framework like `Hummingbird` or `Vapor` depending on binary footprint constraints.
