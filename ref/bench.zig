const std = @import("std");
const CRS = @import("CRS");

// Hardcoded limits of the C reference implementation (see #define MAX_K / MAX_M /
// MAX_W in CauchyReedSolomon.c). The Zig implementation supports larger configs,
// but the C-side context buffer must be sized to these.
const REF_MAX_K = 24;
const REF_MAX_M = 6;
const REF_MAX_W = 8;
const REF_CONTEXT_SIZE = 3 + REF_MAX_K * REF_MAX_W * REF_MAX_M * REF_MAX_W;

extern fn crs_create(k: c_int, m: c_int, context: [*]u8) void;
extern fn crs_encode(context: [*]const u8, sources: u32, targets: u32, shards: [*][*]u8, shard_size: u32) void;
extern fn crs_xor(source: [*]u8, target: [*]u8, length: u32) void;

fn fillDeterministic(buf: []u8, seed: usize) void {
    for (buf, 0..) |*b, j| b.* = @truncate(seed *% 31 +% j *% 7 +% 13);
}

fn benchEncode(
    comptime label: []const u8,
    comptime k: u8,
    comptime m: u8,
    comptime shard_size: u32,
    comptime iterations: u32,
    allocator: std.mem.Allocator,
    io: std.Io,
    stderr: *std.Io.Writer,
) !void {
    const RS = CRS.CODEC(k, m);
    const km: usize = @as(usize, k) + m;

    // Heap-allocate shard storage (can be tens of MB for large configs).
    var zig_bufs: [km][]u8 = undefined;
    var c_bufs: [km][]u8 = undefined;
    for (0..km) |i| {
        zig_bufs[i] = try allocator.alloc(u8, shard_size);
        c_bufs[i] = try allocator.alloc(u8, shard_size);
    }
    defer for (0..km) |i| {
        allocator.free(zig_bufs[i]);
        allocator.free(c_bufs[i]);
    };

    for (0..k) |i| {
        fillDeterministic(zig_bufs[i], i);
        fillDeterministic(c_bufs[i], i);
    }

    var c_shard_ptrs: [km][*]u8 = undefined;
    for (0..km) |i| c_shard_ptrs[i] = c_bufs[i].ptr;

    var c_context: [REF_CONTEXT_SIZE]u8 = undefined;
    crs_create(k, m, &c_context);

    const all_data: RS.Mask = (@as(RS.Mask, 1) << RS.K) - 1;
    const all_parity: RS.Mask = ((@as(RS.Mask, 1) << (RS.K + RS.M)) - 1) & ~all_data;
    // C reference still uses u32.
    const c_sources: u32 = @intCast(all_data);
    const c_targets: u32 = @intCast(all_parity);

    // Benchmark Zig
    const zig_start = std.Io.Clock.awake.now(io);
    for (0..iterations) |_| {
        RS.repair(&zig_bufs, shard_size, all_data, all_parity);
    }
    const zig_end = std.Io.Clock.awake.now(io);
    const zig_ns: u64 = @intCast(zig_start.durationTo(zig_end).nanoseconds);

    // Benchmark C
    const c_start = std.Io.Clock.awake.now(io);
    for (0..iterations) |_| {
        crs_encode(&c_context, c_sources, c_targets, &c_shard_ptrs, shard_size);
    }
    const c_end = std.Io.Clock.awake.now(io);
    const c_ns: u64 = @intCast(c_start.durationTo(c_end).nanoseconds);

    const data_bytes: u64 = @as(u64, shard_size) * k * iterations;
    const zig_ms = @as(f64, @floatFromInt(zig_ns)) / 1_000_000.0;
    const c_ms = @as(f64, @floatFromInt(c_ns)) / 1_000_000.0;
    const zig_tp = @as(f64, @floatFromInt(data_bytes)) / (@as(f64, @floatFromInt(zig_ns)) / 1e9) / (1024.0 * 1024.0);
    const c_tp = @as(f64, @floatFromInt(data_bytes)) / (@as(f64, @floatFromInt(c_ns)) / 1e9) / (1024.0 * 1024.0);

    try stderr.print("{s:<40} Zig: {d:8.1}ms ({d:8.1} MB/s)  C: {d:8.1}ms ({d:8.1} MB/s)\n", .{
        label, zig_ms, zig_tp, c_ms, c_tp,
    });
}

