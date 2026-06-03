import 'package:flutter_test/flutter_test.dart';
import 'package:lib_mlx/src/openai_client.dart';

void main() {
  test('parses typed responses events', () async {
    final events = await parseSse(
      Stream<String>.fromIterable(const <String>[
        'event: response.output_text.delta',
        'data: {"type":"response.output_text.delta","delta":"Paris"}',
        '',
        'event: response.completed',
        'data: {"type":"response.completed","response":{"status":"completed"}}',
        '',
      ]),
    ).toList();

    expect(events, hasLength(2));
    expect(events.first.event, 'response.output_text.delta');
    expect(events.first.data?['delta'], 'Paris');
    expect(events.last.event, 'response.completed');
  });

  test('parses chat done sentinel', () async {
    final events = await parseSse(
      Stream<String>.fromIterable(const <String>[
        'data: {"choices":[{"delta":{"content":"Paris"}}]}',
        '',
        'data: [DONE]',
        '',
      ]),
    ).toList();

    expect(events, hasLength(2));
    expect(events.first.data?['choices'], isA<List<Object?>>());
    expect(events.last.done, isTrue);
  });
}
