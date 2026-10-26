import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:lib_mlx/runtime_smoke.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final progress = ValueNotifier<String>('Starting real MLX public API smoke…');
  runApp(
    MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: ValueListenableBuilder(
            valueListenable: progress,
            builder: (_, value, _) =>
                SingleChildScrollView(child: SelectableText(value)),
          ),
        ),
      ),
    ),
  );
  final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
  const configuredPath = String.fromEnvironment('LIB_MLX_MODEL_PATH');
  final path = configuredPath.isEmpty
      ? '$home/Documents/gemma-4-e2b'
      : configuredPath;
  final reportPath = '$home/Documents/lib_mlx-smoke-report.json';
  final progressFile = File('$home/Documents/lib_mlx-smoke-progress.json');
  void recordProgress(String phase) {
    progressFile.writeAsStringSync(
      jsonEncode({
        'run_id': const String.fromEnvironment('LIB_MLX_SMOKE_RUN_ID'),
        'phase': phase,
        'model_path': path,
      }),
    );
  }

  Map<String, Object?> report;
  try {
    recordProgress('dart_entry_started');
    report = await runRuntimeSmoke(
      modelPath: path,
      contextLength: const int.fromEnvironment(
        'LIB_MLX_CONTEXT_LENGTH',
        defaultValue: 4096,
      ),
      log: (message) {
        progress.value += '\n$message';
        debugPrint(message);
        recordProgress(message);
      },
    );
  } catch (error, stack) {
    report = {'status': 'failed', 'error': '$error', 'stack': '$stack'};
  }
  report['platform'] = Platform.operatingSystem;
  report['os'] = Platform.operatingSystemVersion;
  report['host'] = 'flutter';
  report['build_mode'] = const bool.fromEnvironment('dart.vm.product')
      ? 'release'
      : 'debug';
  report['source_digest'] = const String.fromEnvironment(
    'LIB_MLX_SOURCE_DIGEST',
  );
  report['run_id'] = const String.fromEnvironment('LIB_MLX_SMOKE_RUN_ID');
  await File(
    reportPath,
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  progress.value += '\n${jsonEncode(report)}\nReport: $reportPath';
  debugPrint('LIB_MLX_SMOKE_RESULT ${jsonEncode(report)}');
}