fn benchRecover(
    comptime label: []const u8,
    comptime k: u8,
    comptime m: u8,
    comptime shard_size: u32,
    comptime erasures: u32,
    comptime iterations: u32,
    allocator: std.mem.Allocator,
    io: std.Io,
    stderr: *std.Io.Writer,
) !void {
    comptime std.debug.assert(erasures >= 1 and erasures <= m);

    const RS = CRS.CODEC(k, m);
    const km: usize = @as(usize, k) + m;

    var zig_bufs: [km][]u8 = undefined;
    var c_bufs: [km][]u8 = undefined;
    for (0..km) |i| {
        zig_bufs[i] = try allocator.alloc(u8, shard_size);
        c_bufs[i] = try allocator.alloc(u8, shard_size);
    }
    defer for (0..km) |i| {
        allocator.free(zig_bufs[i]);
        allocator.free(c_bufs[i]);
    };

    for (0..k) |i| {
        fillDeterministic(zig_bufs[i], i);
        fillDeterministic(c_bufs[i], i);
    }

    var c_shard_ptrs: [km][*]u8 = undefined;
    for (0..km) |i| c_shard_ptrs[i] = c_bufs[i].ptr;

    var c_context: [REF_CONTEXT_SIZE]u8 = undefined;
    crs_create(k, m, &c_context);

    // Pre-encode so parity shards are valid before we benchmark the decode path.
    RS.encode(&zig_bufs, shard_size);
    const all_data: RS.Mask = (@as(RS.Mask, 1) << RS.K) - 1;
    const all_parity: RS.Mask = ((@as(RS.Mask, 1) << (RS.K + RS.M)) - 1) & ~all_data;
    crs_encode(&c_context, @intCast(all_data), @intCast(all_parity), &c_shard_ptrs, shard_size);

    // Erase the first `erasures` data shards.
    const targets: RS.Mask = (@as(RS.Mask, 1) << erasures) - 1;
    const full: RS.Mask = (@as(RS.Mask, 1) << (RS.K + RS.M)) - 1;
    const sources: RS.Mask = full & ~targets;

    const zig_start = std.Io.Clock.awake.now(io);
    for (0..iterations) |_| {
        RS.repair(&zig_bufs, shard_size, sources, targets);
    }
    const zig_end = std.Io.Clock.awake.now(io);
    const zig_ns: u64 = @intCast(zig_start.durationTo(zig_end).nanoseconds);

    const c_start = std.Io.Clock.awake.now(io);
    for (0..iterations) |_| {
        crs_encode(&c_context, @intCast(sources), @intCast(targets), &c_shard_ptrs, shard_size);
    }
    const c_end = std.Io.Clock.awake.now(io);
    const c_ns: u64 = @intCast(c_start.durationTo(c_end).nanoseconds);

    // Throughput normalized to bytes reconstructed per iteration.
    const data_bytes: u64 = @as(u64, shard_size) * erasures * iterations;
    const zig_ms = @as(f64, @floatFromInt(zig_ns)) / 1_000_000.0;
    const c_ms = @as(f64, @floatFromInt(c_ns)) / 1_000_000.0;
    const zig_tp = @as(f64, @floatFromInt(data_bytes)) / (@as(f64, @floatFromInt(zig_ns)) / 1e9) / (1024.0 * 1024.0);
    const c_tp = @as(f64, @floatFromInt(data_bytes)) / (@as(f64, @floatFromInt(c_ns)) / 1e9) / (1024.0 * 1024.0);

    try stderr.print("{s:<40} Zig: {d:8.1}ms ({d:8.1} MB/s)  C: {d:8.1}ms ({d:8.1} MB/s)\n", .{
        label, zig_ms, zig_tp, c_ms, c_tp,
    });
}

