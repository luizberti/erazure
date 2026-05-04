//! # Optimized Cauchy Reed-Solomon Erasure Coding
//! Reed-Solomon erasure coding splits data into **`k`** data shards and produces
//! **`m`** parity shards such that the original data can be recovered from any **`k`**
//! of the **`k + m`** total shards. This tolerates the loss of up to **`m`** arbitrary
//! shards (data or parity).
//!
//! ## Choosing `k` and `m`
//! - **k** (data shards): how many pieces your data is split into. Higher k means
//!   less storage overhead but more computation per repair.
//! - **m** (parity shards): how many simultaneous failures you can tolerate.
//!   Higher m means more redundancy but more parity to compute and store.
//! - **Storage overhead**: the total storage is `(k + m) / k` times the original.
//!   For k=4, m=2 that's 1.5x (50% overhead). For k=10, m=4 that's 1.4x (40%).
//!
//! Common configurations used in production systems:
//!
//! | System          | k  | m | Overhead | Fault tolerance          |
//! |-----------------|----|---|----------|--------------------------|
//! | Simple mirror   |  1 | 1 | 2.00x    | 1 failure (replication)  |
//! | Triple mirror   |  1 | 2 | 3.00x    | 2 failures (replication) |
//! | Google Colossus |  6 | 3 | 1.50x    | 3 failures               |
//! | Azure LRCs      | 12 | 4 | 1.33x    | 4 failures (global)      |
//! | Backblaze.      | 17 | 3 | 1.18x    | 3 failures               |
//!
//! **Rules of thumb:**
//! - For most storage systems, k=4..12 and m=2..4 is the sweet spot.
//! - k=1 with any m gives pure replication (simplest, highest overhead).
//! - The first parity shard (m=1) is always a simple XOR of all data shards,
//!   so single-failure recovery is very fast regardless of k.
//! - `shard_size` must be divisible by both `w` (the Galois Field exponent,
//!   chosen automatically) and 8. Powers of 2 are ideal.
//!
//! ## Algorithm
//! Implements the algorithm from Plank & Xu's "Optimizing Cauchy Reed-Solomon
//! Codes for Fault-Tolerant Storage Applications" (2006). A Cauchy matrix over
//! GF(2^w) is expanded into a binary bitmatrix so that all encoding and decoding
//! reduces to XOR operations — no finite field arithmetic at runtime.
//!
//! The implementation exhaustively searches for the (w, primitive polynomial,
//! column offset, row offset) combination that minimizes the number of 1-bits
//! in the bitmatrix, directly minimizing the number of XOR operations needed to
//! encode. These optimal parameters are precomputed and stored in a lookup table
//! for all supported (k, m) pairs.
//!
//! ## Supported Ranges
//! - k >= 1, m >= 1
//! - k + m <= 127 (capped by u128 bitmask width)

const std = @import("std");
const assert = std.debug.assert;

const galois = @import("galois.zig");

// ============================================================================
// MARK: CODEC
// ============================================================================

