import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lib_mlx/lib_mlx.dart';

void main() {
  final executable = Platform.environment['LIB_MLX_PROTOCOL_HOST'];
  test(
    'public Dart client reaches Swift converter and receives live deltas',
    () async {
      final host = await Process.start(executable!, []);
      final errors = host.stderr.transform(utf8.decoder).join();
      LibMlxOpenAiClient? client;
      try {
        final baseUrl = await host.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 15));
        client = LibMlxOpenAiClient(baseUri: Uri.parse(baseUrl));
        final elapsed = Stopwatch()..start();
        int? first;
        var content = '';
        await for (final event in client.chatCompletionsStream({
          'thinking': false,
          'max_tokens': 19,
          'messages': [
            {'role': 'system', 'content': '系统指令'},
            {'role': 'user', 'content': '中文与 emoji 🌏'},
          ],
        })) {
          for (final choice in event.data?['choices'] as List? ?? []) {
            final delta = (choice as Map)['delta'] as Map?;
            if (delta?['content'] case final String text) {
              first ??= elapsed.elapsedMilliseconds;
              content += text;
            }
          }
        }
        expect(elapsed.elapsedMilliseconds - first!, greaterThanOrEqualTo(200));
        final echo = jsonDecode(content.split('\nfinished').first) as Map;
        expect(echo['text'], '系统指令中文与 emoji 🌏');
        expect(echo['max_tokens'], 19);
        expect(echo['thinking'], false);
        final response = await client.responses({
          'instructions': '遵循此指令',
          'input': '输入',
          'thinking': false,
        });
        expect(response.toString(), contains('遵循此指令'));
        final typed = {
          'n': 3,
          'ok': true,
          'items': [
            1,
            null,
            {'nested': '值'},
          ],
        };
        final toolResponse = await client.chatCompletions({
          'messages': [
            {'role': 'user', 'content': '工具'},
          ],
          'tools': [
            {
              'type': 'function',
              'function': {
                'name': 'f',
                'parameters': {
                  'type': 'object',
                  'properties': {
                    'n': {'type': 'number'},
                  },
                  'example': typed,
                },
              },
            },
          ],
        });
        final toolContent =
            ((toolResponse['choices'] as List).first['message']
                    as Map)['content']
                as String;
        final toolEcho =
            jsonDecode(toolContent.split('\nfinished').first) as Map;
        expect(
          ((toolEcho['tools'] as List).first['function']
              as Map)['parameters']['example'],
          typed,
        );
      } finally {
        client?.close(force: true);
        host.stdin.writeln();
        await host.stdin.close();
        expect(
          await host.exitCode.timeout(const Duration(seconds: 15)),
          0,
          reason: await errors,
        );
      }
    },
    skip: executable == null
        ? 'Set LIB_MLX_PROTOCOL_HOST to the built Swift executable.'
        : false,
  );
}
