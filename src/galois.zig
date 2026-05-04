const std = @import("std");
const assert = std.debug.assert;

/// Factory for a precomputed GF(2^W) instance. `Field(w)` returns a struct type
/// whose value holds the log/exp tables for a chosen primitive polynomial,
/// plus a couple of Cauchy-specific heuristic tables (`bit`, `min`) that strictly
/// speaking don't belong here — keeping them for now to keep the migration
/// small; they can move into a `cauchy_heuristic.zig` later.
///
/// Usage:
///
///     const GF = galois.Field(8);
///     const t = comptime GF.init(29);
///     const v = t.multiply(0x53, 0xCA);   // u8
///     const w = t.divide(1, 0x42);
pub fn Field(comptime w: u4) type {
    return struct {
        /// GF(2^W) — exponent of the field size
        pub const W: u4 = w;
        /// Number of field elements
        pub const SIZE: u16 = 1 << w;
        /// Order of the multiplicative group (2^W − 1): 3 / 15 / 255.
        pub const ORDER: u16 = SIZE - 1;

        /// Standard primitive (irreducible) polynomials of degree W over GF(2).
        /// The Cauchy density optimizer searches all of them per (k, m) and
        /// keeps the one yielding the lowest 1-bit count in the bitmatrix.
        /// Stored as `u16` because the conventional "include implicit x^W bit"
        /// form (e.g. 7 for GF(4)) doesn't always fit in `Element`.
        pub const primitives: []const u16 = switch (w) {
            2 => &.{7},
            4 => &.{19}, // TODO: GF(16) has a second primitive (25 = x^4+x^3+1)
            8 => &.{ 29, 43, 45, 77, 95, 99, 101, 105, 113, 135, 141, 169, 195, 207, 231, 245 },
            else => @compileError("`w` must be a power of two less than or equal to 8"),
        };

        /// `log[a]` = `i` such that `g^i = a`, where `g = 2` is the generator.
        /// `log[0]` is poisoned with `ORDER` since the log of zero is undefined.
        log: [SIZE]u8 = undefined,
        /// `exp[i] = g^i mod p(x)`. `exp[ORDER]` is poisoned with 0.
        exp: [SIZE]u8 = undefined,

        /// `bit[a]` = popcount of `a`'s "multiply-by-a" operator expressed as a
        /// W×W GF(2) matrix (row `i` = binary of `a · 2^i`). Drives the Cauchy
        /// row-density minimizer. Cauchy-specific, not core GF math — flagged
        /// for future relocation. Max value w² = 64, so a `u8` is plenty.
        bit: [SIZE]u8 = undefined,
        /// Field elements sorted ascending by `bit`, with index as tiebreak.
        /// `min[i]` = the i-th sparsest element. Used by the m=2 fast path
        /// in `createMatrix` to pick low-density column multipliers.
        min: [SIZE]u8 = undefined,

        /// Compute the tables for `primitive`. Designed for comptime use:
        ///
        ///     const t = comptime Field(8).init(29);
        pub fn init(primitive: u16) @This() {
            @setEvalBranchQuota(1024 * 1024);
            var self: @This() = undefined;

            // log/exp via repeated doubling. log[0] / exp[ORDER] left poisoned.
            for (&self.log) |*v| v.* = @intCast(ORDER);
            for (&self.exp) |*v| v.* = 0;

            var b: u16 = 1;
            for (0..ORDER) |a| {
                self.log[b] = @intCast(a);
                self.exp[a] = @intCast(b);
                b <<= 1;
                if (b & SIZE != 0) b = (b ^ primitive) & ORDER;
            }

            // bit table: depends on multiply, which depends on log/exp built above.
            for (0..SIZE) |a| self.bit[a] = self.matrixWeight(@intCast(a));

            // min table: stable selection-sort over (bit, index).
            // TODO: can this be replaced with a stable sort from the stdlib?
            self.min[0] = 0;
            for (1..SIZE) |i| {
                const prev = self.min[i - 1];
                var best: ?u8 = null;
                for (1..SIZE) |a| {
                    if (self.bit[a] < self.bit[prev]) continue;
                    if (self.bit[a] == self.bit[prev] and a <= prev) continue;
                    if (best == null or self.bit[a] < self.bit[best.?]) best = @intCast(a);
                }
                self.min[i] = best.?;
            }

            return self;
        }

        pub fn multiply(self: *const @This(), a: u8, b: u8) u8 {
            assert(a <= ORDER);
            assert(b <= ORDER);
            if (a == 0 or b == 0) return 0;
            const sum: u16 = @as(u16, self.log[a]) + self.log[b];
            return @intCast(self.exp[sum % ORDER]);
        }

        pub fn divide(self: *const @This(), a: u8, b: u8) u8 {
            assert(a <= ORDER);
            assert(b <= ORDER);
            assert(b != 0);
            if (a == 0) return 0;
            const diff: u16 = @as(u16, self.log[a]) + ORDER - self.log[b];
            return @intCast(self.exp[diff % ORDER]);
        }

        /// Popcount of `a`'s multiplication-by-a operator viewed as a W×W GF(2)
        /// matrix. Sums the bit count of `a · 2^i` across `i ∈ [0, W)`. This is
        /// the per-element contribution to the encoding bitmatrix's 1-bit total
        /// — minimizing it (across the Cauchy matrix) is the optimization goal.
        pub fn matrixWeight(self: *const @This(), a: u8) u8 {
            assert(a <= ORDER);
            var count: u8 = 0;
            var n: u8 = a;
            for (0..W) |_| {
                count += @popCount(n);
                n = self.multiply(n, 2);
            }
            return count;
        }

        /// Creates a maximum distance separable Cauchy matrix for this field.
        ///
        /// Shape is a k×m over elements of GF(2^W), row-major.
        ///
        /// Row 0 is normalized to all 1s; subsequent rows are divided by the
        /// column whose multiplier minimizes the row's bit count. Returns the
        /// total popcount over the implied bitmatrix expansion, which is our
        /// optimization objective for minimizing XOR operations.
        ///
        /// Calling convention:
        /// - `matrix` must be exactly k*m elements (bytes) long.
        /// - `m == 1`: x and y must be null. Matrix is the all-ones row.
        /// - `m == 2`: x and y must be null. Row 1 is `min[1..k+1]`.
        /// - `m >  2`: x and y must be set, with `x ≠ y`, `x + k ≤ SIZE`,
        ///   `y + m ≤ SIZE`, and the [x, x+k) / [y, y+m) ranges disjoint.
        pub fn cauchy(self: *const @This(), k: u8, m: u8, x: ?u8, y: ?u8, matrix: []u8) u32 {
            assert(k >= 1 and m >= 1);
            assert(@as(u16, k) + m <= SIZE);
            assert(matrix.len == @as(usize, k) * m);

            // Row 0 is always all-1s; contributes k * bit[1] to the total.
            var count: u32 = @as(u32, self.bit[1]) * k;

            if (m == 1) {
                assert(x == null and y == null);
                for (0..k) |c| matrix[c] = 1;
                assert(count > 0);
                return count;
            }

            if (m == 2) {
                assert(x == null and y == null);
                for (0..k) |c| matrix[c] = 1;
                for (0..k) |c| {
                    matrix[k + c] = self.min[c + 1];
                    assert(matrix[k + c] > 0);
                    count += self.bit[matrix[k + c]];
                }
                assert(count > 0);
                return count;
            }

            const xv = x.?;
            const yv = y.?;
            assert(@as(u16, xv) + k <= SIZE);
            assert(@as(u16, yv) + m <= SIZE);
            assert(xv != yv);
            if (xv < yv) assert(@as(u16, xv) + k <= yv) else assert(@as(u16, yv) + m <= xv);

            // Raw Cauchy: matrix[r,c] = 1 / ((y+r) ^ (x+c)).
            for (0..m) |r| for (0..k) |c| {
                const yr: u8 = @intCast(@as(u16, yv) + r);
                const xc: u8 = @intCast(@as(u16, xv) + c);
                matrix[r * k + c] = self.divide(1, yr ^ xc);
            };

            // Normalize each row by its column 0.
            for (1..m) |r| for (0..k) |c| {
                matrix[r * k + c] = self.divide(matrix[r * k + c], matrix[c]);
            };

            // Set row 0 to all 1s by self-dividing.
            for (0..k) |c| {
                matrix[c] = self.divide(matrix[c], matrix[c]);
                assert(matrix[c] == 1);
            }

            // For each non-zero row, find the column whose value yields the
            // lowest total bit count when divided into the row, and apply it.
            for (1..m) |r| {
                const rk = @as(usize, r) * k;
                var result: u32 = 0;
                for (0..k) |c| result += self.bit[matrix[rk + c]];

                var best: ?u8 = null;
                for (0..k) |c| {
                    var bits: u32 = 0;
                    for (0..k) |d| {
                        bits += self.bit[self.divide(matrix[rk + d], matrix[rk + c])];
                    }
                    if (bits < result) {
                        result = bits;
                        best = matrix[rk + c];
                    }
                }
                if (best) |col| for (0..k) |c| {
                    matrix[rk + c] = self.divide(matrix[rk + c], col);
                };
                count += result;
            }

            for (0..k) |c| assert(matrix[c] == 1);
            assert(count > 0);
            return count;
        }
    };
}

test "Field: multiply/divide round-trip" {
    @setEvalBranchQuota(16 * 1024 * 1024);
    inline for (.{ 2, 4, 8 }) |w| {
        const GF = Field(w);
        inline for (GF.primitives) |p| {
            const t = comptime GF.init(p);
            for (1..GF.SIZE) |a| {
                const ai: u8 = @intCast(a);
                const inv = t.divide(1, ai);
                try std.testing.expectEqual(@as(u8, 1), t.multiply(ai, inv));
            }
        }
    }
}

test "Field: log/exp consistency" {
    const GF = Field(8);
    const t = comptime GF.init(29);
    for (1..GF.SIZE) |a| {
        const ai: u8 = @intCast(a);
        try std.testing.expectEqual(ai, t.exp[t.log[ai]]);
    }
}