/// Factory function that produces an erasure-coding type specialized for
/// `k` data shards and `m` parity shards. The encoding bitmatrix is computed
/// at compile time and stored in `.rodata`; the returned type is zero-sized
/// and exposes static methods — no instance needs to be constructed.
///
/// Example:
///
///     const RS = CODEC(4, 2);
///     RS.repair(&shards, shard_size, sources, targets);
///
/// Compile-time validation:
/// - `k >= 1`, `m >= 1`
/// - `k + m <= 127` (capped by u128 Mask width)
///
/// The optimal Galois Field parameters (w, primitive polynomial, offsets) are
/// looked up in a precomputed table for k <= 24, m <= 6, or computed by
/// exhaustive comptime search for larger configurations.
pub fn CODEC(comptime k: u8, comptime m: u8) type {
    if (k < 1 or m < 1) @compileError("k and m must be >= 1");
    // Mask snaps to a standard width {u16, u32, u64, u128}. u128 is the widest
    // supported, and we need one bit of slack above K+M for safe shifts.
    if (k +| m > 127) @compileError("k + m must be <= 127");

    const params = comptime Parameters.init(k, m) orelse unreachable;

    return struct {
        pub const K: comptime_int = k;
        pub const M: comptime_int = m;
        pub const W: comptime_int = params.w;

        pub const GF = galois.Field(W).init(params.p);

        pub const ENCODER: EncodingMatrix = .init();

        /// Unsigned integer wide enough to hold a bitmask over all k+m shards.
        /// Snapped to a standard width (u16/u32/u64/u128). The extra slack
        /// also guarantees shifts of `1 << (K+M)` never overflow.
        pub const Mask = switch (@as(u16, k) + m) {
            0x00...0x0F => u16,
            0x10...0x1F => u32,
            0x20...0x3F => u64,
            0x40...0x7F => u128,
            else => unreachable,
        };

        // MARK: ENCODING MATRIX

        pub const EncodingMatrix = struct {
            /// M row-blocks of W rows × K·W cols, row-major. Row-block `p` is
            /// the bitmatrix operator for parity shard `p` — the W bit-rows
            /// that XOR data-shard bits into parity-shard bit `p`.
            data: [K * M * W * W]u8 = undefined,

            /// Comptime-build an encoding matrix for the given GF parameters.
            /// First derives the optimized Cauchy matrix in GF(2^W) via
            /// `GF.cauchy`, then expands each k×m GF(2^W) entry into a W×W
            /// GF(2) sub-block (row `a` is the binary of `entry · 2^a`). The
            /// resulting (M·W) × (K·W) GF(2) bitmatrix is what the runtime
            /// XOR routines consume — every encode reduces to bytewise XOR
            /// with no field arithmetic.
            ///
            /// `params.p` selects the primitive polynomial; `params.x`/`.y`
            /// are the Cauchy row/column offsets (use `-1` for the m ≤ 2 fast
            /// paths, which don't take offsets).
            pub fn init() EncodingMatrix {
                @setEvalBranchQuota(2 * 1024 * 1024);

                var cauchy: [K * M]u8 = undefined;
                _ = GF.cauchy(K, M, params.x, params.y, &cauchy);

                var enc: EncodingMatrix = undefined;
                var count: u32 = 0;
                for (0..M) |r| for (0..K) |c| {
                    var v: u8 = cauchy[r * K + c];
                    for (0..W) |a| {
                        for (0..W) |b| {
                            const bit: u8 = if (v & (@as(u8, 1) << @intCast(b)) != 0) 1 else 0;
                            enc.data[r * W * K * W + W * c + a + K * W * b] = bit;
                            count += bit;
                        }
                        v = GF.multiply(v, 2);
                    }
                };
                assert(count > 0);

                // POSTCONDITION: row 0 of the Cauchy matrix is all 1s (which
                // `cauchy` guarantees), so the first W rows of the bitmatrix
                // are K copies of the W×W identity. The "1 erasure within
                // first k+1 shards" fast path in `repair` depends on this.
                for (0..K) |c| for (0..W) |a| {
                    const want: u8 = if (a == 0) 1 else 0;
                    assert(enc.data[@as(usize, c) * W + a] == want);
                };

                return enc;
            }

            /// The W bitmatrix rows for parity shard `p`, returned as a
            /// fixed-size pointer to `K * W * W` bytes (W rows × K·W cols,
            /// row-major).
            pub fn parityBlock(self: *const EncodingMatrix, p: u8) *const [K * W * W]u8 {
                assert(p < M);
                return self.data[@as(usize, p) * K * W * W ..][0 .. K * W * W];
            }
        };

        // MARK: DECODING MATRIX

        pub const DecodingMatrix = struct {
            data: [K * K * W * W]u8 = undefined,

            /// Builds the (K·W) × (K·W) decoding bitmatrix into `self.data`
            /// from the K surviving shards in `sources`, using `encoding` for
            /// the parity-shard rows. Each `sources[a]` is the (K+M)-shard
            /// index of the a-th survivor we'll use for recovery. After this
            /// returns, `invert()` transforms the matrix into the operator
            /// that maps surviving-shard bits back to original-data-shard bits.
            ///
            /// Layout: K row-blocks of W rows each, all row-major.
            /// - `sources[a] < K` (data shard survived): row-block `a` is a
            ///   W×W identity at column-block `sources[a]`, zero elsewhere.
            /// - `sources[a] >= K` (parity shard): row-block `a` is the W
            ///   rows of `encoding` for parity shard `sources[a] - K`.
            pub fn assemble(self: *DecodingMatrix, sources: *const [K]u8) void {
                const kww: usize = K * W * W;
                for (sources, 0..) |src, a| {
                    assert(src < K + M);
                    const block = self.data[a * kww ..][0..kww];
                    if (src < K) {
                        @memset(block, 0);
                        var idx: usize = @as(usize, src) * W;
                        for (0..W) |_| {
                            block[idx] = 1;
                            idx += K * W + 1;
                        }
                    } else {
                        @memcpy(block, ENCODER.parityBlock(src - K));
                    }
                }
            }

            /// Inverts `self.data` in place over GF(2). Replaces the matrix
            /// with its own inverse using only an O(K·W)-sized permutation
            /// array (~1.5 KB at K=24, W=8) — no K·W × K·W scratch buffer.
            ///
            /// Why this works in GF(2): for each pivot column k, the inner
            /// elimination loop XORs row k into row i for every i != k *but
            /// skips column k itself*. In GF(2), `1/pivot = pivot = 1`, so the
            /// (i, k) entries left untouched by column k's pass coincide
            /// algebraically with M⁻¹'s column k. No separate "I half" needs
            /// to be tracked.
            ///
            /// Pivoting is purely logical: `permutations[i]` records which
            /// physical row currently plays the role of logical row `i`. When
            /// `M[ki, ki] = 0` we swap *the indices* in `permutations`, never
            /// moving bytes during the forward pass. The eliminations operate
            /// on physical rows resolved through `permutations`, so the result
            /// is the same elimination sequence as the physical-swap variant,
            /// just performed at conjugated row positions.
            ///
            /// After the forward pass, storage holds `P · M⁻¹ · P⁻¹`. The
            /// reverse pass recovers M⁻¹ by undoing the conjugation: at each
            /// swap-while step `(i, perm[i])`, apply BOTH a row swap and a
            /// column swap to storage. Each step is conjugation by the
            /// transposition; the cumulative effect is conjugation by P⁻¹,
            /// which yields `P⁻¹ · (P · M⁻¹ · P⁻¹) · P = M⁻¹`. For Cauchy
            /// decoding matrices pivots are rare, so most positions are fixed
            /// points and the reverse pass typically does no work.
            ///
            /// Caller must guarantee invertibility. Non-invertible input fails
            /// the pivot-search assertion in safety-checked builds and is
            /// undefined behavior in ReleaseFast. The Cauchy MDS property
            /// guarantees invertibility for matrices CRS produces.
            pub fn invert(self: *DecodingMatrix) void {
                const size: usize = K * W;
                const P = if (size <= std.math.maxInt(u8)) u8 else u16;
                var permutations: [K * W]P = std.simd.iota(P, size);

                for (0..size) |ki| {
                    if (self.data[@as(usize, permutations[ki]) * size + ki] == 0) {
                        var r = ki + 1;
                        while (r < size and self.data[@as(usize, permutations[r]) * size + ki] == 0) r += 1;
                        assert(r < size);
                        std.mem.swap(P, &permutations[ki], &permutations[r]);
                    }

                    const pivot: usize = permutations[ki];
                    const pivot_lo = self.data[pivot * size ..][0..ki];
                    const pivot_hi = self.data[pivot * size + ki + 1 ..][0 .. size - ki - 1];

                    // NOTE: these two loops are over discontiguous ranges to skip over the `i == ki` check.
                    for (0..ki) |i| {
                        const phys: usize = permutations[i];
                        const mask: u8 = 0 -% self.data[phys * size + ki];
                        xorAndBytesSIMD(pivot_lo, self.data[phys * size ..][0..ki], mask);
                        xorAndBytesSIMD(pivot_hi, self.data[phys * size + ki + 1 ..][0 .. size - ki - 1], mask);
                    }
                    for (ki + 1..size) |i| {
                        const phys: usize = permutations[i];
                        const mask: u8 = 0 -% self.data[phys * size + ki];
                        xorAndBytesSIMD(pivot_lo, self.data[phys * size ..][0..ki], mask);
                        xorAndBytesSIMD(pivot_hi, self.data[phys * size + ki + 1 ..][0 .. size - ki - 1], mask);
                    }
                }

                // Reverse: storage holds P⁻¹ · M⁻¹ · P⁻¹, recover M⁻¹ via
                // M⁻¹ = P · storage · P — row-gather by π and col-gather by
                // π⁻¹. The two operations need OPPOSITE traversal directions
                // (π ≠ π⁻¹ for cycles of length ≥ 3), so we walk each cycle
                // twice: a read-only forward chase to do the row shift, then
                // the standard swap-while to do the col shift. The swap-while
                // destroys the cycle's perm entries, which conveniently marks
                // them visited for the outer loop's `continue` check.
                for (0..size) |start| {
                    if (permutations[start] == start) continue;

                    // Row gather by π: walk cycle forward, swapping each
                    // adjacent (cur, next) pair. Cumulative effect on a
                    // cycle (i_0, i_1, ..., i_{l-1}) is row[i_k] ← orig[i_{k+1}]
                    // (with wrap), which is row gather by π. Read-only over
                    // permutations.
                    var curr: usize = start;
                    while (permutations[curr] != start) : (curr = permutations[curr]) {
                        const lhs = self.data[curr * size ..][0..size];
                        const rhs = self.data[permutations[curr] * size ..][0..size];
                        std.mem.swap([size]u8, lhs, rhs);
                    }

                    // Col gather by π⁻¹: standard swap-while on permutations.
                    // Mutates this cycle to fixed points, marking it visited
                    // for the outer loop's `continue` check.
                    while (permutations[start] != start) {
                        const j: usize = permutations[start];
                        std.mem.swap(P, &permutations[start], &permutations[j]);
                        for (0..size) |r| std.mem.swap(u8, &self.data[r * size + start], &self.data[r * size + j]);
                    }
                }
            }
        };

        // MARK: REPAIR AND ENCODING

        /// Convenience wrapper around `repair` for the common case: all data
        /// shards are present (indices `0..K`), compute all parity shards
        /// (indices `K..K+M`).
        pub fn encode(shards: [][]u8, shard_size: u32) void {
            const data: Mask = (@as(Mask, 1) << K) - 1;
            const parity: Mask = ((@as(Mask, 1) << (K + M)) - 1) & ~data;
            repair(shards, shard_size, data, parity);
        }

        /// Repair missing shards — a unified operation that covers both encoding
        /// (generating parity from data) and decoding (recovering lost shards
        /// from survivors). In both cases you are "repairing" the code by
        /// computing the missing pieces from what's available.
        ///
        /// The `sources` and `targets` bitmasks tell it which shards are
        /// present and which to compute:
        ///
        /// - **Encoding** (computing parity from complete data):
        ///   `sources` = all k data shard bits set, `targets` = parity shard bits.
        /// - **Recovery** (reconstructing lost shards from any k survivors):
        ///   `sources` = bits for the k+ shards you still have, `targets` = bits
        ///   for the shards to reconstruct.
        ///
        /// - `shards`: slice of length k + m, each element `shard_size` bytes.
        /// - `shard_size`: bytes per shard. Must be divisible by `W` and 8.
        ///   Multiples of 128 give full SIMD lanes with no tail fallback.
        /// - `sources`: bitmask of present shards (at least k bits set).
        /// - `targets`: bitmask of shards to compute (at most m bits set,
        ///   no overlap with `sources`).
        pub fn repair(shards: [][]u8, shard_size: u32, sources: Mask, targets: Mask) void {
            assert(shards.len == K + M);
            assert(shard_size > 0);
            assert(shard_size % W == 0);
            assert(shard_size % 8 == 0);
            assert(sources & targets == 0);
            const full_mask: Mask = (@as(Mask, 1) << (K + M)) - 1;
            assert((sources | targets) & ~full_mask == 0);
            assert(@popCount(sources) >= K);
            assert(@popCount(targets) >= 1);
            assert(@popCount(targets) <= M);

            if (K == 1) {
                // Optimization for pure replication.
                const src_idx: usize = @ctz(sources);
                for (0..K + M) |i| {
                    if (targets & (@as(Mask, 1) << @intCast(i)) != 0) {
                        dotCpy(shards[src_idx][0..shard_size], shards[i][0..shard_size]);
                    }
                }
                return;
            }

            const k1_mask: Mask = (@as(Mask, 1) << (K + 1)) - 1;
            if (@popCount(targets) == 1 and
                @popCount(sources & k1_mask) == K and
                @popCount(targets & k1_mask) == 1)
            {
                // Optimization for 1 erasure (i < k + 1).
                const tgt_idx: usize = @ctz(targets);
                var copied = false;
                for (0..K + 1) |i| {
                    if (sources & (@as(Mask, 1) << @intCast(i)) != 0) {
                        if (!copied) {
                            dotCpy(shards[i][0..shard_size], shards[tgt_idx][0..shard_size]);
                            copied = true;
                        } else {
                            xorBytesSIMD(shards[i][0..shard_size], shards[tgt_idx][0..shard_size]);
                        }
                    }
                }
                return;
            }

            const kww: usize = K * W * W;
            var max_idx: u8 = K;
            var kerasures: u8 = 0;
            for (0..K) |i| {
                if (sources & (@as(Mask, 1) << @intCast(i)) == 0) {
                    max_idx = @intCast(i);
                    kerasures += 1;
                }
            }
            if (sources & (@as(Mask, 1) << K) == 0) max_idx = K;

            if (kerasures > 1 or (kerasures == 1 and sources & (@as(Mask, 1) << K) == 0)) {
                var s: [K]u8 = undefined;
                var si: u8 = 0;
                var sj: u8 = 0;
                while (sj < K) {
                    if (sources & (@as(Mask, 1) << @intCast(si)) != 0) {
                        s[sj] = si;
                        sj += 1;
                    }
                    si += 1;
                }

                var dec: DecodingMatrix = undefined;
                dec.assemble(&s);
                dec.invert();

                for (0..max_idx) |i| {
                    if (kerasures <= 0) break;
                    if (sources & (@as(Mask, 1) << @intCast(i)) == 0) {
                        dot(W, K, shards, shard_size, dec.data[kww * i ..], &s, i);
                        kerasures -= 1;
                    }
                }
            }

            if (kerasures > 0) {
                var s: [K]u8 = undefined;
                for (0..K) |si| {
                    const sii: u8 = @intCast(si);
                    s[si] = if (sii < max_idx) sii else sii + 1;
                }
                dot(W, K, shards, shard_size, &ENCODER.data, &s, max_idx);
            }

            for (0..M) |i| {
                if (sources & (@as(Mask, 1) << @intCast(K + i)) == 0) {
                    var s: [K]u8 = undefined;
                    for (0..K) |si| s[si] = @intCast(si);
                    dot(W, K, shards, shard_size, ENCODER.parityBlock(@intCast(i)), &s, K + i);
                }
            }
        }

        /// # NOT IMPLEMENTED
        /// Check that `shards` form a valid codeword — i.e. the stored parity
        /// shards match what `encode` would produce from the data shards.
        ///
        /// ## Cost
        /// The Reed-Solomon algebra does not offer a "syndrome shortcut" for
        /// systematic codes: verification = recompute all `M` parities, compare
        /// byte-for-byte. Cost ≈ `encode` cost. No free lunch.
        ///
        /// Two implementation options were considered:
        ///
        /// 1. **Full verify** (this signature): recompute all `M` parities into
        ///    scratch and `memcmp`. Complete coverage, cost ≈ `encode`.
        ///    Needs `shard_size` bytes of scratch (one parity at a time).
        ///
        /// 2. **XOR-parity-only quick check**: the `m = 1` parity row of the
        ///    bitmatrix is always all-ones, so `P[0] = D[0] ^ D[1] ^ … ^ D[K-1]`.
        ///    Costs `K` XOR passes (~`1/M` the full-verify work). Catches
        ///    corruption in an odd number of shards; misses pathological
        ///    multi-shard corruption that cancels in XOR. Only works when
        ///    `P[0]` is trusted. Rejected as a footgun — it looks like a
        ///    verify but isn't one.
        ///
        /// ## When to use this vs. a hash
        /// In practice, production systems (Backblaze, Ceph, Azure) pair RS
        /// with per-shard BLAKE3/xxHash rather than using RS verify for
        /// corruption detection. Hashing runs at 5–20 GB/s — comparable to
        /// or faster than recomputing parity (memory-bandwidth-bound). Hashes
        /// also pinpoint *which* shard is corrupted, which `verify` does not.
        /// Reach for this function only when you cannot store external hashes.
        pub fn verify() bool {
            @compileError("verifying is not implemented");
        }
    };
}

