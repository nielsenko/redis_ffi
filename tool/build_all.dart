#!/usr/bin/env dart

// Build script for compiling hiredis for all target platforms.
//
// This script uses Zig for cross-compilation, which allows building
// for all platforms from any host machine. The resulting binaries are
// committed to the repo and bundled with the published package.
//
// The zig target mapping and iOS sysroot logic here should be kept in sync
// with hook/build.dart which handles runtime builds.
//
// Prerequisites:
// - zigup installed (https://github.com/marler8997/zigup)
//
// Usage:
//   dart run tool/build_all.dart           # Build all platforms
//   dart run tool/build_all.dart --host    # Build only for host platform
//   dart run tool/build_all.dart linux-x64 # Build specific platform
import 'dart:io';

/// Reads the required Zig version from .zig-version file.
String get zigVersion {
  final scriptDir = File(Platform.script.toFilePath()).parent.parent.path;
  final versionFile = File('$scriptDir/.zig-version');
  if (!versionFile.existsSync()) {
    throw Exception('.zig-version file not found');
  }
  return versionFile.readAsStringSync().trim();
}

/// Target configurations: platform name -> zig target triple.
///
/// Linux uses musl libc for static linking (no glibc version dependency).
/// Android uses NDK (Bionic libc) - cannot use musl as symbols differ at runtime.
/// iOS requires Xcode SDK (only builds on macOS).
const zigTargets = <String, String>{
  // Desktop platforms
  'linux-x64': 'x86_64-linux-musl',
  'linux-arm64': 'aarch64-linux-musl',
  'macos-x64': 'x86_64-macos',
  'macos-arm64': 'aarch64-macos',
  'windows-x64': 'x86_64-windows',
  // iOS (requires Xcode SDK on macOS)
  'ios-arm64': 'aarch64-ios',
  'ios-simulator-arm64': 'aarch64-ios-simulator',
  'ios-simulator-x64': 'x86_64-ios-simulator',
};

/// Android targets use Zig with NDK libc configuration.
/// Maps platform name to Zig target triple.
const androidTargets = <String, String>{
  'android-arm64': 'aarch64-linux-android',
  'android-arm': 'arm-linux-androideabi',
  'android-x64': 'x86_64-linux-android',
};

/// All supported targets.
Map<String, String> get targets => {...zigTargets, ...androidTargets};

Future<void> main(List<String> args) async {
  final stopwatch = Stopwatch()..start();

  // Determine which platforms to build
  final Set<String> platformsToBuild;
  if (args.contains('--host')) {
    platformsToBuild = {_getHostPlatform()};
  } else if (args.isNotEmpty && !args.first.startsWith('-')) {
    platformsToBuild = args.where((a) => targets.containsKey(a)).toSet();
    if (platformsToBuild.isEmpty) {
      stderr.writeln('Unknown platform(s): ${args.join(', ')}');
      stderr.writeln('Available platforms: ${targets.keys.join(', ')}');
      exit(1);
    }
  } else {
    platformsToBuild = targets.keys.toSet();
  }

  print('=== Redis FFI Native Build Script ===\n');

  // Ensure correct Zig version
  await _ensureZigVersion();

  // Build for each platform
  var successCount = 0;
  var failCount = 0;

  for (final platform in platformsToBuild) {
    final target = targets[platform]!;
    final isAndroid = androidTargets.containsKey(platform);
    print('\n--- Building for $platform ($target) ---');

    try {
      if (isAndroid) {
        await _buildForAndroid(platform, target);
      } else {
        await _buildForTarget(platform, target);
      }
      successCount++;
      print('  OK: $platform');
    } catch (e) {
      failCount++;
      print('  FAILED: $platform - $e');
    }
  }

  stopwatch.stop();
  print('\n=== Build Summary ===');
  print('  Succeeded: $successCount');
  print('  Failed: $failCount');
  print('  Time: ${stopwatch.elapsed.inSeconds}s');

  if (failCount > 0) {
    exit(1);
  }
}

String _getHostPlatform() {
  final os = Platform.operatingSystem;
  final arch = _getHostArch();
  return '$os-$arch';
}

String _getHostArch() {
  if (Platform.isWindows) {
    // On Windows, use PROCESSOR_ARCHITECTURE environment variable
    final arch = Platform.environment['PROCESSOR_ARCHITECTURE'] ?? 'AMD64';
    return switch (arch.toUpperCase()) {
      'AMD64' || 'X86_64' => 'x64',
      'ARM64' => 'arm64',
      'X86' => 'x86',
      _ => 'x64',
    };
  }

  // Use uname on Unix-like systems
  final result = Process.runSync('uname', ['-m']);
  final machine = result.stdout.toString().trim();

  return switch (machine) {
    'arm64' || 'aarch64' => 'arm64',
    'x86_64' || 'amd64' => 'x64',
    'armv7l' || 'arm' => 'arm',
    'i386' || 'i686' => 'x86',
    _ => 'x64', // Default to x64
  };
}

