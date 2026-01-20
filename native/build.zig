const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Fetch hiredict dependency to get the C source files
    const hiredict_dep = b.dependency("hiredict", .{});

    // Get the upstream hiredict sources (hiredict depends on the actual hiredict C library)
    const upstream_dep = hiredict_dep.builder.dependency("hiredict", .{});
    const upstream_path = upstream_dep.path(".");

    const source_files = &[_][]const u8{
        "alloc.c",
        "async.c",
        "hiredict.c",
        "net.c",
        "read.c",
        "sds.c",
        "sockcompat.c",
    };

    const cflags = &[_][]const u8{"-std=c99"};

    // Build shared library for FFI
    const shared_lib = b.addSharedLibrary(.{
        .name = "hiredis",
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    shared_lib.addCSourceFiles(.{
        .root = upstream_path,
        .files = source_files,
        .flags = cflags,
    });

    shared_lib.addIncludePath(upstream_path);

    // Platform-specific libraries
    const platform_libs: []const []const u8 = switch (target.result.os.tag) {
        .windows => &.{ "ws2_32", "crypt32" },
        .freebsd => &.{"m"},
        .solaris => &.{"socket"},
        else => &.{},
    };
    for (platform_libs) |libname| {
        shared_lib.linkSystemLibrary(libname);
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
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    static_lib.addCSourceFiles(.{
        .root = upstream_path,
        .files = source_files,
        .flags = cflags,
    });

    static_lib.addIncludePath(upstream_path);

    for (platform_libs) |libname| {
        static_lib.linkSystemLibrary(libname);
    }

    b.installArtifact(static_lib);
}