// ============================================================================
// MARK: XOR ROUTINES
// ============================================================================

/// XOR source into target using a simple byte loop. Intended to benefit from
/// LLVM auto-vectorization (SIMD), but Zig 0.16 had to disable auto-vectorization
/// due to miscompilation bugs.
pub inline fn xorBytesNaive(source: []const u8, target: []u8) void {
    assert(source.len == target.len);
    assert(source.len > 0);
    for (source, target) |s, *t| t.* ^= s;
}

/// SWAR (SIMD Within A Register) XOR. Processes `word` bits at a time using
/// scalar integer XOR. The tail is handled by `xorBytesNaive`.
///
/// `word` must be a power of two in bits and at least 16 (e.g. 64, 128).
///
/// When `unaligned_fallback` is true, misaligned source/target pairs fall back
/// to `xorBytesNaive` entirely, and matched-alignment pairs are pre-aligned with a
/// byte preamble before the SWAR loop. When false, the SWAR loop always runs
/// with unaligned loads/stores — simpler codegen, good on hardware with cheap
/// unaligned access.
///
/// You should probably default to `false` for the `unaligned_fallback` if
/// targeting modern platforms, however older hardware tends to have a much
/// greater penalty for unaligned loads.
pub fn xorBytesSWAR(
    source: []const u8,
    target: []u8,
    comptime word: u8,
    comptime unaligned_fallback: bool,
) void {
    comptime assert(@popCount(word) == 1 and word >= 16); // power of two, >= 2 bytes
    const Word = @Int(.unsigned, word);
    const size = word / 8;
    const mask = size - 1;

    assert(source.len == target.len);
    assert(source.len > 0);

    var offset: usize = 0;

    if (unaligned_fallback) {
        // Fall back to byte XOR if alignment cannot be corrected.
        if (@intFromPtr(source.ptr) & mask != @intFromPtr(target.ptr) & mask) {
            return xorBytesNaive(source, target);
        }

        // XOR bytes to reach word alignment.
        while ((@intFromPtr(source.ptr) + offset) & mask != 0 and offset < source.len) {
            target[offset] ^= source[offset];
            offset += 1;
        }
        if (offset == source.len) return;
    }

    // XOR words (aligned if we took the preamble above, unaligned otherwise).
    const words = (source.len - offset) / size;
    if (words > 0) {
        const src_w: [*]align(1) const Word = @ptrCast(source.ptr + offset);
        const tgt_w: [*]align(1) Word = @ptrCast(target.ptr + offset);
        for (0..words) |i| tgt_w[i] ^= src_w[i];
        offset += words * size;
    }

    // XOR remaining bytes.
    if (offset < source.len) return xorBytesNaive(source[offset..], target[offset..]);
}