Future<void> _ensureZigVersion() async {
  print('Checking Zig version...');

  // Check if zig is available and has correct version
  final requiredVersion = zigVersion;
  final zigCheck = await Process.run('zig', ['version']);
  if (zigCheck.exitCode == 0) {
    final installedVersion = zigCheck.stdout.toString().trim();
    if (installedVersion == requiredVersion) {
      print('  Using Zig $installedVersion');
      return;
    }
    print('  Found Zig $installedVersion, but need $requiredVersion');
  }

  // Use zigup to get the correct version
  final whichCmd = Platform.isWindows ? 'where' : 'which';
  final zigupCheck = await Process.run(whichCmd, ['zigup']);
  if (zigupCheck.exitCode != 0) {
    throw Exception(
      'Zig $zigVersion not found and zigup not available. '
      'Please install zigup from https://github.com/marler8997/zigup',
    );
  }

  // Fetch and set the required version
  print('  Ensuring Zig $zigVersion is installed via zigup...');
  final fetchResult = await Process.run('zigup', ['fetch', zigVersion]);
  if (fetchResult.exitCode != 0) {
    throw Exception('Failed to fetch Zig $zigVersion: ${fetchResult.stderr}');
  }

  final defaultResult = await Process.run('zigup', [zigVersion]);
  if (defaultResult.exitCode != 0) {
    throw Exception(
      'Failed to set Zig $zigVersion as default: ${defaultResult.stderr}',
    );
  }

  // Verify
  final versionResult = await Process.run('zig', ['version']);
  final installedVersion = versionResult.stdout.toString().trim();
  print('  Using Zig $installedVersion');
}

Future<String> _getIosSysroot({required bool simulator}) async {
  final sdk = simulator ? 'iphonesimulator' : 'iphoneos';
  final result = await Process.run('xcrun', ['--sdk', sdk, '--show-sdk-path']);
  if (result.exitCode != 0) {
    throw Exception(
      'Failed to get iOS SDK path. Is Xcode installed?\n'
      'stderr: ${result.stderr}',
    );
  }
  return result.stdout.toString().trim();
}

Future<void> _buildForTarget(String platform, String zigTarget) async {
  final scriptDir = File(Platform.script.toFilePath()).parent.parent.path;
  final nativeDir = '$scriptDir/native';
  final outputDir = '$nativeDir/lib/$platform';

  // Ensure output directory exists
  await Directory(outputDir).create(recursive: true);

  // Build zig arguments
  final args = [
    'build',
    '-Dtarget=$zigTarget',
    '-Doptimize=ReleaseFast',
    '-p',
    outputDir,
  ];

  // iOS requires Xcode SDK sysroot (only available on macOS)
  if (platform.startsWith('ios-')) {
    if (!Platform.isMacOS) {
      throw Exception('iOS builds require macOS with Xcode installed');
    }
    final isSimulator = platform.contains('simulator');
    final sysroot = await _getIosSysroot(simulator: isSimulator);
    args.add('--sysroot');
    args.add(sysroot);
  }

  // Run zig build
  final result = await Process.run('zig', args, workingDirectory: nativeDir);

  if (result.exitCode != 0) {
    throw Exception(
      'zig build failed:\n'
      'stdout: ${result.stdout}\n'
      'stderr: ${result.stderr}',
    );
  }

  // Verify output exists
  final libDir = Directory('$outputDir/lib');
  if (!await libDir.exists()) {
    throw Exception('Build succeeded but no lib directory created');
  }

  final files = await libDir.list().toList();
  if (files.isEmpty) {
    throw Exception('Build succeeded but no library files created');
  }

  print('  Built: ${files.map((f) => f.path.split('/').last).join(', ')}');
}