fn benchXorAtSize(
    size: usize,
    iterations: usize,
    allocator: std.mem.Allocator,
    io: std.Io,
    stderr: *std.Io.Writer,
) !void {
    const src = try allocator.alloc(u8, size);
    defer allocator.free(src);
    const tgt = try allocator.alloc(u8, size);
    defer allocator.free(tgt);

    fillDeterministic(src, 42);
    fillDeterministic(tgt, 99);

    if (size >= 1024 * 1024) {
        try stderr.print("  {d} MiB x {d} iterations:\n", .{ size / (1024 * 1024), iterations });
    } else {
        try stderr.print("  {d} B x {d} iterations:\n", .{ size, iterations });
    }

    const Wrap = struct {
        fn swar64A(s: []const u8, t: []u8) void {
            CRS.xorBytesSWAR(s, t, 64, true);
        }
        fn swar64U(s: []const u8, t: []u8) void {
            CRS.xorBytesSWAR(s, t, 64, false);
        }
        fn swar128A(s: []const u8, t: []u8) void {
            CRS.xorBytesSWAR(s, t, 128, true);
        }
        fn swar128U(s: []const u8, t: []u8) void {
            CRS.xorBytesSWAR(s, t, 128, false);
        }
    };
    const xor_fns = .{
        .{ "xorBytesNaive      (byte loop)", CRS.xorBytesNaive },
        .{ "xorBytesSWAR 64b   (aligned)", Wrap.swar64A },
        .{ "xorBytesSWAR 64b   (unaligned)", Wrap.swar64U },
        .{ "xorBytesSWAR 128b  (aligned)", Wrap.swar128A },
        .{ "xorBytesSWAR 128b  (unaligned)", Wrap.swar128U },
        .{ "xorBytesSIMD       (@Vector 128B)", CRS.xorBytesSIMD },
    };

    inline for (xor_fns) |entry| {
        const label = entry[0];
        const func = entry[1];

        const start = std.Io.Clock.awake.now(io);
        for (0..iterations) |_| func(src, tgt);
        const end = std.Io.Clock.awake.now(io);

        const ns: u64 = @intCast(start.durationTo(end).nanoseconds);
        const bytes: u64 = @as(u64, size) * iterations;
        const tp = @as(f64, @floatFromInt(bytes)) / (@as(f64, @floatFromInt(ns)) / 1e9) / (1024.0 * 1024.0);

        try stderr.print("    {s:<36} {d:8.1}ms  ({d:8.1} MB/s)\n", .{
            label,
            @as(f64, @floatFromInt(ns)) / 1_000_000.0,
            tp,
        });
    }

    // C reference dot_xor
    {
        const start = std.Io.Clock.awake.now(io);
        for (0..iterations) |_| crs_xor(src.ptr, tgt.ptr, @intCast(size));
        const end = std.Io.Clock.awake.now(io);

        const ns: u64 = @intCast(start.durationTo(end).nanoseconds);
        const bytes: u64 = @as(u64, size) * iterations;
        const c_tp = @as(f64, @floatFromInt(bytes)) / (@as(f64, @floatFromInt(ns)) / 1e9) / (1024.0 * 1024.0);

        try stderr.print("    {s:<36} {d:8.1}ms  ({d:8.1} MB/s)\n", .{
            "C ref       (dot_xor, u64 words)",
            @as(f64, @floatFromInt(ns)) / 1_000_000.0,
            c_tp,
        });
    }
}

fn benchXor(allocator: std.mem.Allocator, io: std.Io, stderr: *std.Io.Writer) !void {
    try stderr.print("XOR variant comparison\n", .{});
    try stderr.print("----------------------\n", .{});
    try benchXorAtSize(1536, 1024, allocator, io, stderr);
    try stderr.print("\n", .{});
    try benchXorAtSize(64 * 1024 * 1024, 256, allocator, io, stderr);
    try stderr.print("\n", .{});
    try benchXorAtSize(1024 * 1024 * 1024, 64, allocator, io, stderr);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    try stderr.print("Cauchy Reed-Solomon — Zig vs C reference benchmark (ReleaseFast)\n", .{});
    try stderr.print("=================================================================\n\n", .{});

    try benchEncode("k=4  m=2  shard=64KB", 4, 2, 64 * 1024, 1000, allocator, io, stderr);
    try benchEncode("k=8  m=4  shard=64KB", 8, 4, 64 * 1024, 500, allocator, io, stderr);
    try benchEncode("k=16 m=6  shard=64KB", 16, 6, 64 * 1024, 200, allocator, io, stderr);
    try benchEncode("k=4  m=2  shard=1MB", 4, 2, 1024 * 1024, 100, allocator, io, stderr);
    try benchEncode("k=8  m=4  shard=1MB", 8, 4, 1024 * 1024, 50, allocator, io, stderr);
    try benchEncode("k=24 m=6  shard=1MB", 24, 6, 1024 * 1024, 20, allocator, io, stderr);

    try stderr.print("\nRecovery (erase first E data shards)\n", .{});
    try stderr.print("------------------------------------\n", .{});
    try benchRecover("k=4  m=2  shard=1MB  E=1 (fast)", 4, 2, 1024 * 1024, 1, 100, allocator, io, stderr);
    try benchRecover("k=4  m=2  shard=1MB  E=2 (full)", 4, 2, 1024 * 1024, 2, 100, allocator, io, stderr);
    try benchRecover("k=8  m=4  shard=1MB  E=1 (fast)", 8, 4, 1024 * 1024, 1, 50, allocator, io, stderr);
    try benchRecover("k=8  m=4  shard=1MB  E=4 (full)", 8, 4, 1024 * 1024, 4, 50, allocator, io, stderr);
    try benchRecover("k=24 m=6  shard=1MB  E=1 (fast)", 24, 6, 1024 * 1024, 1, 20, allocator, io, stderr);
    try benchRecover("k=24 m=6  shard=1MB  E=6 (full)", 24, 6, 1024 * 1024, 6, 20, allocator, io, stderr);

    try stderr.print("\n", .{});
    try benchXor(allocator, io, stderr);

    try stderr.print("\nDone.\n", .{});
    try stderr.flush();
}