/// XOR source into target using explicit SIMD via `@Vector(128, u8)`.
pub fn xorBytesSIMD(source: []const u8, target: []u8) void {
    assert(source.len == target.len);
    assert(source.len > 0);

    // TODO: should we have fallback behavior for unaligned data like for SWAR?
    //       I'm not entirely convinced this is necessary, this implementation seems
    //       to tolerate unaligned loads really well, I haven't observed significant
    //       deterioration.

    const V = @Vector(128, u8);
    const step: usize = @sizeOf(V);

    var offset: usize = 0;
    while (offset + step <= source.len) : (offset += step) {
        const s: V = source[offset..][0..step].*;
        const t: V = target[offset..][0..step].*;
        target[offset..][0..step].* = s ^ t;
    }

    for (source[offset..], target[offset..]) |s, *t| t.* ^= s;
}

/// Branchless `target ^= source & mask_byte`, byte-wise, via explicit SIMD.
/// `mask_byte` is broadcast across each lane: 0x00 means no-op, 0xFF means
/// full XOR. Used by `DecodingMatrix.invert` to fold the GF(2) "skip when
/// M[i,k]=0" branch into a mask-AND so the inner loop stays straight-line.
/// Decoding-matrix rows are short (16..1016 bytes for the supported K,W
/// range) so we use one 16-lane vector — matches an SSE/NEON register and
/// keeps the tail small.
inline fn xorAndBytesSIMD(source: []const u8, target: []u8, mask_byte: u8) void {
    assert(source.len == target.len);
    // Empty input is a no-op: invert's boundary cases (ki == 0 and
    // ki == size-1) produce zero-length pivot halves.

    const V = @Vector(16, u8);
    const mask: V = @splat(mask_byte);
    const step: usize = @sizeOf(V);

    var offset: usize = 0;
    while (offset + step <= source.len) : (offset += step) {
        const s: V = source[offset..][0..step].*;
        const t: V = target[offset..][0..step].*;
        target[offset..][0..step].* = t ^ (s & mask);
    }

    for (source[offset..], target[offset..]) |s, *t| t.* ^= s & mask_byte;
}