/// Finds the Android NDK path.
Future<String> _findNdkPath() async {
  // Check ANDROID_NDK_HOME first
  final ndkHome = Platform.environment['ANDROID_NDK_HOME'];
  if (ndkHome != null && await Directory(ndkHome).exists()) {
    return ndkHome;
  }

  // Check ANDROID_HOME/ndk
  final androidHome =
      Platform.environment['ANDROID_HOME'] ??
      Platform.environment['ANDROID_SDK_ROOT'];
  if (androidHome != null) {
    final ndkDir = Directory('$androidHome/ndk');
    if (await ndkDir.exists()) {
      // Find the latest NDK version
      final versions = await ndkDir.list().toList();
      if (versions.isNotEmpty) {
        // Sort by version and pick the latest
        final sorted = versions.map((e) => e.path.split('/').last).toList()
          ..sort();
        return '${ndkDir.path}/${sorted.last}';
      }
    }
  }

  // Check common locations
  final commonPaths = [
    if (Platform.isMacOS)
      '${Platform.environment['HOME']}/Library/Android/sdk/ndk',
    if (Platform.isLinux) '${Platform.environment['HOME']}/Android/Sdk/ndk',
    if (Platform.isWindows)
      '${Platform.environment['LOCALAPPDATA']}\\Android\\Sdk\\ndk',
  ];

  for (final path in commonPaths) {
    final ndkDir = Directory(path);
    if (await ndkDir.exists()) {
      final versions = await ndkDir.list().toList();
      if (versions.isNotEmpty) {
        final sorted = versions.map((e) => e.path.split('/').last).toList()
          ..sort();
        return '${ndkDir.path}/${sorted.last}';
      }
    }
  }

  throw Exception(
    'Android NDK not found. Please install it via Android Studio or set ANDROID_NDK_HOME.',
  );
}

/// Builds for Android using Zig with NDK libc configuration.
///
/// Zig doesn't bundle Android's Bionic libc, so we create a libc config file
/// that points to the NDK sysroot. This allows Zig to compile for Android
/// while using Bionic's headers and libraries.
Future<void> _buildForAndroid(String platform, String zigTarget) async {
  final scriptDir = File(Platform.script.toFilePath()).parent.parent.path;
  final nativeDir = '$scriptDir/native';
  final outputDir = '$nativeDir/lib/$platform';

  // Ensure output directory exists
  await Directory(outputDir).create(recursive: true);

  // Find NDK and create libc config
  final ndkPath = await _findNdkPath();
  print('  Using NDK: $ndkPath');

  final libcConfigPath = await _createAndroidLibcConfig(
    nativeDir,
    ndkPath,
    zigTarget,
  );

  // Build with zig using the libc config
  final args = [
    'build',
    '-Dtarget=$zigTarget',
    '-Doptimize=ReleaseFast',
    '--libc',
    libcConfigPath,
    '-p',
    outputDir,
  ];

  final result = await Process.run('zig', args, workingDirectory: nativeDir);

  if (result.exitCode != 0) {
    throw Exception(
      'zig build failed:\n'
      'stdout: ${result.stdout}\n'
      'stderr: ${result.stderr}',
    );
  }

  // Verify output exists
  final libDir = Directory('$outputDir/lib');
  if (!await libDir.exists()) {
    throw Exception('Build succeeded but no lib directory created');
  }

  final files = await libDir.list().toList();
  if (files.isEmpty) {
    throw Exception('Build succeeded but no library files created');
  }

  print('  Built: ${files.map((f) => f.path.split('/').last).join(', ')}');
}

/// Creates a libc configuration file for Android NDK.
///
/// This tells Zig where to find Bionic headers and libraries.
Future<String> _createAndroidLibcConfig(
  String nativeDir,
  String ndkPath,
  String zigTarget,
) async {
  // Determine host platform for NDK toolchain
  final hostTag = switch (Platform.operatingSystem) {
    'macos' => 'darwin-x86_64',
    'linux' => 'linux-x86_64',
    'windows' => 'windows-x86_64',
    _ => throw Exception('Unsupported host platform for NDK'),
  };

  final sysroot = '$ndkPath/toolchains/llvm/prebuilt/$hostTag/sysroot';

  // Map zig target to NDK target triple
  final ndkTriple = switch (zigTarget) {
    'x86_64-linux-android' => 'x86_64-linux-android',
    'aarch64-linux-android' => 'aarch64-linux-android',
    'arm-linux-androideabi' => 'arm-linux-androideabi',
    _ => throw Exception('Unknown Android target: $zigTarget'),
  };

  // API level 21 is minimum for modern NDKs
  const apiLevel = '21';

  final configContent =
      '''
include_dir=$sysroot/usr/include
sys_include_dir=$sysroot/usr/include/$ndkTriple
crt_dir=$sysroot/usr/lib/$ndkTriple/$apiLevel
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
''';

  final configFile = File('$nativeDir/android-libc-$zigTarget.txt');
  await configFile.writeAsString(configContent);
  return configFile.path;
}
