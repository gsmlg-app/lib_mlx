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
  static const pinnedE2bRevision = '238767527555cb75a05732a84dff5d6ba0dd6809';

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
    this.contextLength = 8192,
    this.prefillStepSize = 256,
    this.memoryLimitBytes,
    this.cacheLimitBytes = 64 * 1024 * 1024,
  });

  MlxModelConfig.forAvailableModel({
    required this.modelPath,
    required MlxAvailableModel model,
    this.revision,
    this.thinkingEnabled = true,
    this.lazyEncoders = true,
    this.contextLength = 8192,
    this.prefillStepSize = 256,
    this.memoryLimitBytes,
    this.cacheLimitBytes = 64 * 1024 * 1024,
  }) : modelId = model.huggingFaceModelId;

  final String modelPath;
  final String modelId;
  final String? revision;
  final bool thinkingEnabled;
  final bool lazyEncoders;

  /// Input template tokens plus reserved output must fit this limit.
  /// A configured value is an admission limit, not a device validation claim.
  final int contextLength;
  final int prefillStepSize;
  final int? memoryLimitBytes;
  final int cacheLimitBytes;

  Map<String, Object?> toJson() => <String, Object?>{
    'model_path': modelPath,
    'model_id': modelId,
    if (revision != null) 'revision': revision,
    'thinking_enabled': thinkingEnabled,
    'lazy_encoders': lazyEncoders,
    'context_length': contextLength,
    'prefill_step_size': prefillStepSize,
    if (memoryLimitBytes != null) 'memory_limit_bytes': memoryLimitBytes,
    'cache_limit_bytes': cacheLimitBytes,
  };
}

class MlxServerConfig {
  const MlxServerConfig({
    this.host = '127.0.0.1',
    this.port = 0,
    this.modelId,
    this.queueLimit = 1,
    this.maxHeaderBytes = 32 * 1024,
    this.maxBodyBytes = 64 * 1024 * 1024,
    this.headerTimeoutSeconds = 10,
    this.requestTimeoutSeconds = 120,
    this.writeTimeoutSeconds = 30,
    this.maxConnections = 64,
  });

  final String host;
  final int port;

  /// Optional service alias. Defaults to the resident model identity.
  final String? modelId;

  /// Waiting requests, excluding the single active generation.
  final int queueLimit;
  final int maxHeaderBytes;
  final int maxBodyBytes;
  final int headerTimeoutSeconds;
  final int requestTimeoutSeconds;
  final int writeTimeoutSeconds;
  final int maxConnections;

  Map<String, Object?> toJson() => <String, Object?>{
    'host': host,
    'port': port,
    if (modelId != null) 'model_id': modelId,
    'queue_limit': queueLimit,
    'max_header_bytes': maxHeaderBytes,
    'max_body_bytes': maxBodyBytes,
    'header_timeout_seconds': headerTimeoutSeconds,
    'request_timeout_seconds': requestTimeoutSeconds,
    'write_timeout_seconds': writeTimeoutSeconds,
    'max_connections': maxConnections,
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
    this.metrics = const {},
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
      metrics: (model['metrics'] as Map?)?.cast<String, Object?>() ?? const {},
    );
  }

  final int handle;
  final String modelStatus;
  final String serverStatus;
  final String modelId;
  final String modelPath;
  final Map<String, Object?> metrics;
}

class MlxLifecycleException implements Exception {
  const MlxLifecycleException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'MlxLifecycleException($code): $message';
}
