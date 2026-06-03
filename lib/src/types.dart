class MlxModelConfig {
  const MlxModelConfig({
    required this.modelPath,
    this.modelId = 'mlx-community/gemma-4-e2b-it-4bit',
    this.revision,
    this.thinkingEnabled = true,
    this.lazyEncoders = true,
  });

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
    this.modelId = 'mlx-community/gemma-4-e2b-it-4bit',
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
          json['model_id'] as String? ?? 'mlx-community/gemma-4-e2b-it-4bit',
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
