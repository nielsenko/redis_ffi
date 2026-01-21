#!/usr/bin/env dart

// Build script for compiling hiredis for all target platforms.
//
// This script uses Zig for cross-compilation, which allows building
// for all platforms from any host machine.
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
/// Note: Android and iOS are excluded because Zig doesn't bundle their libc.
/// For mobile platforms, use Flutter's build system which handles NDK/SDK
/// automatically via the `native_toolchain_c` package in hook/build.dart.
const targets = <String, String>{
  'linux-x64': 'x86_64-linux-gnu',
  'linux-arm64': 'aarch64-linux-gnu',
  'macos-x64': 'x86_64-macos',
  'macos-arm64': 'aarch64-macos',
  'windows-x64': 'x86_64-windows',
};

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
    final zigTarget = targets[platform]!;
    print('\n--- Building for $platform ($zigTarget) ---');

    try {
      await _buildForTarget(platform, zigTarget);
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

Future<void> _buildForTarget(String platform, String zigTarget) async {
  final scriptDir = File(Platform.script.toFilePath()).parent.parent.path;
  final nativeDir = '$scriptDir/native';
  final outputDir = '$nativeDir/lib/$platform';

  // Ensure output directory exists
  await Directory(outputDir).create(recursive: true);

  // Run zig build
  final result = await Process.run('zig', [
    'build',
    '-Dtarget=$zigTarget',
    '-Doptimize=ReleaseFast',
    '-p',
    outputDir,
  ], workingDirectory: nativeDir);

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
