# Flutter Example

A Flutter app to test redis_ffi on mobile and desktop platforms.

## Setup

Before building, generate the platform projects for your target:

```bash
# For iOS
flutter create . --platforms=ios

# For Android
flutter create . --platforms=android

# For macOS
flutter create . --platforms=macos

# Or multiple platforms at once
flutter create . --platforms=ios,android,macos
```

## Running

```bash
# iOS Simulator
flutter run -d iphone

# Android
flutter run -d android

# macOS
flutter run -d macos
```

## Note

The default host is `10.0.2.2` which is the host machine from Android emulator.
Change to `localhost` or your Redis server's IP as needed.
