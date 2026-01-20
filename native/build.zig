const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Fetch hiredict dependency to get the C source files
    const hiredict_dep = b.dependency("hiredict", .{});

    // Get the upstream hiredict sources (hiredict depends on the actual hiredict C library)
    const upstream_dep = hiredict_dep.builder.dependency("hiredict", .{});
    const upstream_path = upstream_dep.path(".");

    const hiredict_source_files = &[_][]const u8{
        "alloc.c",
        "async.c",
        "hiredict.c",
        "net.c",
        "read.c",
        "sds.c",
        "sockcompat.c",
    };

    const cflags = &[_][]const u8{"-std=c99"};

    // Platform-specific libraries
    const platform_libs: []const []const u8 = switch (target.result.os.tag) {
        .windows => &.{ "ws2_32", "crypt32" },
        .freebsd => &.{"m"},
        .solaris => &.{"socket"},
        else => &.{},
    };

    // Build shared library for FFI
    const shared_lib = b.addSharedLibrary(.{
        .name = "hiredis",
        .root_source_file = b.path("src/async_loop.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Add hiredict C sources
    shared_lib.addCSourceFiles(.{
        .root = upstream_path,
        .files = hiredict_source_files,
        .flags = cflags,
    });

    // Include paths for both hiredict headers and our Zig code
    shared_lib.addIncludePath(upstream_path);

    for (platform_libs) |libname| {
        shared_lib.linkSystemLibrary(libname);
    }

    // macOS: Add headerpad for install_name_tool compatibility (required by Dart)
    if (target.result.os.tag == .macos) {
        shared_lib.headerpad_max_install_names = true;
    }

    // Install headers for ffigen
    shared_lib.installHeadersDirectory(
        upstream_path,
        "",
        .{ .include_extensions = &.{
            "alloc.h",
            "async.h",
            "hiredict.h",
            "net.h",
            "read.h",
            "sds.h",
            "sockcompat.h",
        } },
    );

    b.installArtifact(shared_lib);

    // Also build static library
    const static_lib = b.addStaticLibrary(.{
        .name = "hiredis",
        .root_source_file = b.path("src/async_loop.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    static_lib.addCSourceFiles(.{
        .root = upstream_path,
        .files = hiredict_source_files,
        .flags = cflags,
    });

    static_lib.addIncludePath(upstream_path);

    for (platform_libs) |libname| {
        static_lib.linkSystemLibrary(libname);
    }

    b.installArtifact(static_lib);
}
