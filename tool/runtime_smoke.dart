import 'dart:convert';
import 'dart:io';

import 'package:lib_mlx/runtime_smoke.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart run tool/runtime_smoke.dart MODEL_PATH [DYLIB_PATH] [CONTEXT_LENGTH]',
    );
    exitCode = 64;
    return;
  }
  final report = await runRuntimeSmoke(
    modelPath: File(args[0]).absolute.path,
    libraryPath: args.length > 1 ? File(args[1]).absolute.path : null,
    contextLength: args.length > 2 ? int.parse(args[2]) : 4096,
    log: stderr.writeln,
  );
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
}
