const std = @import("std");
const CRS = @import("CRS");

// Hardcoded limits of the C reference implementation (see #define MAX_K / MAX_M /
// MAX_W in CauchyReedSolomon.c). The Zig implementation supports larger configs,
// but cross-impl tests are capped here.
const REF_MAX_K = 24;
const REF_MAX_M = 6;
const REF_MAX_W = 8;
const REF_CONTEXT_SIZE = 3 + REF_MAX_K * REF_MAX_W * REF_MAX_M * REF_MAX_W;

extern fn crs_create(k: c_int, m: c_int, context: [*]u8) void;
extern fn crs_encode(context: [*]const u8, sources: u32, targets: u32, shards: [*][*]u8, shard_size: u32) void;

fn fillDeterministic(buf: []u8, seed: usize) void {
    for (buf, 0..) |*b, j| b.* = @truncate(seed *% 31 +% j *% 7 +% 13);
}

fn crossImplTest(comptime k: u8, comptime m: u8) !void {
    const RS = CRS.CODEC(k, m);
    const shard_size: u32 = 1024;
    const km: usize = @as(usize, k) + m;

    // -- Zig implementation --
    var zig_storage: [km][shard_size]u8 = undefined;
    var zig_shards: [km][]u8 = undefined;
    for (&zig_shards, &zig_storage) |*s, *st| s.* = st;

    for (0..k) |i| fillDeterministic(&zig_storage[i], i);

    const all_data: RS.Mask = (@as(RS.Mask, 1) << RS.K) - 1;
    const all_parity: RS.Mask = ((@as(RS.Mask, 1) << (RS.K + RS.M)) - 1) & ~all_data;
    RS.repair(&zig_shards, shard_size, all_data, all_parity);

    // -- C reference implementation --
    const context_size = 3 + @as(usize, k) * RS.W * @as(usize, m) * RS.W;
    var c_context: [REF_CONTEXT_SIZE]u8 = undefined;
    crs_create(k, m, &c_context);

    var c_storage: [km][shard_size]u8 = undefined;
    var c_shard_ptrs: [km][*]u8 = undefined;
    for (0..km) |i| c_shard_ptrs[i] = &c_storage[i];

    for (0..k) |i| fillDeterministic(&c_storage[i], i);

    crs_encode(&c_context, all_data, all_parity, &c_shard_ptrs, shard_size);

    // -- Compare context bytes (bitmatrix portion) --
    try std.testing.expectEqualSlices(u8, c_context[3..][0 .. context_size - 3], RS.ENCODER.data[0 .. context_size - 3]);

    // Verify context header matches.
    try std.testing.expectEqual(c_context[0], RS.W);
    try std.testing.expectEqual(c_context[1], RS.K);
    try std.testing.expectEqual(c_context[2], RS.M);

    // -- Compare encoded parity shards --
    for (k..km) |i| {
        try std.testing.expectEqualSlices(u8, &c_storage[i], &zig_storage[i]);
    }

    // -- Compare decode: erase shard 0, recover, compare --
    var zig_saved: [shard_size]u8 = undefined;
    @memcpy(&zig_saved, zig_shards[0]);
    @memset(zig_shards[0], 0);

    var c_saved: [shard_size]u8 = undefined;
    @memcpy(&c_saved, c_storage[0][0..shard_size]);
    @memset(&c_storage[0], 0);

    const full_mask: RS.Mask = (@as(RS.Mask, 1) << (RS.K + RS.M)) - 1;
    const target_bit: RS.Mask = 1;
    const sources: RS.Mask = full_mask & ~target_bit;

    RS.repair(&zig_shards, shard_size, sources, target_bit);
    crs_encode(&c_context, sources, target_bit, &c_shard_ptrs, shard_size);

    try std.testing.expectEqualSlices(u8, &zig_saved, zig_shards[0]);
    try std.testing.expectEqualSlices(u8, &c_saved, c_storage[0][0..shard_size]);
    try std.testing.expectEqualSlices(u8, c_storage[0][0..shard_size], zig_shards[0]);
}

test "oracle: smoke tests" {
    try crossImplTest(1, 1);
    try crossImplTest(2, 2);
    try crossImplTest(4, 2);
    try crossImplTest(8, 4);
    try crossImplTest(12, 4);
    try crossImplTest(16, 6);
    try crossImplTest(24, 6);
}

