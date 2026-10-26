import 'dart:async';

import 'package:lib_mlx/lib_mlx.dart';

/// Runs the public Dart -> FFI -> HTTP -> MLX -> SSE path. No test backend.
Future<Map<String, Object?>> runRuntimeSmoke({
  required String modelPath,
  String? libraryPath,
  int contextLength = 4096,
  void Function(String)? log,
}) async {
  final runtime = LibMlxRuntime(libraryPath: libraryPath);
  final checks = <String, Object?>{};
  void passed(String name, [Object? evidence = true]) {
    checks[name] = evidence;
    log?.call('$name: $evidence');
  }

  Future<void> expectLifecycleFailure(
    Future<Object?> action,
    String code,
  ) async {
    try {
      await action;
      throw StateError('Expected lifecycle failure: $code');
    } on MlxLifecycleException catch (error) {
      if (error.code != code && code != '*') rethrow;
      passed('rejected_${error.code}', error.message);
    }
  }

  log?.call('checking_missing_model_rejection');
  await expectLifecycleFailure(
    runtime.loadModel(
      MlxModelConfig(
        modelPath: '$modelPath/does-not-exist',
        contextLength: contextLength,
      ),
    ),
    '*',
  );
  log?.call('loading_pinned_model');
  final handle = await runtime.loadModel(
    MlxModelConfig(
      modelPath: modelPath,
      revision: MlxAvailableModel.pinnedE2bRevision,
      contextLength: contextLength,
    ),
  );
  passed('loaded_model', handle.modelId);
  LibMlxOpenAiClient? client;
  var unloaded = false;
  try {
    final server = await runtime.startServer(handle);
    client = LibMlxOpenAiClient(baseUri: server.uri);
    passed('release_ffi_and_listener', server.baseUrl);
    final models = await client.listModels();
    if ((models['data'] as List).first['id'] != handle.modelId) {
      throw StateError(
        'Server model identity differs from the resident handle',
      );
    }
    final first = await client.chatCompletions({
      'model': handle.modelId,
      'thinking': false,
      'max_tokens': 32,
      'temperature': 0,
      'top_p': 1.0,
      'top_k': 0,
      'seed': 42,
      'messages': [
        {'role': 'system', 'content': 'Answer briefly in English.'},
        {
          'role': 'user',
          'content': 'My secret codeword is aqua. Remember it. Say OK.',
        },
      ],
    });
    final firstText =
        ((first['choices'] as List).first['message'] as Map)['content']
            as String;
    if (firstText.isEmpty || firstText.contains('Stub')) {
      throw StateError('No real text generation');
    }
    final usage = first['usage'] as Map;
    if ((usage['prompt_tokens'] as int) <= 0 ||
        (usage['completion_tokens'] as int) <= 0) {
      throw StateError('Usage did not contain real tokenizer counts');
    }
    passed('text_and_token_usage', {'text': firstText, 'usage': usage});
    final second = await client.responses({
      'instructions': 'Reply with the codeword only.',
      'thinking': false,
      'max_output_tokens': 32,
      'input': [
        {'role': 'user', 'content': 'My secret codeword is aqua. Remember it.'},
        {'role': 'assistant', 'content': firstText},
        {'role': 'user', 'content': 'What is my secret codeword?'},
      ],
    });
    if (!second.toString().toLowerCase().contains('aqua')) {
      throw StateError(
        'Multi-turn/instructions smoke did not retain the codeword: $second',
      );
    }
    passed('multi_turn_instructions', second);
    var reasoning = '';
    var text = '';
    var deltas = 0;
    var sawDone = false;
    final streamTime = Stopwatch()..start();
    int? firstDeltaMs;
    await for (final event in client.chatCompletionsStream({
      'model': handle.modelId,
      'thinking': true,
      'max_tokens': 256,
      'messages': [
        {'role': 'user', 'content': 'What is 2 plus 2? Answer briefly.'},
      ],
    })) {
      if (event.done) sawDone = true;
      for (final choice in event.data?['choices'] as List? ?? const []) {
        final delta = (choice as Map)['delta'] as Map? ?? const {};
        final content = delta['content'] as String? ?? '';
        final thought = delta['reasoning_content'] as String? ?? '';
        if (content.isNotEmpty || thought.isNotEmpty) {
          firstDeltaMs ??= streamTime.elapsedMilliseconds;
          deltas++;
          text += content;
          reasoning += thought;
        }
      }
    }
    if (!sawDone || deltas < 2 || text.isEmpty || reasoning.isEmpty) {
      throw StateError(
        'Missing incremental thinking/text output: $deltas deltas, text=$text, reasoning=$reasoning',
      );
    }
    passed('thinking_stream', {
      'text': text,
      'reasoning': reasoning,
      'deltas': deltas,
      'first_delta_ms': firstDeltaMs,
      'total_ms': streamTime.elapsedMilliseconds,
    });
    try {
      await client.chatCompletions({
        'messages': [
          {
            'role': 'user',
            'content': List.filled(contextLength * 2, ' hello').join(),
          },
        ],
        'thinking': false,
        'max_tokens': contextLength,
      });
      throw StateError('Context overflow was silently accepted');
    } on MlxHttpException catch (error) {
      if (!error.body.contains('context')) rethrow;
      passed('context_admission', error.body);
    }
    final probe = await client.chatCompletions({
      'thinking': false,
      'max_tokens': 8,
      'messages': [
        {'role': 'system', 'content': 'Answer OK only.'},
        {
          'role': 'user',
          'content': List.filled(contextLength - 128, 'hello').join(' '),
        },
      ],
    });
    final probeUsage = probe['usage'] as Map;
    if ((probeUsage['prompt_tokens'] as int) < contextLength * 0.9) {
      throw StateError(
        'Context probe did not exercise the configured window: $probeUsage',
      );
    }
    passed('context_probe', probeUsage);
    // Cancelling after the first real delta must close HTTP and drain generation.
    await client
        .chatCompletionsStream({
          'thinking': false,
          'max_tokens': 512,
          'messages': [
            {
              'role': 'user',
              'content': 'Count from 1 to 1000, one number per line.',
            },
          ],
        })
        .firstWhere(
          (event) => (event.data?['choices'] as List? ?? const []).any(
            (choice) => ((choice as Map)['delta'] as Map?)?['content'] != null,
          ),
        );
    await runtime.stopServer(handle);
    passed(
      'cancel_and_stop',
      (await runtime.serverStatus(handle)).serverStatus,
    );
    await runtime.startServer(handle);
    passed('memory', (await runtime.serverStatus(handle)).metrics);
    await runtime.unloadModel(handle);
    unloaded = true;
    await expectLifecycleFailure(runtime.startServer(handle), 'invalid_handle');
    passed('unloaded');
  } finally {
    client?.close(force: true);
    if (!unloaded) await runtime.unloadModel(handle);
  }
  final reloaded = await runtime.loadModel(
    MlxModelConfig(modelPath: modelPath, contextLength: contextLength),
  );
  await runtime.unloadModel(reloaded);
  passed('repeat_load_unload');
  return {
    'status': 'passed',
    'model_revision': MlxAvailableModel.pinnedE2bRevision,
    'context_length': contextLength,
    'checks': checks,
  };
}