fn dot(
    comptime w: u8,
    comptime k: u8,
    shards: [][]u8,
    shard_size: u32,
    row: []const u8,
    source_index: []const u8,
    target_index: usize,
) void {
    comptime assert(w == 2 or w == 4 or w == 8);
    comptime assert(k >= 1 and k < (1 << w));
    assert(shard_size % w == 0);

    const chunk_size = dotChunkSize(w, k, shard_size);
    assert(w * chunk_size <= shard_size);
    assert(shard_size % (w * chunk_size) == 0);

    var shard_offset: u32 = 0;
    while (shard_offset < shard_size) {
        var column: usize = 0;
        for (0..w) |a| {
            var copied = false;
            const target_start = shard_offset + @as(u32, @intCast(a)) * chunk_size;
            const target_slice = shards[target_index][target_start .. target_start + chunk_size];

            for (0..k) |b| {
                const src_shard = shards[source_index[b]];
                for (0..w) |c| {
                    if (row[column] != 0) {
                        const src_start = shard_offset + @as(u32, @intCast(c)) * chunk_size;
                        const src_slice = src_shard[src_start .. src_start + chunk_size];
                        if (!copied) {
                            dotCpy(src_slice, target_slice);
                            copied = true;
                        } else {
                            xorBytesSIMD(src_slice, target_slice);
                        }
                    }
                    column += 1;
                }
            }
        }
        shard_offset += w * chunk_size;
    }
    assert(shard_offset == shard_size);
}

fn dotChunkSize(comptime w: u8, comptime k: u8, shard_size: u32) u32 {
    comptime assert(w == 2 or w == 4 or w == 8);
    comptime assert(k >= 1 and k < (1 << w));
    assert(shard_size % w == 0);

    var chunk_size: u32 = shard_size / w;
    while (chunk_size > 64 and
        chunk_size % 2 == 0 and
        @as(u64, 1 + @as(u32, k) * w) * chunk_size > 1048576)
    {
        chunk_size /= 2;
    }
    assert(chunk_size > 0);
    assert(shard_size % (w * chunk_size) == 0);
    return chunk_size;
}

fn dotCpy(source: []const u8, target: []u8) void {
    assert(source.len == target.len);
    assert(source.len > 0);
    @memcpy(target, source);
}

