import 'package:flutter_test/flutter_test.dart';
import 'package:lib_mlx/lib_mlx.dart';

void main() {
  test(
    'available model config maps supported aliases to Hugging Face pages',
    () {
      expect(MlxAvailableModel.values.map((model) => model.id), <String>[
        'gemma-4-e4b',
        'gemma-4-e2b',
      ]);

      expect(MlxAvailableModel.byId, <String, MlxAvailableModel>{
        'gemma-4-e4b': MlxAvailableModel.gemma4E4b,
        'gemma-4-e2b': MlxAvailableModel.gemma4E2b,
      });
      expect(
        MlxAvailableModel.gemma4E4b.huggingFaceModelId,
        'mlx-community/gemma-4-e4b-it-4bit',
      );
      expect(
        MlxAvailableModel.gemma4E4b.huggingFaceModelPageUrl,
        'https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit',
      );
      expect(
        MlxAvailableModel.gemma4E2b.huggingFaceModelId,
        'mlx-community/gemma-4-e2b-it-4bit',
      );
      expect(
        MlxAvailableModel.gemma4E2b.huggingFaceModelPageUrl,
        'https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit',
      );
    },
  );

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

  test('model config can use an available model alias', () {
    final config = MlxModelConfig.forAvailableModel(
      modelPath: '/models/gemma-4-e4b',
      model: MlxAvailableModel.gemma4E4b,
    );

    expect(config.toJson(), <String, Object?>{
      'model_path': '/models/gemma-4-e4b',
      'model_id': 'mlx-community/gemma-4-e4b-it-4bit',
      'thinking_enabled': true,
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
