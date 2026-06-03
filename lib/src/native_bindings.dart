import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../lib_mlx_bindings_generated.dart';

class MlxNativeBindings {
  MlxNativeBindings._(this._bindings);

  factory MlxNativeBindings.open() =>
      MlxNativeBindings._(LibMlxBindings(_openDynamicLibrary()));

  final LibMlxBindings _bindings;

  String loadModel(String configJson) {
    return _callWithJson(configJson, _bindings.lib_mlx_load_model);
  }

  String startServer(int handle, String configJson) {
    final config = configJson.toNativeUtf8().cast<ffi.Char>();
    try {
      return _takeString(_bindings.lib_mlx_start_server(handle, config));
    } finally {
      malloc.free(config);
    }
  }

  String stopServer(int handle) {
    return _takeString(_bindings.lib_mlx_stop_server(handle));
  }

  String serverStatus(int handle) {
    return _takeString(_bindings.lib_mlx_server_status(handle));
  }

  String unloadModel(int handle) {
    return _takeString(_bindings.lib_mlx_unload_model(handle));
  }

  String _callWithJson(
    String json,
    ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char>) call,
  ) {
    final input = json.toNativeUtf8().cast<ffi.Char>();
    try {
      return _takeString(call(input));
    } finally {
      malloc.free(input);
    }
  }

  String _takeString(ffi.Pointer<ffi.Char> pointer) {
    if (pointer == ffi.nullptr) {
      throw const MlxNativeBindingException('Native call returned null.');
    }
    try {
      return pointer.cast<Utf8>().toDartString();
    } finally {
      _bindings.lib_mlx_free(pointer.cast());
    }
  }
}

class MlxNativeBindingException implements Exception {
  const MlxNativeBindingException(this.message);

  final String message;

  @override
  String toString() => 'MlxNativeBindingException: $message';
}

ffi.DynamicLibrary _openDynamicLibrary() {
  if (!Platform.isIOS) {
    throw UnsupportedError('lib_mlx is iOS-only.');
  }

  try {
    return ffi.DynamicLibrary.open('lib_mlx.framework/lib_mlx');
  } on Object {
    return ffi.DynamicLibrary.process();
  }
}