// ============================================================================
// MARK: PARAMETERS
// ============================================================================

/// Optimal Galois Field parameters for a given (k, m) pair.
///
/// Found by exhaustive search over all valid (w, p, x, y) combinations,
/// selecting the one that minimizes the bitmatrix density (fewest XOR ops).
pub const Parameters = struct {
    /// Number of data shards.
    k: u8,
    /// Number of parity shards.
    m: u8,
    /// Galois Field exponent. The field is GF(2^w). Smaller w means fewer bits
    /// per element and a smaller bitmatrix, but requires k + m <= 2^w.
    /// Possible values: 2 (k+m <= 4), 4 (k+m <= 16), 8 (k+m <= 256).
    w: u8,
    /// Primitive polynomial used to generate the Galois Field's log/exp tables.
    /// Different polynomials produce different matrices; the search picks the
    /// one yielding the fewest 1-bits. E.g. 7 for GF(4), 19 for GF(16).
    p: u8,
    /// Column offset for Cauchy matrix generation. Together with y, determines
    /// which elements of GF(2^w) are used as column/row indices in the Cauchy
    /// formula: matrix[r][c] = 1 / ((y+r) XOR (x+c)). `null` when m <= 2
    /// (where the matrix is constructed differently).
    x: ?u8,
    /// Row offset for Cauchy matrix generation. See x. `null` when m <= 2.
    y: ?u8,
    /// Total number of 1-bits in the resulting bitmatrix. Directly proportional
    /// to the number of XOR operations needed for encoding. Lower is faster.
    b: u32,

    pub fn init(k: u8, m: u8) ?Parameters {
        assert(k >= 1 and m >= 1);
        assert(@as(u16, k) + m <= 256);
        var lo: usize = 0;
        var hi: usize = OPTIMAL.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const p = OPTIMAL[mid];
            if (p.k < k or (p.k == k and p.m < m)) lo = mid + 1 else hi = mid;
        }
        if (lo < OPTIMAL.len and OPTIMAL[lo].k == k and OPTIMAL[lo].m == m) return OPTIMAL[lo];
        if (@inComptime()) return search(k, m);
        return null;
    }

    const OPTIMAL: []const Parameters = @import("params");

    /// Exhaustively searches for the optimal parameters for a (k, m) pair.
    /// Pre-resolves `w` from `k +| m`, then dispatches via `inline switch`
    /// so the body runs with `galois.Field(w_ct)` as a comptime type.
    /// Three instantiations are emitted (w = 2 / 4 / 8); the runtime
    /// dispatch picks one.
    pub fn search(k: u8, m: u8) Parameters {
        @setEvalBranchQuota(2 * 1024 * 1024);
        assert(k >= 1 and m >= 1);
        assert(@as(u16, k) + m <= 256);

        const W: u4 = switch (k +| m) {
            0x00...0x04 => 2,
            0x05...0x10 => 4,
            else => 8,
        };

        return switch (W) {
            inline 2, 4, 8 => |w| blk: {
                const GF = galois.Field(w);

                var best: Parameters = .{
                    .k = k,
                    .m = m,
                    .w = GF.W,
                    .p = 0,
                    .x = null,
                    .y = null,
                    .b = std.math.maxInt(u32),
                };

                // k * m bounded by (2^w)^2 = 256^2 at w=8; tighter since
                // k + m <= 256 so k*m <= 128*128. Use the widest bound.
                var matrix: [128 * 128]u8 = undefined;
                const matrix_slice = matrix[0 .. @as(usize, k) * m];

                for (GF.primitives) |prim| {
                    const tables = GF.init(prim);

                    if (m <= 2) {
                        const b = tables.cauchy(k, m, null, null, matrix_slice);
                        if (b < best.b) best = .{
                            .k = k,
                            .m = m,
                            .w = GF.W,
                            .p = @intCast(prim),
                            .x = null,
                            .y = null,
                            .b = b,
                        };
                        continue;
                    }

                    const z: u16 = GF.SIZE;
                    var x: u16 = 0;
                    while (x + k <= z) : (x += 1) {
                        var y: u16 = 0;
                        while (y + m <= z) : (y += 1) {
                            if (x == y) continue;
                            if (x < y and x + k > y) continue;
                            if (y < x and y + m > x) continue;

                            const b = tables.cauchy(k, m, @intCast(x), @intCast(y), matrix_slice);
                            if (b < best.b) best = .{
                                .k = k,
                                .m = m,
                                .w = GF.W,
                                .p = @intCast(prim),
                                .x = @intCast(x),
                                .y = @intCast(y),
                                .b = b,
                            };
                        }
                    }
                }

                break :blk best;
            },
            else => unreachable,
        };
    }
};

// ============================================================================
// MARK: TESTS
// ============================================================================

test "factory produces valid types for representative (k, m) pairs" {
    // Non-precomputed configs (k > 24 or m > 6) compile via comptime search
    // but it's too slow to include here — try e.g. `CODEC(30, 4)`
    // manually to exercise that path.
    inline for (.{
        .{ 1, 1 },
        .{ 4, 2 },
        .{ 8, 4 },
        .{ 16, 6 },
        .{ 24, 6 },
    }) |pair| {
        const RS = CODEC(pair[0], pair[1]);
        const expected_param = comptime Parameters.init(pair[0], pair[1]) orelse unreachable;
        try std.testing.expectEqual(@as(u8, pair[0]), RS.K);
        try std.testing.expectEqual(@as(u8, pair[1]), RS.M);
        try std.testing.expectEqual(@as(u8, expected_param.w), RS.W);
        const w_usize: usize = expected_param.w;
        try std.testing.expectEqual(pair[0] * w_usize * pair[1] * w_usize, RS.ENCODER.data.len);
    }
}

