import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:lib_mlx/lib_mlx.dart' show MlxAvailableModel;
import 'package:lib_mlx/runtime_smoke.dart';

typedef _ReadMemoryNative = Int32 Function(Pointer<Size>);
typedef _ReadMemory = int Function(Pointer<Size>);
typedef _SetMetallibNative = Int32 Function(Pointer<Utf8>);
typedef _SetMetallib = int Function(Pointer<Utf8>);

// Real macOS dylib probe. Inference uses the public API; these upstream MLX C
// functions only observe the allocator after the public handle is unloaded.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 4) {
    stderr.writeln(
      'Usage: dart run tool/resource_smoke.dart MODEL_PATH DYLIB_PATH '
      'MACOS_METALLIB_PATH REPORT_PATH',
    );
    exitCode = 64;
    return;
  }
  if (!Platform.isMacOS) {
    throw UnsupportedError('The native allocator probe requires macOS.');
  }
  final metallib = File(arguments[2]).absolute;
  if (!metallib.existsSync()) {
    throw ArgumentError(
      'Build the macOS Metal library with Xcode: ${metallib.path}',
    );
  }
  final library = DynamicLibrary.open(arguments[1]);
  // A Dart CLI has no application resource bundle for MLX's automatic lookup.
  // Use MLX's supported library-path setting with the actual SDK-built artifact.
  final setMetallib = library.lookupFunction<_SetMetallibNative, _SetMetallib>(
    'mlx_metal_set_metallib_path',
  );
  final metallibPath = metallib.path.toNativeUtf8();
  try {
    if (setMetallib(metallibPath) != 0) {
      throw StateError('Cannot configure the SDK-built macOS Metal library');
    }
  } finally {
    calloc.free(metallibPath);
  }
  final readers = {
    for (final name in ['active', 'cache', 'peak'])
      'mlx_${name}_bytes': library
          .lookupFunction<_ReadMemoryNative, _ReadMemory>(
            'mlx_get_${name}_memory',
          ),
  };
  Map<String, int> memory() {
    final value = calloc<Size>();
    try {
      return {
        for (final entry in readers.entries)
          entry.key: () {
            if (entry.value(value) != 0) {
              throw StateError('Cannot read ${entry.key}');
            }
            return value.value;
          }(),
        'dart_process_rss_bytes': ProcessInfo.currentRss,
      };
    } finally {
      calloc.free(value);
    }
  }

  final baseline = memory();
  const maximumRetainedBytes = 1024 * 1024;
  const maximumActiveSpanBytes = 4096;
  final cycles = <Map<String, Object?>>[];
  for (var cycle = 1; cycle <= 5; cycle++) {
    Map<String, int>? firstUnload;
    final result = await runRuntimeSmoke(
      modelPath: arguments[0],
      libraryPath: arguments[1],
      contextLength: 4096,
      log: (message) {
        if (message == 'unloaded: true') firstUnload = memory();
      },
    );
    if (result['status'] != 'passed') {
      throw StateError('Public runtime smoke failed in cycle $cycle: $result');
    }
    final after = memory();
    await Future<void>.delayed(const Duration(seconds: 1));
    final idle = memory();
    // This coarse ceiling detects retained model tensors. The separate span
    // check below detects smaller growth across cycles. Peak stays historical.
    if (after['mlx_active_bytes']! >
            baseline['mlx_active_bytes']! + maximumRetainedBytes ||
        after['mlx_cache_bytes']! >
            baseline['mlx_cache_bytes']! + maximumRetainedBytes) {
      throw StateError(
        'MLX allocations did not recover after cycle $cycle: $after',
      );
    }
    final checks = result['checks']! as Map;
    if (firstUnload == null) {
      throw StateError('Missing the public smoke first-unload observation');
    }
    final record = <String, Object?>{
      'cycle': cycle,
      'status': result['status'],
      'checks': checks.keys.toList(),
      'resident_memory': checks['memory'],
      'first_unload': firstUnload,
      'after_unload': after,
      'after_idle': idle,
    };
    cycles.add(record);
    stdout.writeln(jsonEncode(record));
  }
  final idleActive = cycles.map(
    (cycle) => (cycle['after_idle']! as Map<String, int>)['mlx_active_bytes']!,
  );
  final minimumActive = idleActive.reduce((a, b) => a < b ? a : b);
  final maximumActive = idleActive.reduce((a, b) => a > b ? a : b);
  final activeSpan = maximumActive - minimumActive;
  final recoveryPassed = activeSpan <= maximumActiveSpanBytes;
  final report = File(arguments[3]);
  await report.parent.create(recursive: true);
  await report.writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'status': recoveryPassed ? 'passed' : 'failed',
      'platform': Platform.operatingSystem,
      'os': Platform.operatingSystemVersion,
      'host': 'dart-cli',
      'run_id': Platform.environment['LIB_MLX_SMOKE_RUN_ID'],
      'source_digest': Platform.environment['LIB_MLX_SOURCE_DIGEST'],
      'native_library': File(arguments[1]).absolute.path,
      'metallib': metallib.path,
      'model_revision': MlxAvailableModel.pinnedE2bRevision,
      'context_length': 4096,
      'baseline': baseline,
      'cycles': cycles,
      'short_run_recovery': {
        'maximum_retained_bytes': maximumRetainedBytes,
        'maximum_active_span_bytes': maximumActiveSpanBytes,
        'observed_active_span_bytes': activeSpan,
        'status': recoveryPassed ? 'within_threshold' : 'growth_detected',
      },
      'long_run_stability': 'not_verified',
      'note':
          'RSS and physical footprint have different accounting domains. '
          'Neither is the MLX allocator peak; do not add overlapping metrics. '
          'Five cycles and the stated tolerances do not prove a long-run plateau.',
    }),
  );
  if (!recoveryPassed) {
    stderr.writeln('Post-unload MLX active memory grew by $activeSpan bytes.');
    exitCode = 1;
  }
}
