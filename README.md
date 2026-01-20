# redis_ffi

A Dart FFI wrapper for [hiredis](https://github.com/redis/hiredis), the minimalistic C client for Redis.

This package provides high-performance async Redis client functionality using direct FFI bindings to the hiredis C library, with a custom Zig-based polling loop for non-blocking I/O.

## Features

- Fully async API with Future-based operations
- Automatic command pipelining for maximum throughput
- Pub/Sub support with Dart Stream API
- Automatic memory management via `NativeFinalizer`
- Prebuilt binaries for all major platforms (no native toolchain required for users)
- Cross-platform: Linux (x64, arm64), macOS (x64, arm64), Windows (x64), Android, iOS

## Getting Started

Add `redis_ffi` to your `pubspec.yaml`:

```yaml
dependencies:
  redis_ffi: ^1.0.0
```

No additional setup is required - prebuilt native libraries are bundled with the package.

## Usage

### Basic Operations

```dart
import 'package:redis_ffi/redis_ffi.dart';

void main() async {
  final client = await RedisClient.connect('localhost', 6379);

  try {
    // Test connection
    print(await client.ping()); // PONG

    // Set and get values
    await client.set('greeting', 'Hello, Redis!');
    print(await client.get('greeting')); // Hello, Redis!

    // Check existence
    print(await client.exists('greeting')); // true

    // Delete keys
    await client.del(['greeting']);
  } finally {
    await client.close();
  }
}
```

### Raw Commands

For commands not covered by the convenience methods, use `command`:

```dart
final reply = await client.command(['MGET', 'key1', 'key2', 'key3']);
print(reply?.type); // RedisReplyType.array
for (var i = 0; i < (reply?.length ?? 0); i++) {
  print(reply?[i]?.string);
}
reply?.free(); // Optional - will be freed automatically by NativeFinalizer
```

### Pipelining

Send multiple commands at once for better throughput:

```dart
final results = await client.pipeline([
  ['SET', 'key1', 'value1'],
  ['SET', 'key2', 'value2'],
  ['GET', 'key1'],
  ['GET', 'key2'],
]);

print(results[2]?.string); // value1
print(results[3]?.string); // value2

for (final reply in results) {
  reply?.free();
}
```

### Pub/Sub

```dart
import 'package:redis_ffi/redis_ffi.dart';

void main() async {
  // Subscriber connection
  final subscriber = await RedisClient.connect('localhost', 6379);
  
  // Publisher connection (can't publish on a subscribed connection)
  final publisher = await RedisClient.connect('localhost', 6379);

  try {
    // Listen to messages
    subscriber.messages.listen((message) {
      print('Channel: ${message.channel}');
      print('Message: ${message.message}');
    });

    // Subscribe to channels
    await subscriber.subscribe(['news']);
    await subscriber.psubscribe(['user:*']); // Pattern subscription

    // Publish messages
    await publisher.publish('news', 'Breaking news!');
    await publisher.publish('user:123', 'User logged in');

  } finally {
    await subscriber.close();
    await publisher.close();
  }
}
```

## Architecture

This package uses a hybrid approach for async I/O:

1. **Hiredis async API** - Commands are sent using hiredis's non-blocking async interface
2. **Zig polling loop** - A custom Zig function (`redis_async_poll`) efficiently waits for socket I/O
3. **Dart isolate** - The polling runs in a separate isolate, keeping the main isolate responsive
4. **NativeCallable.listener** - Callbacks from native code post directly to Dart's event loop

This design provides true async behavior without busy-polling, while maintaining compatibility with Dart's single-threaded async model.

## Memory Management

This package uses Dart's `NativeFinalizer` to automatically free native resources when Dart objects are garbage collected. However, for optimal performance:

- Call `await client.close()` when done with a `RedisClient`
- Optionally call `reply?.free()` on `RedisReply` objects if you want immediate cleanup

The package uses hiredis options (`REDICT_OPT_NOAUTOFREE`, `REDICT_OPT_NOAUTOFREEREPLIES`, `REDICT_OPT_NO_PUSH_AUTOFREE`) to ensure Dart has full control over memory lifetime.

## Building from Source

For package maintainers or contributors who need to rebuild the native libraries:

### Prerequisites

- [zigup](https://github.com/marler8997/zigup) - Zig version manager
- LLVM/libclang (for regenerating FFI bindings with ffigen)

### Build Commands

```bash
# Build for current platform
cd native && zig build

# Build for all platforms
dart run tool/build_all.dart

# Build for specific platform
dart run tool/build_all.dart macos-arm64

# Regenerate FFI bindings
dart run ffigen --config ffigen.yaml
```

### Target Platforms

| Platform | Architecture | Library |
|----------|-------------|---------|
| Linux | x64, arm64 | libhiredis.so |
| macOS | x64, arm64 | libhiredis.dylib |
| Windows | x64 | hiredis.dll |
| Android | arm64, arm, x64 | libhiredis.so |
| iOS | arm64 | libhiredis.a |

## License

See LICENSE file.