test "DecodingMatrix.invert: yields a true inverse" {
    // CODEC(4,2) — DecodingMatrix is [16*16]u8 (K=4, W=4).
    const RS = CODEC(4, 2);

    // Case 1: lower-triangular with 1s on diag — natural-order pivots only.
    var case_natural: [16 * 16]u8 = undefined;
    @memset(&case_natural, 0);
    for (0..16) |i| {
        case_natural[i * 16 + i] = 1;
        if (i > 0) case_natural[i * 16 + (i - 1)] = 1;
    }

    // Case 2: forces row-swap pivoting at multiple columns. Diagonal starts
    // with 0s in positions 0, 4, 8 — exercises permutation tracking.
    var case_pivots: [16 * 16]u8 = undefined;
    @memset(&case_pivots, 0);
    // Build as a permuted lower-triangular: row i has a 1 at column (i XOR 1).
    // That's a block of 2x2 swaps along the diagonal — invertible, pivots needed.
    for (0..16) |i| case_pivots[i * 16 + (i ^ 1)] = 1;
    // Add some lower-triangular fill to make it non-trivial.
    for (2..16) |i| case_pivots[i * 16 + (i - 2)] = 1;

    // Case 3: 3-cycle permutation pattern — row i has 1 only at col ((i+1) % 3)
    // within each 3-row block. Forces 3-cycles in the pivot permutation, which
    // exposes asymmetry between π and π⁻¹ that 2-cycle (involution) cases miss.
    // Plus diagonal+1 fill so eliminations actually happen.
    var case_long_cycle: [16 * 16]u8 = undefined;
    @memset(&case_long_cycle, 0);
    for (0..15) |i| {
        const block: usize = (i / 3) * 3;
        case_long_cycle[i * 16 + block + ((i - block + 1) % 3)] = 1;
        if (i > 0) case_long_cycle[i * 16 + (i - 1)] = 1;
    }
    case_long_cycle[15 * 16 + 15] = 1;

    inline for (.{ &case_natural, &case_pivots, &case_long_cycle }) |m_ptr| {
        var dec: RS.DecodingMatrix = .{ .data = m_ptr.* };
        dec.invert();

        // Sanity: M · M⁻¹ = I over GF(2).
        var product: [16 * 16]u8 = undefined;
        for (0..16) |i| for (0..16) |j| {
            var acc: u8 = 0;
            for (0..16) |kk| acc ^= m_ptr.*[i * 16 + kk] & dec.data[kk * 16 + j];
            product[i * 16 + j] = acc;
        };
        for (0..16) |i| for (0..16) |j| {
            const want: u8 = if (i == j) 1 else 0;
            try std.testing.expectEqual(want, product[i * 16 + j]);
        };
    }
}

test "xorBytes correct for all variants" {
    const a = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0x11, 0x22, 0x33, 0x44, 0x55 };
    const b = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99 };
    var mut = a;

    xorBytesNaive(&b, &mut);
    xorBytesNaive(&b, &mut);
    try std.testing.expectEqualSlices(u8, &mut, &a);
    xorBytesSWAR(&b, &mut, 64, true);
    xorBytesSWAR(&b, &mut, 64, true);
    try std.testing.expectEqualSlices(u8, &mut, &a);
    xorBytesSWAR(&b, &mut, 64, false);
    xorBytesSWAR(&b, &mut, 64, false);
    try std.testing.expectEqualSlices(u8, &mut, &a);
    xorBytesSWAR(&b, &mut, 128, true);
    xorBytesSWAR(&b, &mut, 128, true);
    try std.testing.expectEqualSlices(u8, &mut, &a);
    xorBytesSWAR(&b, &mut, 128, false);
    xorBytesSWAR(&b, &mut, 128, false);
    try std.testing.expectEqualSlices(u8, &mut, &a);
    xorBytesSIMD(&b, &mut);
    xorBytesSIMD(&b, &mut);
    try std.testing.expectEqualSlices(u8, &mut, &a);
}

test "single erasure fast path" {
    const RS = CODEC(4, 2);
    const shard_size: u32 = 1024;

    var shard_storage: [RS.K + RS.M][shard_size]u8 = undefined;
    var shards: [RS.K + RS.M][]u8 = undefined;
    for (&shards, &shard_storage) |*s, *storage| s.* = storage;

    // Fill data shards with deterministic data.
    for (0..RS.K) |i| {
        for (shards[i], 0..) |*byte, j| byte.* = @truncate(i *% 31 +% j *% 7);
    }

    // Encode parity.
    const all_data: RS.Mask = (@as(RS.Mask, 1) << RS.K) - 1;
    const all_parity: RS.Mask = ((@as(RS.Mask, 1) << (RS.K + RS.M)) - 1) & ~all_data;
    RS.repair(&shards, shard_size, all_data, all_parity);

    // Save original shard 0.
    var saved: [shard_size]u8 = undefined;
    @memcpy(&saved, shards[0]);

    // Erase shard 0.
    @memset(shards[0], 0);

    // Recover shard 0 using remaining data + first parity.
    const sources: RS.Mask = (all_data & ~@as(RS.Mask, 1)) | (@as(RS.Mask, 1) << RS.K);
    const targets: RS.Mask = 1;
    RS.repair(&shards, shard_size, sources, targets);

    try std.testing.expectEqualSlices(u8, &saved, shards[0]);
}

