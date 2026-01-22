// ignore_for_file: depend_on_referenced_packages

import 'package:redis/redis.dart' as pure_dart;
import 'package:redis_ffi/redis_ffi.dart' as ffi;

Future<void> main() async {
  print('Pipeline Benchmark: FFI vs Pure Dart');
  print('=' * 50);

  // Connect both clients
  final ffiClient = await ffi.RedisClient.connect('localhost', 6379);
  final dartConn = pure_dart.RedisConnection();
  final dartCmd = await dartConn.connect('localhost', 6379);

  // Warm up
  for (var i = 0; i < 100; i++) {
    await ffiClient.set('warmup', 'value');
    await dartCmd.send_object(['SET', 'warmup', 'value']);
  }

  print('');
  print('Pipeline sizes: 100, 1000, 10000');
  print('');
  print('FFI Auto-Pipeline: Commands batched automatically via microtask');
  print(
    'Dart Implicit:     Multiple send_object() calls (no explicit pipeline)',
  );
  print('Dart Explicit:     Using pipe_start()/pipe_end() API');
  print('');

  for (final n in [100, 1000, 10000]) {
    print('--- Pipeline size: $n ---');

    // FFI Sequential (baseline for small n only)
    if (n == 100) {
      final sw = Stopwatch()..start();
      for (var i = 0; i < n; i++) {
        await ffiClient.set('seq_key$i', 'value$i');
      }
      sw.stop();
      print(
        'FFI Sequential:       ${(sw.elapsedMicroseconds / n).toStringAsFixed(1)} μs/op',
      );

      sw.reset();
      sw.start();
      for (var i = 0; i < n; i++) {
        await dartCmd.send_object(['SET', 'seq_key$i', 'value$i']);
      }
      sw.stop();
      print(
        'Dart Sequential:      ${(sw.elapsedMicroseconds / n).toStringAsFixed(1)} μs/op',
      );
    }

    // FFI Pipelined (auto-batched via microtask)
    var sw = Stopwatch()..start();
    final ffiFutures = <Future<String?>>[];
    for (var i = 0; i < n; i++) {
      ffiFutures.add(ffiClient.set('ffi_key$i', 'value$i'));
    }
    await ffiFutures.wait;
    sw.stop();
    print(
      'FFI Pipelined:        ${(sw.elapsedMicroseconds / n).toStringAsFixed(1)} μs/op',
    );

    // Pure Dart Implicit (no explicit pipeline)
    sw = Stopwatch()..start();
    final dartFutures = <Future>[];
    for (var i = 0; i < n; i++) {
      dartFutures.add(dartCmd.send_object(['SET', 'dart_key$i', 'value$i']));
    }
    await dartFutures.wait;
    sw.stop();
    print(
      'Dart Implicit:        ${(sw.elapsedMicroseconds / n).toStringAsFixed(1)} μs/op',
    );

    // Pure Dart Explicit Pipeline (using pipe_start/pipe_end)
    sw = Stopwatch()..start();
    dartCmd.pipe_start();
    final dartPipeFutures = <Future>[];
    for (var i = 0; i < n; i++) {
      dartPipeFutures.add(
        dartCmd.send_object(['SET', 'dart_pipe_key$i', 'value$i']),
      );
    }
    dartCmd.pipe_end();
    await dartPipeFutures.wait;
    sw.stop();
    print(
      'Dart Explicit:        ${(sw.elapsedMicroseconds / n).toStringAsFixed(1)} μs/op',
    );

    // FFI Pipelined SET+GET (auto-batched)
    sw = Stopwatch()..start();
    final ffiSgFutures = <Future>[];
    for (var i = 0; i < n; i++) {
      ffiSgFutures.add(ffiClient.set('ffisg_key$i', 'value$i'));
      ffiSgFutures.add(ffiClient.get('ffisg_key$i'));
    }
    await ffiSgFutures.wait;
    sw.stop();
    print(
      'FFI Pipelined SET+GET: ${(sw.elapsedMicroseconds / n).toStringAsFixed(1)} μs/pair',
    );

    // Pure Dart Explicit SET+GET (using pipe_start/pipe_end)
    sw = Stopwatch()..start();
    dartCmd.pipe_start();
    final dartSgFutures = <Future>[];
    for (var i = 0; i < n; i++) {
      dartSgFutures.add(
        dartCmd.send_object(['SET', 'dartsg_key$i', 'value$i']),
      );
      dartSgFutures.add(dartCmd.send_object(['GET', 'dartsg_key$i']));
    }
    dartCmd.pipe_end();
    await dartSgFutures.wait;
    sw.stop();
    print(
      'Dart Explicit SET+GET:  ${(sw.elapsedMicroseconds / n).toStringAsFixed(1)} μs/pair',
    );

    print('');
  }

  await ffiClient.close();
  await dartConn.close();

  print('Lower is better');
}
