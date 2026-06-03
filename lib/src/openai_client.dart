import 'dart:async';
import 'dart:convert';
import 'dart:io';

class LibMlxOpenAiClient {
  LibMlxOpenAiClient({
    required Uri baseUri,
    this.apiKey,
    HttpClient? httpClient,
  }) : _baseUri = _normalizeBaseUri(baseUri),
       _httpClient = httpClient ?? HttpClient();

  final Uri _baseUri;
  final String? apiKey;
  final HttpClient _httpClient;

  Future<Map<String, Object?>> listModels() {
    return _getJson('/v1/models');
  }

  Future<Map<String, Object?>> chatCompletions(Map<String, Object?> request) {
    return _postJson('/v1/chat/completions', request);
  }

  Stream<MlxSseEvent> chatCompletionsStream(Map<String, Object?> request) {
    return _postSse('/v1/chat/completions', <String, Object?>{
      ...request,
      'stream': true,
    });
  }

  Future<Map<String, Object?>> responses(Map<String, Object?> request) {
    return _postJson('/v1/responses', request);
  }

  Stream<MlxSseEvent> responsesStream(Map<String, Object?> request) {
    return _postSse('/v1/responses', <String, Object?>{
      ...request,
      'stream': true,
    });
  }

  void close({bool force = false}) {
    _httpClient.close(force: force);
  }

  Future<Map<String, Object?>> _getJson(String path) async {
    final request = await _httpClient.getUrl(_uri(path));
    _applyHeaders(request, accept: ContentType.json);
    final response = await request.close();
    return _decodeJsonResponse(response);
  }

  Future<Map<String, Object?>> _postJson(
    String path,
    Map<String, Object?> body,
  ) async {
    final request = await _httpClient.postUrl(_uri(path));
    _applyHeaders(request, accept: ContentType.json);
    request.headers.contentType = ContentType.json;
    request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close();
    return _decodeJsonResponse(response);
  }

  Stream<MlxSseEvent> _postSse(String path, Map<String, Object?> body) async* {
    final request = await _httpClient.postUrl(_uri(path));
    _applyHeaders(request, accept: ContentType('text', 'event-stream'));
    request.headers.contentType = ContentType.json;
    request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw await MlxHttpException.fromResponse(response);
    }

    yield* parseSse(
      response.transform(utf8.decoder).transform(const LineSplitter()),
    );
  }

  Future<Map<String, Object?>> _decodeJsonResponse(
    HttpClientResponse response,
  ) async {
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MlxHttpException(response.statusCode, text);
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw MlxHttpException(response.statusCode, text);
    }
    return decoded.cast<String, Object?>();
  }

  void _applyHeaders(HttpClientRequest request, {required ContentType accept}) {
    request.headers.set(HttpHeaders.acceptHeader, accept.toString());
    final apiKey = this.apiKey;
    if (apiKey != null && apiKey.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    }
  }

  Uri _uri(String path) {
    final basePath = _baseUri.path.endsWith('/')
        ? _baseUri.path.substring(0, _baseUri.path.length - 1)
        : _baseUri.path;
    return _baseUri.replace(path: '$basePath$path');
  }

  static Uri _normalizeBaseUri(Uri uri) {
    if (!uri.hasScheme) {
      return Uri.parse('http://$uri');
    }
    return uri;
  }
}

class MlxSseEvent {
  const MlxSseEvent({this.event, this.data, this.rawData, this.done = false});

  final String? event;
  final Map<String, Object?>? data;
  final String? rawData;
  final bool done;
}

class MlxHttpException implements Exception {
  const MlxHttpException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  static Future<MlxHttpException> fromResponse(
    HttpClientResponse response,
  ) async {
    return MlxHttpException(
      response.statusCode,
      await response.transform(utf8.decoder).join(),
    );
  }

  @override
  String toString() => 'MlxHttpException($statusCode): $body';
}

Stream<MlxSseEvent> parseSse(Stream<String> lines) async* {
  String? event;
  final dataLines = <String>[];

  FutureOr<MlxSseEvent?> flush() {
    if (event == null && dataLines.isEmpty) {
      return null;
    }
    final rawData = dataLines.join('\n');
    final emittedEvent = event;
    event = null;
    dataLines.clear();

    if (rawData == '[DONE]') {
      return MlxSseEvent(event: emittedEvent, rawData: rawData, done: true);
    }

    final decoded = jsonDecode(rawData);
    return MlxSseEvent(
      event: emittedEvent,
      rawData: rawData,
      data: decoded is Map ? decoded.cast<String, Object?>() : null,
    );
  }

  await for (final line in lines) {
    if (line.isEmpty) {
      final event = await flush();
      if (event != null) {
        yield event;
      }
      continue;
    }
    if (line.startsWith('event:')) {
      event = line.substring('event:'.length).trimLeft();
      continue;
    }
    if (line.startsWith('data:')) {
      dataLines.add(line.substring('data:'.length).trimLeft());
    }
  }

  final trailingEvent = await flush();
  if (trailingEvent != null) {
    yield trailingEvent;
  }
}
