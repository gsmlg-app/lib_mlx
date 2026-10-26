import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lib_mlx/lib_mlx.dart';

void main() {
  late HttpServer server;
  late LibMlxOpenAiClient client;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = LibMlxOpenAiClient(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
    );
  });
  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
  });

  for (final streaming in [false, true]) {
    test('UTF-8 POST has exact byte length (stream=$streaming)', () async {
      final body = <String, Object?>{
        'messages': [
          {'role': 'user', 'content': '你好，世界 🌏'},
        ],
        'tools': [
          {
            'type': 'function',
            'function': {
              'name': '示例',
              'parameters': {
                'count': 3,
                'flag': true,
                'nested': {
                  'items': [1, null, '文本'],
                },
              },
            },
          },
        ],
        if (streaming) 'stream': true,
      };
      final received = server.first.then((request) async {
        expect(request.contentLength, utf8.encode(jsonEncode(body)).length);
        expect(
          request.headers.value(HttpHeaders.transferEncodingHeader),
          isNull,
        );
        expect(jsonDecode(await utf8.decoder.bind(request).join()), body);
        request.response.headers.contentType = streaming
            ? ContentType('text', 'event-stream', charset: 'utf-8')
            : ContentType.json;
        request.response.write(streaming ? 'data: [DONE]\n\n' : '{"ok":true}');
        await request.response.close();
      });
      if (streaming) {
        expect(
          (await client.chatCompletionsStream(body).toList()).single.done,
          isTrue,
        );
      } else {
        expect(await client.chatCompletions(body), {'ok': true});
      }
      await received;
    });
  }

  test(
    'SSE rejects a successful JSON response with the diagnostic body',
    () async {
      final served = server.first.then((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"error":{"message":"backend failed"}}');
        await request.response.close();
      });
      await expectLater(
        client.chatCompletionsStream({}).toList(),
        throwsA(
          isA<MlxHttpException>().having(
            (error) => error.body,
            'body',
            contains('backend failed'),
          ),
        ),
      );
      await served;
    },
  );

  test('SSE rejects EOF before the endpoint terminal event', () async {
    final served = server.first.then((request) async {
      await request.drain<void>();
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      request.response.write(
        'data: {"choices":[{"delta":{"content":"中"}}]}\n\n',
      );
      await request.response.close();
    });
    await expectLater(
      client.chatCompletionsStream({}).toList(),
      throwsA(
        isA<MlxHttpException>().having(
          (error) => error.body,
          'body',
          contains('terminal'),
        ),
      ),
    );
    await served;
  });

  test('SSE generation errors never become successful completion', () async {
    final served = server.first.then((request) async {
      await request.drain<void>();
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      request.response.write(
        'event: error\ndata: {"error":{"message":"cancelled"}}\n\n',
      );
      await request.response.close();
    });
    await expectLater(
      client.chatCompletionsStream({}).toList(),
      throwsA(isA<MlxHttpException>()),
    );
    await served;
  });

  test('Responses requires completed rather than an ordinary EOF', () async {
    final served = server.first.then((request) async {
      await request.drain<void>();
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      request.response.write(
        'event: response.completed\n'
        'data: {"type":"response.completed","response":{"status":"completed"}}\n\n',
      );
      await request.response.close();
    });
    expect(
      (await client.responsesStream({'input': '中文'}).toList()).single.event,
      'response.completed',
    );
    await served;
  });
}
