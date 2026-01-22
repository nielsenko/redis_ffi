const std = @import("std");

/// All target platforms we support.
const Platform = struct {
    name: []const u8,
    target: std.Target.Query,
    /// For iOS, we need to pass --sysroot to xcrun
    ios_sdk: ?[]const u8 = null,
};

const platforms = [_]Platform{
    // Desktop
    .{ .name = "linux-x64", .target = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu } },
    .{ .name = "linux-arm64", .target = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu } },
    .{ .name = "macos-x64", .target = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
    .{ .name = "macos-arm64", .target = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
    // Windows disabled: DLL symbol export issues (hiredis lacks __declspec(dllexport))
    // TODO: Re-enable when Dart native assets supports static linking on Windows
    // .{ .name = "windows-x64", .target = .{ .cpu_arch = .x86_64, .os_tag = .windows } },
    // Android (uses NDK libc)
    .{ .name = "android-x64", .target = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .android } },
    .{ .name = "android-arm64", .target = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .android } },
    .{ .name = "android-arm", .target = .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .androideabi } },
    // iOS
    .{ .name = "ios-arm64", .target = .{ .cpu_arch = .aarch64, .os_tag = .ios }, .ios_sdk = "iphoneos" },
    .{ .name = "ios-simulator-arm64", .target = .{ .cpu_arch = .aarch64, .os_tag = .ios, .abi = .simulator }, .ios_sdk = "iphonesimulator" },
    .{ .name = "ios-simulator-x64", .target = .{ .cpu_arch = .x86_64, .os_tag = .ios, .abi = .simulator }, .ios_sdk = "iphonesimulator" },
};

pub fn build(b: *std.Build) void {
    // Check if building all platforms
    const build_all = b.option(bool, "all", "Build for all platforms") orelse false;

    // NDK path option (required for Android builds)
    const ndk_path = b.option([]const u8, "ndk", "Path to Android NDK (required for Android builds)");

    // Single platform option (e.g., -Dplatform=android-arm64)
    const platform_name = b.option([]const u8, "platform", "Build for a specific platform by name");

    if (build_all) {
        buildAllPlatforms(b, ndk_path);
    } else if (platform_name) |name| {
        buildNamedPlatform(b, name, ndk_path);
    } else {
        // Single target build (default behavior, uses -Dtarget)
        buildSingleTarget(b, ndk_path);
    }
}

fn buildAllPlatforms(b: *std.Build, ndk_path: ?[]const u8) void {
    for (platforms) |platform| {
        const target = b.resolveTargetQuery(platform.target);
        // Install to <prefix>/<platform>/ - use with `zig build -Dall -p lib`
        const output_dir = platform.name;

        // Skip Android if no NDK path provided
        const is_android = platform.target.abi == .android or platform.target.abi == .androideabi;
        if (is_android and ndk_path == null) {
            std.log.warn("Skipping {s}: no NDK path provided (use -Dndk=<path>)", .{platform.name});
            continue;
        }

        // Get iOS sysroot if needed
        var sysroot: ?[]const u8 = null;
        if (platform.ios_sdk) |sdk| {
            sysroot = getIosSysroot(b.allocator, sdk);
            if (sysroot == null) {
                std.log.warn("Skipping {s}: could not find iOS SDK", .{platform.name});
                continue;
            }
        }

        const shared_lib = buildLibrary(b, target, .dynamic, sysroot, ndk_path);
        const static_lib = buildLibrary(b, target, .static, sysroot, ndk_path);

        // Install to platform-specific directory
        const shared_install = b.addInstallArtifact(shared_lib, .{
            .dest_dir = .{ .override = .{ .custom = output_dir } },
        });
        const static_install = b.addInstallArtifact(static_lib, .{
            .dest_dir = .{ .override = .{ .custom = output_dir } },
        });

        b.getInstallStep().dependOn(&shared_install.step);
        b.getInstallStep().dependOn(&static_install.step);
    }
}

fn buildNamedPlatform(b: *std.Build, name: []const u8, ndk_path: ?[]const u8) void {
    // Find the platform by name
    const platform = for (platforms) |p| {
        if (std.mem.eql(u8, p.name, name)) break p;
    } else {
        std.debug.print("Unknown platform: {s}\n", .{name});
        std.debug.print("Available platforms:\n", .{});
        for (platforms) |p| {
            std.debug.print("  {s}\n", .{p.name});
        }
        return;
    };

    const target = b.resolveTargetQuery(platform.target);
    const is_android = platform.target.abi == .android or platform.target.abi == .androideabi;

    if (is_android and ndk_path == null) {
        std.debug.print("Error: Android builds require -Dndk=<path>\n", .{});
        return;
    }

    // Get iOS sysroot if needed
    var sysroot: ?[]const u8 = null;
    if (platform.ios_sdk) |sdk| {
        sysroot = getIosSysroot(b.allocator, sdk);
        if (sysroot == null) {
            std.debug.print("Error: could not find iOS SDK '{s}'\n", .{sdk});
            return;
        }
    }

    const shared_lib = buildLibrary(b, target, .dynamic, sysroot, ndk_path);
    const static_lib = buildLibrary(b, target, .static, sysroot, ndk_path);

    // Use dest_dir override to put files directly in prefix (not prefix/lib/)
    const shared_install = b.addInstallArtifact(shared_lib, .{
        .dest_dir = .{ .override = .{ .custom = "." } },
    });
    const static_install = b.addInstallArtifact(static_lib, .{
        .dest_dir = .{ .override = .{ .custom = "." } },
    });

    b.getInstallStep().dependOn(&shared_install.step);
    b.getInstallStep().dependOn(&static_install.step);
}

