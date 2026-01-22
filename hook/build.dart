// Dart build hook for native assets.
//
// This hook is invoked by the Dart/Flutter build system to build or locate
// the native hiredis library for the current target platform.
//
// Behavior depends on how the package is being used:
// - Published package (from pub.dev): Uses prebuilt binaries, no zig required
// - Development (git checkout): Always runs zig build for correct caching
//
// All target configuration (zig targets, iOS sysroot, Android NDK libc) is
// handled by native/build.zig.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final packageRoot = input.packageRoot;
    final targetOS = input.config.code.targetOS;
    final targetArch = input.config.code.targetArchitecture;

    // Detect iOS simulator vs device
    // iOS simulator requires dynamic linking, device requires static linking
    final isIosSimulator =
        targetOS == OS.iOS &&
        input.config.code.iOS.targetSdk == IOSSdk.iPhoneSimulator;
    final isIosDevice = targetOS == OS.iOS && !isIosSimulator;

    // Determine platform directory name
    final platformDir = _getPlatformDir(targetOS, targetArch, isIosSimulator);
    final libName = _getLibraryName(targetOS, isIosSimulator);

    // Path to output binary
    final binaryPath = packageRoot.resolve('native/lib/$platformDir/$libName');
    final binaryFile = File(binaryPath.toFilePath());

    // Check if we're in development mode (git checkout) or published package
    final isDevelopment = _isDevelopmentMode(packageRoot);

    if (isDevelopment) {
      // Development: always run zig build (handles its own caching)
      await _buildWithZig(
        packageRoot,
        targetOS,
        targetArch,
        platformDir,
        isIosSimulator,
      );
    }

    if (!binaryFile.existsSync()) {
      if (!isDevelopment) {
        // Published package but binary missing - this shouldn't happen
        throw Exception(
          'Prebuilt binary not found at: ${binaryPath.toFilePath()}\n'
          'This package requires prebuilt binaries. Please report this issue.',
        );
      }
      throw Exception(
        'Failed to build native library. '
        'Expected file at: ${binaryPath.toFilePath()}',
      );
    }

    // Register the code asset
    // iOS device requires static linking, all others (including iOS simulator) use dynamic
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: '${input.packageName}.dart',
        linkMode: isIosDevice ? StaticLinking() : DynamicLoadingBundled(),
        file: binaryPath,
      ),
    );
  });
}

String _getPlatformDir(OS os, Architecture arch, bool isIosSimulator) {
  final osName = switch (os) {
    OS.linux => 'linux',
    OS.macOS => 'macos',
    OS.android => 'android',
    OS.iOS => isIosSimulator ? 'ios-simulator' : 'ios',
    // Windows not yet supported: DLL symbol export issues
    _ => throw UnsupportedError('Unsupported OS: $os'),
  };

  final archName = switch (arch) {
    Architecture.x64 => 'x64',
    Architecture.arm64 => 'arm64',
    Architecture.arm => 'arm',
    Architecture.ia32 => 'x86',
    _ => throw UnsupportedError('Unsupported architecture: $arch'),
  };

  return '$osName-$archName';
}

String _getLibraryName(OS os, bool isIosSimulator) {
  return switch (os) {
    OS.linux || OS.android => 'libhiredis.so',
    OS.macOS => 'libhiredis.dylib',
    // iOS simulator uses dynamic library, device uses static
    OS.iOS => isIosSimulator ? 'libhiredis.dylib' : 'libhiredis.a',
    // Windows not yet supported: DLL symbol export issues
    _ => throw UnsupportedError('Unsupported OS: $os'),
  };
}

/// Detects if we're in development mode (source checkout) vs published package.
///
/// Development mode: has native/build.zig (can build from source)
/// Published mode: build.zig excluded via .pubignore (only prebuilt binaries)
bool _isDevelopmentMode(Uri packageRoot) {
  final buildZig = File(packageRoot.resolve('native/build.zig').toFilePath());
  return buildZig.existsSync();
}

Future<void> _buildWithZig(
  Uri packageRoot,
  OS targetOS,
  Architecture targetArch,
  String platformDir,
  bool isIosSimulator,
) async {
  // Ensure correct zig version
  await _ensureZigVersion(packageRoot);

  final outputDir = packageRoot.resolve('native/lib/$platformDir/');

  // Ensure output directory exists
  await Directory(outputDir.toFilePath()).create(recursive: true);

  final nativeDir = packageRoot.resolve('native/').toFilePath();

  // Build zig arguments - use platform name directly, build.zig handles
  // the target resolution including Android NDK libc configuration.
  // Note: -Doptimize is not passed here because buildNamedPlatform in
  // build.zig already hardcodes ReleaseFast for all platform builds.
  final args = [
    'build',
    '-Dplatform=$platformDir',
    '-p',
    outputDir.toFilePath(),
  ];

  // Android requires NDK path for libc configuration
  if (targetOS == OS.android) {
    final ndkPath = await _findNdkPath();
    stderr.writeln('Using NDK: $ndkPath');
    args.add('-Dndk=$ndkPath');
  }

  // Build with zig
  final result = await Process.run('zig', args, workingDirectory: nativeDir);

  if (result.exitCode != 0) {
    throw Exception(
      'zig build failed with exit code ${result.exitCode}:\n'
      'stdout: ${result.stdout}\n'
      'stderr: ${result.stderr}',
    );
  }
}

/// Reads the required Zig version from .zig-version file.
Future<String> _getRequiredZigVersion(Uri packageRoot) async {
  final versionFile = File(packageRoot.resolve('.zig-version').toFilePath());
  if (!versionFile.existsSync()) {
    throw Exception('.zig-version file not found in package');
  }
  return (await versionFile.readAsString()).trim();
}

/// Ensures the correct Zig version is available, using zigup if needed.
Future<void> _ensureZigVersion(Uri packageRoot) async {
  final requiredVersion = await _getRequiredZigVersion(packageRoot);

  // Check if zig is available and has correct version
  final zigCheck = await Process.run('zig', ['version']);
  if (zigCheck.exitCode == 0) {
    final installedVersion = (zigCheck.stdout as String).trim();
    if (installedVersion == requiredVersion) {
      return; // Correct version already installed
    }
    stderr.writeln('Found Zig $installedVersion, but need $requiredVersion');
  }

  // Try to use zigup to get the correct version
  final whichCmd = Platform.isWindows ? 'where' : 'which';
  final zigupCheck = await Process.run(whichCmd, ['zigup']);
  if (zigupCheck.exitCode != 0) {
    throw Exception(
      'Zig $requiredVersion not found and zigup not available.\n'
      'Please install Zig $requiredVersion manually, or install zigup from:\n'
      'https://github.com/marler8997/zigup',
    );
  }

  // Fetch and set the required version
  stderr.writeln('Installing Zig $requiredVersion via zigup...');
  final fetchResult = await Process.run('zigup', ['fetch', requiredVersion]);
  if (fetchResult.exitCode != 0) {
    throw Exception(
      'Failed to fetch Zig $requiredVersion: ${fetchResult.stderr}',
    );
  }

  final defaultResult = await Process.run('zigup', [requiredVersion]);
  if (defaultResult.exitCode != 0) {
    throw Exception(
      'Failed to set Zig $requiredVersion as default: ${defaultResult.stderr}',
    );
  }
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
