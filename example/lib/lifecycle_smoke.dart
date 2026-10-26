import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lib_mlx/lib_mlx.dart';
import 'package:path_provider/path_provider.dart';

// Physical-device probe: foreground this app, wait for the ready file, open
// Settings, then reactivate this same process without --terminate-existing.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final progress = ValueNotifier<String>(
    'Loading real model for lifecycle probe',
  );
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
  final witness = _LifecycleWitness();
  final documentsDirectory = await getApplicationDocumentsDirectory();
  await documentsDirectory.create(recursive: true);
  final documents = documentsDirectory.path;
  const runId = String.fromEnvironment('LIB_MLX_SMOKE_RUN_ID');
  const runtime = LibMlxRuntime();
  MlxModelHandle? handle;
  LibMlxOpenAiClient? client;
  Map<String, Object?> report;
  try {
    handle = await runtime.loadModel(
      MlxModelConfig(modelPath: '$documents/gemma-4-e2b', contextLength: 4096),
    );
    final server = await runtime.startServer(handle);
    client = LibMlxOpenAiClient(baseUri: server.uri);
    var announced = false;
    String? interrupted;
    try {
      await for (final event in client.chatCompletionsStream({
        'thinking': false,
        'max_tokens': 2048,
        'messages': [
          {
            'role': 'user',
            'content':
                'Count from 1 to 10000, one number per line. Keep going.',
          },
        ],
      })) {
        final hasText = (event.data?['choices'] as List? ?? const []).any(
          (choice) =>
              (((choice as Map)['delta'] as Map?)?['content'] as String? ?? '')
                  .isNotEmpty,
        );
        if (!announced && hasText) {
          announced = true;
          await File(
            '$documents/lib_mlx-lifecycle-ready.json',
          ).writeAsString(jsonEncode({'run_id': runId, 'phase': 'generating'}));
          progress.value =
              'Generating. Open Settings, then return to this app.';
        }
      }
    } catch (error) {
      interrupted = '$error';
    }
    if (!announced || interrupted == null || !witness.inactive.isCompleted) {
      throw StateError(
        'Generation did not fail during background transition: $interrupted',
      );
    }
    await witness.resumed.future.timeout(const Duration(minutes: 2));
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    var status = await runtime.serverStatus(handle);
    while (status.modelStatus != 'ready' && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      status = await runtime.serverStatus(handle);
    }
    if (status.modelStatus != 'ready' || status.serverStatus != 'stopped') {
      throw StateError(
        'Foreground did not restore safe stopped state: ${status.modelStatus}/${status.serverStatus}',
      );
    }
    client.close(force: true);
    final restarted = await runtime.startServer(handle);
    client = LibMlxOpenAiClient(baseUri: restarted.uri);
    final response = await client.chatCompletions({
      'thinking': false,
      'max_tokens': 16,
      'messages': [
        {'role': 'user', 'content': 'Reply OK only.'},
      ],
    });
    final text =
        ((response['choices'] as List).first['message'] as Map)['content']
            as String;
    if (text.isEmpty ||
        (response['usage'] as Map)['completion_tokens'] as int <= 0) {
      throw StateError('No real generation after foreground resume');
    }
    report = {
      'status': 'passed',
      'background_cancellation_error': interrupted,
      'foreground_text': text,
      'memory': (await runtime.serverStatus(handle)).metrics,
    };
  } catch (error, stack) {
    report = {'status': 'failed', 'error': '$error', 'stack': '$stack'};
  } finally {
    client?.close(force: true);
    if (handle != null) await runtime.unloadModel(handle);
    witness.dispose();
  }
  report.addAll({
    'run_id': runId,
    'source_digest': const String.fromEnvironment('LIB_MLX_SOURCE_DIGEST'),
    'model_revision': MlxAvailableModel.pinnedE2bRevision,
    'platform': Platform.operatingSystem,
    'os': Platform.operatingSystemVersion,
    'build_mode': const bool.fromEnvironment('dart.vm.product')
        ? 'release'
        : 'debug',
    'lifecycle_states': witness.states,
  });
  await File(
    '$documents/lib_mlx-lifecycle-report.json',
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  progress.value = jsonEncode(report);
}

class _LifecycleWitness extends WidgetsBindingObserver {
  _LifecycleWitness() {
    WidgetsBinding.instance.addObserver(this);
  }
  final inactive = Completer<void>();
  final resumed = Completer<void>();
  final states = <String>[];
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    states.add(state.name);
    if (state == AppLifecycleState.inactive && !inactive.isCompleted) {
      inactive.complete();
    }
    if (state == AppLifecycleState.resumed &&
        inactive.isCompleted &&
        !resumed.isCompleted) {
      resumed.complete();
    }
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
  }
}
