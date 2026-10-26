import 'dart:io';

import 'package:lib_mlx/lib_mlx.dart';

Future<void> main(List<String> args) async {
  final runtime = LibMlxRuntime(
    libraryPath: args.isEmpty ? null : File(args.single).absolute.path,
  );
  Future<void> rejects(Future<Object?> action) async {
    try {
      await action;
      throw StateError('Invalid native request unexpectedly succeeded');
    } on MlxLifecycleException catch (error) {
      stdout.writeln('${error.code}: ${error.message}');
    }
  }

  await rejects(
    runtime.loadModel(
      const MlxModelConfig(modelPath: '/lib-mlx-does-not-exist'),
    ),
  );
  const absent = MlxModelHandle(value: -1, modelId: 'absent');
  await rejects(runtime.startServer(absent));
  await rejects(runtime.stopServer(absent));
  await rejects(runtime.serverStatus(absent));
  await rejects(runtime.unloadModel(absent));
  stdout.writeln(
    'FFI lifecycle exports and result freeing passed (no inference claim).',
  );
}
