// Dart build hook for native assets.
//
// This hook is invoked by the Dart/Flutter build system to build or locate
// the native hiredis library for the current target platform.
//
// The zig target mapping and iOS sysroot logic here should be kept in sync
// with tool/build_all.dart which pre-builds for all platforms.

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

    // Path to prebuilt binary (zig outputs to prefix/lib/)
    final prebuiltPath = packageRoot.resolve(
      'native/lib/$platformDir/lib/$libName',
    );

    final prebuiltFile = File(prebuiltPath.toFilePath());

    if (!prebuiltFile.existsSync()) {
      // Development mode: build with zig if binary doesn't exist
      stderr.writeln(
        'Prebuilt binary not found at ${prebuiltPath.toFilePath()}',
      );
      stderr.writeln('Building with zig for $platformDir...');
      await _buildWithZig(
        packageRoot,
        targetOS,
        targetArch,
        platformDir,
        isIosSimulator,
      );

      if (!prebuiltFile.existsSync()) {
        throw Exception(
          'Failed to build native library. '
          'Expected file at: ${prebuiltPath.toFilePath()}',
        );
      }
    }

    // Register the code asset
    // iOS device requires static linking, all others (including iOS simulator) use dynamic
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: '${input.packageName}.dart',
        linkMode: isIosDevice ? StaticLinking() : DynamicLoadingBundled(),
        file: prebuiltPath,
      ),
    );
  });
}

String _getPlatformDir(OS os, Architecture arch, bool isIosSimulator) {
  final osName = switch (os) {
    OS.linux => 'linux',
    OS.macOS => 'macos',
    OS.windows => 'windows',
    OS.android => 'android',
    OS.iOS => isIosSimulator ? 'ios-simulator' : 'ios',
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
    OS.windows => 'hiredis.dll',
    // iOS simulator uses dynamic library, device uses static
    OS.iOS => isIosSimulator ? 'libhiredis.dylib' : 'libhiredis.a',
    _ => throw UnsupportedError('Unsupported OS: $os'),
  };
}

Future<void> _buildWithZig(
  Uri packageRoot,
  OS targetOS,
  Architecture targetArch,
  String platformDir,
  bool isIosSimulator,
) async {
  // Android uses NDK, not Zig (musl symbols differ from Bionic at runtime)
  if (targetOS == OS.android) {
    await _buildWithNdk(packageRoot, targetArch, platformDir);
    return;
  }

  // Ensure correct zig version
  await _ensureZigVersion(packageRoot);

  final zigTarget = _getZigTarget(targetOS, targetArch, isIosSimulator);
  final outputDir = packageRoot.resolve('native/lib/$platformDir/');

  // Ensure output directory exists
  await Directory(outputDir.toFilePath()).create(recursive: true);

  final nativeDir = packageRoot.resolve('native/').toFilePath();

  // Build zig arguments
  final args = [
    'build',
    '-Dtarget=$zigTarget',
    '-Doptimize=ReleaseFast',
    '-p',
    outputDir.toFilePath(),
  ];

  // iOS requires Xcode SDK sysroot
  if (targetOS == OS.iOS) {
    final sysroot = await _getIosSysroot(simulator: isIosSimulator);
    args.addAll(['--sysroot', sysroot]);
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

String _getZigTarget(OS os, Architecture arch, bool isIosSimulator) {
  final archStr = switch (arch) {
    Architecture.x64 => 'x86_64',
    Architecture.arm64 => 'aarch64',
    Architecture.arm => 'arm',
    Architecture.ia32 => 'x86',
    _ => throw UnsupportedError('Unsupported architecture: $arch'),
  };

  // Use musl for Linux (static libc, no glibc version dependency)
  // Android uses NDK, not Zig - see _buildWithNdk
  final osStr = switch (os) {
    OS.linux => 'linux-musl',
    OS.macOS => 'macos',
    OS.windows => 'windows',
    OS.iOS => isIosSimulator ? 'ios-simulator' : 'ios',
    _ => throw UnsupportedError('Unsupported OS: $os'),
  };

  return '$archStr-$osStr';
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

/// Builds for Android using Zig with NDK libc configuration.
///
/// Zig doesn't bundle Android's Bionic libc, so we create a libc config file
/// that points to the NDK sysroot. This allows Zig to compile for Android
/// while using Bionic's headers and libraries.
Future<void> _buildWithNdk(
  Uri packageRoot,
  Architecture targetArch,
  String platformDir,
) async {
  final nativeDir = packageRoot.resolve('native/').toFilePath();
  final outputDir = packageRoot.resolve('native/lib/$platformDir/');

  // Ensure output directory exists
  await Directory(outputDir.toFilePath()).create(recursive: true);

  // Find NDK and create libc config
  final ndkPath = await _findNdkPath();
  stderr.writeln('Using NDK: $ndkPath');

  // Zig target triple
  final zigTarget = switch (targetArch) {
    Architecture.arm64 => 'aarch64-linux-android',
    Architecture.arm => 'arm-linux-androideabi',
    Architecture.x64 => 'x86_64-linux-android',
    _ => throw UnsupportedError(
      'Unsupported Android architecture: $targetArch',
    ),
  };

  final libcConfigPath = await _createAndroidLibcConfig(
    nativeDir,
    ndkPath,
    zigTarget,
  );

  // Ensure correct zig version
  await _ensureZigVersion(packageRoot);

  // Build with zig using the libc config
  final args = [
    'build',
    '-Dtarget=$zigTarget',
    '-Doptimize=ReleaseFast',
    '--libc',
    libcConfigPath,
    '-p',
    outputDir.toFilePath(),
  ];

  final result = await Process.run('zig', args, workingDirectory: nativeDir);

  if (result.exitCode != 0) {
    throw Exception(
      'zig build failed with exit code ${result.exitCode}:\n'
      'stdout: ${result.stdout}\n'
      'stderr: ${result.stderr}',
    );
  }
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
