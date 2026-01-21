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

    // Determine platform directory name
    final platformDir = _getPlatformDir(targetOS, targetArch);
    final libName = _getLibraryName(targetOS);

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
      await _buildWithZig(packageRoot, targetOS, targetArch, platformDir);

      if (!prebuiltFile.existsSync()) {
        throw Exception(
          'Failed to build native library. '
          'Expected file at: ${prebuiltPath.toFilePath()}',
        );
      }
    }

    // Register the code asset
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: '${input.packageName}.dart',
        linkMode: targetOS == OS.iOS
            ? StaticLinking()
            : DynamicLoadingBundled(),
        file: prebuiltPath,
      ),
    );
  });
}

String _getPlatformDir(OS os, Architecture arch) {
  final osName = switch (os) {
    OS.linux => 'linux',
    OS.macOS => 'macos',
    OS.windows => 'windows',
    OS.android => 'android',
    OS.iOS => 'ios',
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

String _getLibraryName(OS os) {
  return switch (os) {
    OS.linux || OS.android => 'libhiredis.so',
    OS.macOS => 'libhiredis.dylib',
    OS.windows => 'hiredis.dll',
    OS.iOS => 'libhiredis.a',
    _ => throw UnsupportedError('Unsupported OS: $os'),
  };
}

Future<void> _buildWithZig(
  Uri packageRoot,
  OS targetOS,
  Architecture targetArch,
  String platformDir,
) async {
  // Ensure correct zig version
  await _ensureZigVersion(packageRoot);

  final zigTarget = _getZigTarget(targetOS, targetArch);
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
    final sysroot = await _getIosSysroot(simulator: false);
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

String _getZigTarget(OS os, Architecture arch) {
  final archStr = switch (arch) {
    Architecture.x64 => 'x86_64',
    Architecture.arm64 => 'aarch64',
    Architecture.arm => 'arm',
    Architecture.ia32 => 'x86',
    _ => throw UnsupportedError('Unsupported architecture: $arch'),
  };

  // Use musl for Linux/Android (static libc, no glibc version dependency)
  final osStr = switch (os) {
    OS.linux => 'linux-musl',
    OS.macOS => 'macos',
    OS.windows => 'windows',
    OS.android => arch == Architecture.arm ? 'linux-musleabihf' : 'linux-musl',
    OS.iOS => 'ios',
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
