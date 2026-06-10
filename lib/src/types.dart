class MlxAvailableModel {
  const MlxAvailableModel._({
    required this.id,
    required this.huggingFaceModelId,
  });

  static const gemma4E4bId = 'gemma-4-e4b';
  static const gemma4E4bHuggingFaceModelId =
      'mlx-community/gemma-4-e4b-it-4bit';
  static const gemma4E2bId = 'gemma-4-e2b';
  static const gemma4E2bHuggingFaceModelId =
      'mlx-community/gemma-4-e2b-it-4bit';

  static const gemma4E4b = MlxAvailableModel._(
    id: gemma4E4bId,
    huggingFaceModelId: gemma4E4bHuggingFaceModelId,
  );
  static const gemma4E2b = MlxAvailableModel._(
    id: gemma4E2bId,
    huggingFaceModelId: gemma4E2bHuggingFaceModelId,
  );

  static const values = <MlxAvailableModel>[gemma4E4b, gemma4E2b];
  static const byId = <String, MlxAvailableModel>{
    gemma4E4bId: gemma4E4b,
    gemma4E2bId: gemma4E2b,
  };
  static const defaultModel = gemma4E2b;
  static const defaultHuggingFaceModelId = gemma4E2bHuggingFaceModelId;

  final String id;
  final String huggingFaceModelId;

  String get huggingFaceModelPageUrl =>
      'https://huggingface.co/$huggingFaceModelId';

  static MlxAvailableModel? fromId(String id) => byId[id];
}

class MlxModelConfig {
  const MlxModelConfig({
    required this.modelPath,
    this.modelId = MlxAvailableModel.defaultHuggingFaceModelId,
    this.revision,
    this.thinkingEnabled = true,
    this.lazyEncoders = true,
  });

  MlxModelConfig.forAvailableModel({
    required this.modelPath,
    required MlxAvailableModel model,
    this.revision,
    this.thinkingEnabled = true,
    this.lazyEncoders = true,
  }) : modelId = model.huggingFaceModelId;

  final String modelPath;
  final String modelId;
  final String? revision;
  final bool thinkingEnabled;
  final bool lazyEncoders;

  Map<String, Object?> toJson() => <String, Object?>{
    'model_path': modelPath,
    'model_id': modelId,
    if (revision != null) 'revision': revision,
    'thinking_enabled': thinkingEnabled,
    'lazy_encoders': lazyEncoders,
  };
}

class MlxServerConfig {
  const MlxServerConfig({
    this.host = '127.0.0.1',
    this.port = 0,
    this.modelId = MlxAvailableModel.defaultHuggingFaceModelId,
    this.queueLimit = 1,
  });

  final String host;
  final int port;
  final String modelId;
  final int queueLimit;

  Map<String, Object?> toJson() => <String, Object?>{
    'host': host,
    'port': port,
    'model_id': modelId,
    'queue_limit': queueLimit,
  };
}

class MlxModelHandle {
  const MlxModelHandle({required this.value, required this.modelId});

  final int value;
  final String modelId;

  @override
  String toString() => 'MlxModelHandle(value: $value, modelId: $modelId)';
}

class MlxServerInfo {
  const MlxServerInfo({
    required this.host,
    required this.port,
    required this.baseUrl,
    required this.modelId,
    required this.status,
  });

  factory MlxServerInfo.fromJson(Map<String, Object?> json) {
    return MlxServerInfo(
      host: json['host'] as String? ?? '127.0.0.1',
      port: json['port'] as int? ?? 0,
      baseUrl: json['base_url'] as String? ?? 'http://127.0.0.1:0',
      modelId:
          json['model_id'] as String? ??
          MlxAvailableModel.defaultHuggingFaceModelId,
      status: json['status'] as String? ?? 'unknown',
    );
  }

  final String host;
  final int port;
  final String baseUrl;
  final String modelId;
  final String status;

  Uri get uri => Uri.parse(baseUrl);
}

class MlxRuntimeStatus {
  const MlxRuntimeStatus({
    required this.handle,
    required this.modelStatus,
    required this.serverStatus,
    required this.modelId,
    required this.modelPath,
  });

  factory MlxRuntimeStatus.fromJson(Map<String, Object?> json) {
    final model = (json['model'] as Map?)?.cast<String, Object?>() ?? const {};
    final server =
        (json['server'] as Map?)?.cast<String, Object?>() ?? const {};
    return MlxRuntimeStatus(
      handle: json['handle'] as int? ?? 0,
      modelStatus: model['status'] as String? ?? 'unknown',
      serverStatus: server['status'] as String? ?? 'unknown',
      modelId: model['model_id'] as String? ?? '',
      modelPath: model['model_path'] as String? ?? '',
    );
  }

  final int handle;
  final String modelStatus;
  final String serverStatus;
  final String modelId;
  final String modelPath;
}

class MlxLifecycleException implements Exception {
  const MlxLifecycleException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'MlxLifecycleException($code): $message';
}