test "repair round-trips" {
    const RoundTrip = struct {
        fn repairRoundTrip(comptime k: u8, comptime m: u8) !void {
            const RS = CODEC(k, m);
            const shard_size: u32 = 1024;

            var shard_storage: [RS.K + RS.M][shard_size]u8 = undefined;
            var shards: [RS.K + RS.M][]u8 = undefined;
            for (&shards, &shard_storage) |*s, *storage| s.* = storage;

            // Fill data shards with deterministic data.
            for (0..RS.K) |i| {
                for (shards[i], 0..) |*byte, j| byte.* = @truncate(i *% 31 +% j *% 7);
            }

            // Save originals.
            var originals: [RS.K][shard_size]u8 = undefined;
            for (0..RS.K) |i| @memcpy(&originals[i], shards[i]);

            // Encode parity shards.
            const all_data: RS.Mask = (@as(RS.Mask, 1) << RS.K) - 1;
            const all_parity: RS.Mask = ((@as(RS.Mask, 1) << (RS.K + RS.M)) - 1) & ~all_data;
            RS.repair(&shards, shard_size, all_data, all_parity);

            // Test recovering from each possible single erasure.
            for (0..RS.K) |erased| {
                // Save and zero the erased shard.
                var saved: [shard_size]u8 = undefined;
                @memcpy(&saved, shards[erased]);
                @memset(shards[erased], 0);

                // Build source/target masks.
                const full_mask: RS.Mask = (@as(RS.Mask, 1) << (RS.K + RS.M)) - 1;
                const target_bit: RS.Mask = @as(RS.Mask, 1) << @intCast(erased);
                const sources: RS.Mask = full_mask & ~target_bit;

                RS.repair(&shards, shard_size, sources, target_bit);
                try std.testing.expectEqualSlices(u8, &saved, shards[erased]);
            }

            // Test recovering from m erasures (worst case): erase the first m shards.
            if (RS.M > 0 and RS.K > 1) {
                var saved_multi: [RS.M][shard_size]u8 = undefined;
                for (0..RS.M) |i| {
                    @memcpy(&saved_multi[i], shards[i]);
                    @memset(shards[i], 0);
                }

                const erased_mask: RS.Mask = (@as(RS.Mask, 1) << RS.M) - 1;
                const full_mask: RS.Mask = (@as(RS.Mask, 1) << (RS.K + RS.M)) - 1;
                const sources: RS.Mask = full_mask & ~erased_mask;

                RS.repair(&shards, shard_size, sources, erased_mask);
                for (0..RS.M) |i| {
                    try std.testing.expectEqualSlices(u8, &saved_multi[i], shards[i]);
                }
            }
        }
    };

    try RoundTrip.repairRoundTrip(1, 1);
    try RoundTrip.repairRoundTrip(2, 2);
    try RoundTrip.repairRoundTrip(12, 4);
    try RoundTrip.repairRoundTrip(17, 3);
    try RoundTrip.repairRoundTrip(24, 6);
}

test "fuzz: round-trips" {
    const pairs = .{ .{ 1, 1 }, .{ 4, 2 }, .{ 8, 4 }, .{ 12, 4 }, .{ 16, 6 }, .{ 24, 6 } };
    inline for (pairs) |pair| try std.testing.fuzz(pair, struct {
        fn run(p: @TypeOf(pair), smith: *std.testing.Smith) anyerror!void {
            @disableInstrumentation();
            const k: u8 = p[0];
            const m: u8 = p[1];
            const RS = CODEC(k, m);
            const shard_size: u32 = 1024;
            const km: usize = @as(usize, k) + m;

            var storage: [k + m][shard_size]u8 = undefined;
            var shards: [k + m][]u8 = undefined;
            for (&shards, &storage) |*s, *st| s.* = st;
            for (0..k) |i| smith.bytes(&storage[i]);

            const all_data: RS.Mask = (@as(RS.Mask, 1) << RS.K) - 1;
            const all_parity: RS.Mask = ((@as(RS.Mask, 1) << (RS.K + RS.M)) - 1) & ~all_data;
            const full: RS.Mask = (@as(RS.Mask, 1) << (RS.K + RS.M)) - 1;
            RS.repair(&shards, shard_size, all_data, all_parity);

            const Action = enum(u8) { erase_one, erase_many, refresh };
            while (!smith.eosWeightedSimple(15, 1)) {
                switch (smith.value(Action)) {
                    .erase_one => {
                        const i = smith.valueRangeAtMost(u8, 0, RS.K + RS.M - 1);
                        const bit: RS.Mask = @as(RS.Mask, 1) << @intCast(i);
                        var saved: [shard_size]u8 = undefined;
                        @memcpy(&saved, shards[i]);
                        @memset(shards[i], 0);
                        RS.repair(&shards, shard_size, full & ~bit, bit);
                        try std.testing.expectEqualSlices(u8, &saved, shards[i]);
                    },
                    .erase_many => {
                        if (RS.M < 2) continue;
                        const e = smith.valueRangeAtMost(u8, 2, RS.M);
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
                        var saved: [RS.K + RS.M][shard_size]u8 = undefined;
                        for (0..km) |i| {
                            const bit: RS.Mask = @as(RS.Mask, 1) << @intCast(i);
                            if (targets & bit != 0) {
                                @memcpy(&saved[i], shards[i]);
                                @memset(shards[i], 0);
                            }
                        }
                        RS.repair(&shards, shard_size, full & ~targets, targets);
                        for (0..km) |i| {
                            const bit: RS.Mask = @as(RS.Mask, 1) << @intCast(i);
                            if (targets & bit != 0) {
                                try std.testing.expectEqualSlices(u8, &saved[i], shards[i]);
                            }
                        }
                    },
                    .refresh => {
                        const i = smith.valueRangeAtMost(u8, 0, RS.K - 1);
                        smith.bytes(&storage[i]);
                        RS.repair(&shards, shard_size, all_data, all_parity);
                    },
                }
            }
        }
    }.run, .{});
}
