import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'native_bindings.dart';
import 'types.dart';

class LibMlxRuntime {
  const LibMlxRuntime();

  Future<MlxModelHandle> loadModel(MlxModelConfig config) async {
    final result = await _invoke(
      _NativeCall.loadModel,
      jsonEncode(config.toJson()),
    );
    _throwIfError(result);
    return MlxModelHandle(
      value: result['handle'] as int,
      modelId: result['model_id'] as String? ?? config.modelId,
    );
  }

  Future<MlxServerInfo> startServer(
    MlxModelHandle handle, {
    MlxServerConfig config = const MlxServerConfig(),
  }) async {
    final result = await _invoke(
      _NativeCall.startServer,
      jsonEncode(config.toJson()),
      handle: handle.value,
    );
    _throwIfError(result);
    final server = (result['server'] as Map).cast<String, Object?>();
    return MlxServerInfo.fromJson(server);
  }

  Future<void> stopServer(MlxModelHandle handle) async {
    final result = await _invoke(
      _NativeCall.stopServer,
      '',
      handle: handle.value,
    );
    _throwIfError(result);
  }

  Future<MlxRuntimeStatus> serverStatus(MlxModelHandle handle) async {
    final result = await _invoke(
      _NativeCall.serverStatus,
      '',
      handle: handle.value,
    );
    _throwIfError(result);
    return MlxRuntimeStatus.fromJson(result);
  }

  Future<void> unloadModel(MlxModelHandle handle) async {
    final result = await _invoke(
      _NativeCall.unloadModel,
      '',
      handle: handle.value,
    );
    _throwIfError(result);
  }

  Future<Map<String, Object?>> _invoke(
    _NativeCall call,
    String json, {
    int handle = 0,
  }) async {
    if (!Platform.isIOS) {
      throw UnsupportedError('lib_mlx is iOS-only.');
    }

    final raw = await Isolate.run(() {
      final bindings = MlxNativeBindings.open();
      return switch (call) {
        _NativeCall.loadModel => bindings.loadModel(json),
        _NativeCall.startServer => bindings.startServer(handle, json),
        _NativeCall.stopServer => bindings.stopServer(handle),
        _NativeCall.serverStatus => bindings.serverStatus(handle),
        _NativeCall.unloadModel => bindings.unloadModel(handle),
      };
    });

    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const MlxLifecycleException(
        'invalid_native_response',
        'Native response was not a JSON object.',
      );
    }
    return decoded.cast<String, Object?>();
  }

  void _throwIfError(Map<String, Object?> result) {
    if (result['ok'] == true) {
      return;
    }

    final error = (result['error'] as Map?)?.cast<String, Object?>();
    throw MlxLifecycleException(
      error?['code'] as String? ?? 'native_error',
      error?['message'] as String? ?? 'Native lifecycle call failed.',
    );
  }
}

enum _NativeCall {
  loadModel,
  startServer,
  stopServer,
  serverStatus,
  unloadModel,
}