fn crossImplMultiErasureTest(comptime k: u8, comptime m: u8) !void {
    if (k <= 1 or m <= 1) return;
    const RS = CRS.CODEC(k, m);
    const shard_size: u32 = 1024;
    const km: usize = @as(usize, k) + m;

    var zig_storage: [km][shard_size]u8 = undefined;
    var zig_shards: [km][]u8 = undefined;
    for (&zig_shards, &zig_storage) |*s, *st| s.* = st;

    var c_storage: [km][shard_size]u8 = undefined;
    var c_shard_ptrs: [km][*]u8 = undefined;
    for (0..km) |i| c_shard_ptrs[i] = &c_storage[i];

    for (0..k) |i| {
        fillDeterministic(&zig_storage[i], i + 100);
        fillDeterministic(&c_storage[i], i + 100);
    }

    const all_data: RS.Mask = (@as(RS.Mask, 1) << RS.K) - 1;
    const all_parity: RS.Mask = ((@as(RS.Mask, 1) << (RS.K + RS.M)) - 1) & ~all_data;

    var c_context: [REF_CONTEXT_SIZE]u8 = undefined;
    crs_create(k, m, &c_context);

    RS.repair(&zig_shards, shard_size, all_data, all_parity);
    crs_encode(&c_context, all_data, all_parity, &c_shard_ptrs, shard_size);

    var zig_originals: [m][shard_size]u8 = undefined;
    var c_originals: [m][shard_size]u8 = undefined;
    const erased_mask: RS.Mask = (@as(RS.Mask, 1) << RS.M) - 1;
    for (0..m) |i| {
        @memcpy(&zig_originals[i], zig_shards[i]);
        @memcpy(&c_originals[i], c_storage[i][0..shard_size]);
        @memset(zig_shards[i], 0);
        @memset(&c_storage[i], 0);
    }

    const full_mask: RS.Mask = (@as(RS.Mask, 1) << (RS.K + RS.M)) - 1;
    const sources: RS.Mask = full_mask & ~erased_mask;

    RS.repair(&zig_shards, shard_size, sources, erased_mask);
    crs_encode(&c_context, sources, erased_mask, &c_shard_ptrs, shard_size);

    for (0..m) |i| {
        try std.testing.expectEqualSlices(u8, &zig_originals[i], zig_shards[i]);
        try std.testing.expectEqualSlices(u8, &c_originals[i], c_storage[i][0..shard_size]);
        try std.testing.expectEqualSlices(u8, c_storage[i][0..shard_size], zig_shards[i]);
    }
}

test "oracle: multi-erasure" {
    try crossImplMultiErasureTest(4, 2);
    try crossImplMultiErasureTest(8, 4);
    try crossImplMultiErasureTest(24, 6);
}

test "fuzz: oracle" {
    const pairs = .{ .{ 1, 1 }, .{ 4, 2 }, .{ 8, 4 }, .{ 12, 4 }, .{ 16, 6 }, .{ 24, 6 } };
    inline for (pairs) |pair| try std.testing.fuzz(pair, struct {
        fn run(p: @TypeOf(pair), smith: *std.testing.Smith) anyerror!void {
            @disableInstrumentation();
            const k: u8 = p[0];
            const m: u8 = p[1];
            const RS = CRS.CODEC(k, m);
            const shard_size: u32 = 1024;
            const km: usize = @as(usize, k) + m;

            var zig_storage: [k + m][shard_size]u8 = undefined;
            var zig_shards: [k + m][]u8 = undefined;
            for (&zig_shards, &zig_storage) |*s, *st| s.* = st;

            var c_storage: [k + m][shard_size]u8 = undefined;
            var c_ptrs: [k + m][*]u8 = undefined;
            for (0..km) |i| c_ptrs[i] = &c_storage[i];

            for (0..k) |i| {
                smith.bytes(&zig_storage[i]);
                @memcpy(&c_storage[i], &zig_storage[i]);
            }

            var c_context: [REF_CONTEXT_SIZE]u8 = undefined;
            crs_create(k, m, &c_context);

            const all_data: RS.Mask = (@as(RS.Mask, 1) << RS.K) - 1;
            const all_parity: RS.Mask = ((@as(RS.Mask, 1) << (RS.K + RS.M)) - 1) & ~all_data;
            const full: RS.Mask = (@as(RS.Mask, 1) << (RS.K + RS.M)) - 1;

            RS.repair(&zig_shards, shard_size, all_data, all_parity);
            crs_encode(&c_context, all_data, all_parity, &c_ptrs, shard_size);
            for (k..km) |i| {
                try std.testing.expectEqualSlices(u8, &c_storage[i], &zig_storage[i]);
            }

            while (!smith.eosWeightedSimple(15, 1)) {
                const e = smith.valueRangeAtMost(u8, 1, RS.M);
                var targets: RS.Mask = 0;
                var got: usize = 0;
                while (got < e) {
                    const i = smith.valueRangeAtMost(u8, 0, RS.K + RS.M - 1);
                    const bit: RS.Mask = @as(RS.Mask, 1) << @intCast(i);
                    if (targets & bit == 0) {
                        targets |= bit;
                        got += 1;
                    }
                }
                const sources = full & ~targets;

                var zig_saved: [RS.K + RS.M][shard_size]u8 = undefined;
                var c_saved: [RS.K + RS.M][shard_size]u8 = undefined;
                for (0..km) |i| {
                    const bit: RS.Mask = @as(RS.Mask, 1) << @intCast(i);
                    if (targets & bit != 0) {
                        @memcpy(&zig_saved[i], zig_shards[i]);
                        @memcpy(&c_saved[i], &c_storage[i]);
                        @memset(zig_shards[i], 0);
                        @memset(&c_storage[i], 0);
                    }
                }

                RS.repair(&zig_shards, shard_size, sources, targets);
                crs_encode(&c_context, sources, targets, &c_ptrs, shard_size);

                for (0..km) |i| {
                    const bit: RS.Mask = @as(RS.Mask, 1) << @intCast(i);
                    if (targets & bit != 0) {
                        try std.testing.expectEqualSlices(u8, &zig_saved[i], zig_shards[i]);
                        try std.testing.expectEqualSlices(u8, &c_saved[i], &c_storage[i]);
                        try std.testing.expectEqualSlices(u8, &c_storage[i], zig_shards[i]);
                    }
                }
            }
        }
    }.run, .{});
}
