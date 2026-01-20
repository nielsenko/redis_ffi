# redis_ffi

A Dart FFI wrapper for [hiredis](https://github.com/redis/hiredis), the minimalistic C client for Redis.

This package provides high-performance Redis client functionality using direct FFI bindings to the hiredis C library, with proper memory management using Dart's `NativeFinalizer`.

## Features

- Synchronous Redis client with common operations (GET, SET, DEL, EXISTS, PING)
- Raw command execution with full reply parsing
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

void main() {
  final client = RedisClient.connect('localhost', 6379);

  try {
    // Test connection
    print(client.ping()); // PONG

    // Set and get values
    client.set('greeting', 'Hello, Redis!');
    print(client.get('greeting')); // Hello, Redis!

    // Check existence
    print(client.exists('greeting')); // true

    // Delete keys
    client.del(['greeting']);
  } finally {
    client.close();
  }
}
```

### Raw Commands

For commands not covered by the convenience methods, use `commandArgv`:

```dart
final reply = client.commandArgv(['MGET', 'key1', 'key2', 'key3']);
print(reply.type); // RedisReplyType.array
for (var i = 0; i < reply.length; i++) {
  print(reply[i]?.string);
}
reply.free(); // Optional - will be freed automatically by NativeFinalizer
```

### Pub/Sub

```dart
import 'package:redis_ffi/redis_ffi.dart';

void main() async {
  final subscriber = RedisPubSub.connect('localhost', 6379);
  final publisher = RedisClient.connect('localhost', 6379);

  try {
    // Listen to messages
    subscriber.messages.listen((message) {
      print('Channel: ${message.channel}');
      print('Message: ${message.message}');
    });

    // Subscribe to channels
    subscriber.subscribe('news');
    subscriber.psubscribe('user:*'); // Pattern subscription

    // Poll for messages (call periodically)
    subscriber.poll();

    // Publish from another client
    publisher.commandArgv(['PUBLISH', 'news', 'Breaking news!']);

    // Poll to receive
    await Future.delayed(Duration(milliseconds: 100));
    subscriber.poll();

  } finally {
    subscriber.close();
    publisher.close();
  }
}
```

## Memory Management

This package uses Dart's `NativeFinalizer` to automatically free native resources when Dart objects are garbage collected. However, for optimal performance:

- Call `client.close()` when done with a `RedisClient`
- Call `subscriber.close()` when done with a `RedisPubSub`
- Optionally call `reply.free()` on `RedisReply` objects if you want immediate cleanup

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
dart run ffigen
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