fn buildSingleTarget(b: *std.Build, ndk_path: ?[]const u8) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Check for sysroot (needed for iOS)
    const sysroot = b.sysroot;

    const shared_lib = buildLibraryWithOptimize(b, target, optimize, .dynamic, sysroot, ndk_path);
    const static_lib = buildLibraryWithOptimize(b, target, optimize, .static, sysroot, ndk_path);

    // Install headers for ffigen
    const hiredis_dep = b.dependency("hiredis", .{});
    const hiredis_path = hiredis_dep.path(".");
    shared_lib.installHeadersDirectory(
        hiredis_path,
        "",
        .{ .include_extensions = &.{
            "alloc.h",
            "async.h",
            "hiredis.h",
            "net.h",
            "read.h",
            "sds.h",
            "sockcompat.h",
        } },
    );

    b.installArtifact(shared_lib);
    b.installArtifact(static_lib);
}

fn buildLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    linkage: std.builtin.LinkMode,
    sysroot: ?[]const u8,
    ndk_path: ?[]const u8,
) *std.Build.Step.Compile {
    return buildLibraryWithOptimize(b, target, .ReleaseFast, linkage, sysroot, ndk_path);
}

fn buildLibraryWithOptimize(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    linkage: std.builtin.LinkMode,
    sysroot: ?[]const u8,
    ndk_path: ?[]const u8,
) *std.Build.Step.Compile {
    const hiredis_dep = b.dependency("hiredis", .{});
    const hiredis_path = hiredis_dep.path(".");

    const hiredis_source_files = &[_][]const u8{
        "alloc.c",
        "async.c",
        "hiredis.c",
        "net.c",
        "read.c",
        "sds.c",
        "sockcompat.c",
    };

    const cflags = &[_][]const u8{"-std=c99"};

    const is_ios = target.result.os.tag == .ios;
    const is_apple = target.result.os.tag == .macos or is_ios;
    const is_android = target.result.abi == .android or target.result.abi == .androideabi;

    // Create module
    const module = b.createModule(.{
        .root_source_file = b.path("src/async_loop.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Build library
    const lib = b.addLibrary(.{
        .name = "hiredis",
        .linkage = linkage,
        .root_module = module,
    });

    // Add hiredis C sources
    lib.addCSourceFiles(.{
        .root = hiredis_path,
        .files = hiredis_source_files,
        .flags = cflags,
    });

    // Add Dart API DL sources
    lib.addCSourceFiles(.{
        .files = &.{"src/dart_api/dart_api_dl.c"},
        .flags = &.{},
    });

    // Include path for hiredis headers
    lib.addIncludePath(hiredis_path);

    // Include path for Dart API headers
    lib.addIncludePath(b.path("src/dart_api"));

    // For Android, we need to provide NDK libc paths
    if (is_android) {
        if (ndk_path) |ndk| {
            const libc_file = generateAndroidLibcConfig(b, target, ndk);
            lib.setLibCFile(libc_file);
        }
    }

    // For iOS, add SDK paths via sysroot
    if (is_ios) {
        if (sysroot) |sr| {
            lib.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sr}) });
            // Set library path relative to sysroot
            lib.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sr}) });
        }
    }

    // macOS/iOS: Add headerpad for install_name_tool compatibility (required by Dart)
    if (is_apple) {
        lib.headerpad_max_install_names = true;
    }

    return lib;
}

/// Generates an Android libc configuration file for NDK.
fn generateAndroidLibcConfig(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    ndk_path: []const u8,
) std.Build.LazyPath {
    const wf = b.addWriteFiles();

    // Determine host tag for NDK toolchain
    const host_tag = switch (@import("builtin").os.tag) {
        .macos => "darwin-x86_64",
        .linux => "linux-x86_64",
        .windows => "windows-x86_64",
        else => @panic("Unsupported host OS for Android NDK"),
    };

    // Map target to NDK triple
    const ndk_triple = switch (target.result.abi) {
        .android => switch (target.result.cpu.arch) {
            .x86_64 => "x86_64-linux-android",
            .aarch64 => "aarch64-linux-android",
            else => @panic("Unsupported Android architecture"),
        },
        .androideabi => "arm-linux-androideabi",
        else => @panic("Not an Android target"),
    };

    const sysroot = b.fmt("{s}/toolchains/llvm/prebuilt/{s}/sysroot", .{ ndk_path, host_tag });
    const api_level = "21";

    const content = b.fmt(
        \\include_dir={s}/usr/include
        \\sys_include_dir={s}/usr/include/{s}
        \\crt_dir={s}/usr/lib/{s}/{s}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\gcc_dir=
        \\
    , .{ sysroot, sysroot, ndk_triple, sysroot, ndk_triple, api_level });

    return wf.add("android-libc.txt", content);
}

fn getIosSysroot(allocator: std.mem.Allocator, sdk: []const u8) ?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "xcrun", "--sdk", sdk, "--show-sdk-path" },
    }) catch return null;

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) return null;

    // Trim trailing newline
    const path = std.mem.trimRight(u8, result.stdout, "\n");
    return allocator.dupe(u8, path) catch null;
}
