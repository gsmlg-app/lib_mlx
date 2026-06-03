import 'package:flutter_test/flutter_test.dart';
import 'package:lib_mlx/lib_mlx.dart';

void main() {
  test('model config encodes lifecycle fields', () {
    const config = MlxModelConfig(
      modelPath: '/models/gemma',
      revision: '99d9a53',
      thinkingEnabled: false,
    );

    expect(config.toJson(), <String, Object?>{
      'model_path': '/models/gemma',
      'model_id': 'mlx-community/gemma-4-e2b-it-4bit',
      'revision': '99d9a53',
      'thinking_enabled': false,
      'lazy_encoders': true,
    });
  });

  test('server info parses native json', () {
    final info = MlxServerInfo.fromJson(<String, Object?>{
      'host': '127.0.0.1',
      'port': 8080,
      'base_url': 'http://127.0.0.1:8080',
      'model_id': 'local-model',
      'status': 'running',
    });

    expect(info.uri, Uri.parse('http://127.0.0.1:8080'));
    expect(info.modelId, 'local-model');
    expect(info.status, 'running');
  });
}
