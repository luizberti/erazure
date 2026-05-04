const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const params = b.createModule(.{ .root_source_file = b.option(
        std.Build.LazyPath,
        "params",
        "Path to the precomputed parameter table (zon)",
    ) orelse b.path("params.zon") });

    const mod = b.addModule("CauchyReedSolomon", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{.{ .name = "params", .module = params }},
    });

    const tests = b.step("test", "Runs testing suite against reference implementation");
    const bench = b.step("bench", "Run benchmarks against reference implementation");
    const search = b.step("search", "Run optimal parameter search for K,M pairs");

    // MARK: TESTING

    tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    tests.dependOn(blk: {
        const module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("ref/tests.zig"),
            .imports = &.{.{ .name = "CRS", .module = mod }},
            .sanitize_c = .off,
            .link_libc = true,
        });
        module.addCSourceFile(.{ .file = b.path("ref/CauchyReedSolomon.c"), .flags = &.{"-O3"} });
        break :blk &b.addRunArtifact(b.addTest(.{ .root_module = module })).step;
    });

    // MARK: BENCHMARKING

    bench.dependOn(blk: {
        const module = b.createModule(.{
            .target = target,
            // NOTE: .ReleaseFast segfaults, might be a Zig 0.16 codegen bug. Changing to .ReleaseSafe for now
            .optimize = .ReleaseSafe,
            .root_source_file = b.path("ref/bench.zig"),
            .imports = &.{.{ .name = "CRS", .module = mod }},
            .sanitize_c = .off,
            .link_libc = true,
        });
        module.addCSourceFile(.{ .file = b.path("ref/CauchyReedSolomon.c"), .flags = &.{"-O3"} });
        break :blk &b.addRunArtifact(b.addExecutable(.{ .name = "bench", .root_module = module })).step;
    });

    // MARK: PARAMETER SEARCH

    search.dependOn(blk: {
        const module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseFast,
            .root_source_file = b.path("search.zig"),
            .imports = &.{
                .{ .name = "CRS", .module = mod },
                .{ .name = "params", .module = params },
            },
        });
        const run = b.addRunArtifact(b.addExecutable(.{ .name = "search", .root_module = module }));
        if (b.args) |passthrough| run.addArgs(passthrough);
        break :blk &run.step;
    });
}
