const std = @import("std");
const CRS = @import("CRS");

const current: []const CRS.Parameters = @import("params");

const usage =
    \\usage:
    \\  search K,M [K,M ...]                 search specific (k, m) pairs
    \\  search --range K_LO,M_LO K_HI,M_HI   search all (k, m) where K_LO <= k <= K_HI, M_LO <= m <= M_HI
    \\
    \\  --diff                               write a colored diff against current params.zon to stderr
    \\                                       instead of writing the full result to stdout
;

fn parsePair(s: []const u8) !struct { u8, u8 } {
    const k_str, const m_str = std.mem.cutScalar(u8, s, ',') orelse return error.InvalidPair;
    return .{ try std.fmt.parseInt(u8, k_str, 10), try std.fmt.parseInt(u8, m_str, 10) };
}

fn findCurrent(k: i32, m: i32) ?CRS.Parameters {
    var lo: usize = 0;
    var hi: usize = current.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const p = current[mid];
        if (p.k < k or (p.k == k and p.m < m)) lo = mid + 1 else hi = mid;
    }
    if (lo < current.len and current[lo].k == k and current[lo].m == m) return current[lo];
    return null;
}

fn writeParametersLine(w: *std.Io.Writer, p: CRS.Parameters) !void {
    var s: std.zon.Serializer = .{ .writer = w };
    var inner = try s.beginStruct(.{ .whitespace_style = .{ .wrap = false } });
    try inner.field("k", p.k, .{});
    try inner.field("m", p.m, .{});
    try inner.field("w", p.w, .{});
    try inner.field("p", p.p, .{});
    try inner.field("x", p.x, .{});
    try inner.field("y", p.y, .{});
    try inner.field("b", p.b, .{});
    try inner.end();
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    const raw_args = try init.minimal.args.toSlice(arena);

    var diff_mode = false;
    const args_buf = try arena.alloc([]const u8, raw_args.len);
    var args_len: usize = 0;
    for (raw_args) |a| {
        if (std.mem.eql(u8, a, "--diff")) {
            diff_mode = true;
        } else {
            args_buf[args_len] = a;
            args_len += 1;
        }
    }
    const args = args_buf[0..args_len];

    var pairs: std.ArrayList([2]u8) = .empty;
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--range")) {
        if (args.len != 4) {
            try stderr.writeAll(usage);
            try stderr.flush();
            std.process.exit(2);
        }
        const k_lo, const m_lo = try parsePair(args[2]);
        const k_hi, const m_hi = try parsePair(args[3]);
        if (k_lo > k_hi or m_lo > m_hi) {
            try stderr.writeAll("error: lower bound must not exceed upper bound\n");
            try stderr.flush();
            std.process.exit(2);
        }
        try pairs.ensureTotalCapacity(gpa, @as(usize, k_hi - k_lo + 1) * (m_hi - m_lo + 1));
        for (k_lo..@as(usize, k_hi) + 1) |k| for (m_lo..@as(usize, m_hi) + 1) |m| {
            pairs.appendAssumeCapacity(.{ @intCast(k), @intCast(m) });
        };
    } else if (args.len >= 2) {
        try pairs.ensureTotalCapacity(gpa, args.len - 1);
        for (args[1..]) |arg| {
            const k, const m = try parsePair(arg);
            pairs.appendAssumeCapacity(.{ k, m });
        }
    } else {
        try stderr.writeAll(usage);
        try stderr.flush();
        std.process.exit(2);
    }
    defer pairs.deinit(gpa);

    const futures = try arena.alloc(std.Io.Future(CRS.Parameters), pairs.items.len);
    for (pairs.items, futures) |pair, *fut| {
        fut.* = io.async(CRS.Parameters.search, .{ pair[0], pair[1] });
    }

    const results = try arena.alloc(CRS.Parameters, pairs.items.len);
    for (futures, results) |*fut, *res| res.* = fut.await(io);

    std.mem.sort(CRS.Parameters, results, {}, struct {
        fn lessThan(_: void, a: CRS.Parameters, b: CRS.Parameters) bool {
            return if (a.k != b.k) a.k < b.k else a.m < b.m;
        }
    }.lessThan);

    if (diff_mode) {
        var any = false;
        for (results) |p| {
            if (findCurrent(p.k, p.m)) |c| {
                if (std.meta.eql(c, p)) continue;
                any = true;
                try stderr.writeAll("\x1b[31m- ");
                try writeParametersLine(stderr, c);
                try stderr.writeAll(",\x1b[0m\n\x1b[32m+ ");
                try writeParametersLine(stderr, p);
                try stderr.writeAll(",\x1b[0m\n");
            } else {
                any = true;
                try stderr.writeAll("\x1b[32m+ ");
                try writeParametersLine(stderr, p);
                try stderr.writeAll(",\x1b[0m\n");
            }
        }
        if (!any) try stderr.writeAll("no changes against current params.zon\n");
        try stderr.flush();
        return;
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll(
        \\// !!! DO NOT EDIT THIS FILE BY HAND !!!
        \\// This file has been autogenerated by the `zig build search` command.
        \\// Use `zig build search --help` for more information.
        \\
        \\.{
        \\
    );
    for (results, 0..) |p, i| {
        if (i > 0 and p.k != results[i - 1].k) try stdout.writeByte('\n');
        try stdout.writeAll("    ");
        try writeParametersLine(stdout, p);
        try stdout.writeAll(",\n");
    }
    try stdout.writeAll("}\n");
    try stdout.flush();
}
