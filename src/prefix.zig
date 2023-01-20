const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const testing = std.testing;
const Signedness = std.builtin.Signedness;

const addr = @import("./addr.zig");
const Ip4Addr = addr.Ip4Addr;
const Ip6Addr = addr.Ip6Addr;

/// Inclusion relationship between 2 prefixes A and B
/// (sets of IP addresses they define)
pub const Inclusion = enum {
    /// A is a proper subset of B
    sub,
    /// A is equal to B
    eq,
    /// A is a proper superset of B
    super,
    /// A and B are not related
    none,
};

/// A Prefix type constructor from the corresponding Addr type
pub fn PrefixForAddrType(comptime T: type) type {
    if (T != Ip4Addr and T != Ip6Addr) {
        @compileError("unknown address type '" ++ @typeName(T) ++ "' (only v4 and v6 addresses are supported)");
    }

    const pos_bits = @typeInfo(T.PositionType).Int.bits;

    return packed struct {
        const Self = @This();
        const V = T.ValueType;

        // we need an extra bit to represent the widest mask, e.g. /32 for the v4 address
        /// The type of the bits mask
        pub const MaskBitsType = std.meta.Int(Signedness.unsigned, pos_bits + 1);
        /// The type of wrapped address.
        pub const AddrType = T;
        /// Max allowed bit mask
        pub const maxMaskBits = 1 << pos_bits;

        // that includes the Overflow and InvalidCharacter
        pub const ParseError = error{NoBitMask} || T.ParseError;

        addr: T,
        mask_bits: MaskBitsType,

        /// Create a prefix from the given address and the number of bits.
        /// Following the go's netip implementation, we don't zero bits not
        /// covered by the mask.
        /// The mask bits size must be <= address specific maxMaskBits.
        pub inline fn init(a: T, bits: MaskBitsType) !Self {
            if (bits > maxMaskBits) {
                return error.Overflow;
            }
            return safeInit(a, bits);
        }

        inline fn safeInit(a: T, bits: MaskBitsType) Self {
            return Self{ .addr = a, .mask_bits = bits };
        }

        /// Create a new prefix with the same bit mask size as
        /// the given example prefix.
        pub inline fn initAnother(a: T, example: Self) Self {
            return safeInit(a, example.mask_bits);
        }

        /// Parse the prefix from the string representation
        pub fn parse(s: []const u8) ParseError!Self {
            if (mem.indexOfScalar(u8, s, '/')) |i| {
                if (i == s.len - 1) return ParseError.NoBitMask;

                const parsed = try T.parse(s[0..i]);

                var bits: MaskBitsType = 0;
                for (s[i + 1 ..]) |c| {
                    switch (c) {
                        '0'...'9' => {
                            bits = math.mul(MaskBitsType, bits, 10) catch return ParseError.Overflow;
                            bits = math.add(MaskBitsType, bits, @truncate(MaskBitsType, c - '0')) catch return ParseError.Overflow;
                        },
                        else => return ParseError.InvalidCharacter,
                    }
                }

                if (bits > maxMaskBits) return ParseError.Overflow;

                return init(parsed, bits);
            }

            return ParseError.NoBitMask;
        }

        /// Returns underlying address.
        pub inline fn addr(self: Self) T {
            return self.addr;
        }

        /// Returns the number of bits in the mask
        pub inline fn maskBits(self: Self) MaskBitsType {
            return self.mask_bits;
        }

        inline fn mask(self: Self) V {
            // shrExact doesn't work because mask_bits has 1 extra bit
            return ~math.shr(V, ~@as(V, 0), self.mask_bits);
        }

        /// Return the first and the last addresses in the prefix
        pub inline fn addrRange(self: Self) [2]T {
            const first = self.addr.value() & self.mask();
            const last = first | ~self.mask();

            return [2]T{ T.init(first), T.init(last) };
        }

        /// Return the canonical representation of the prefix
        /// with all insignificant bits set to 0 (bits not covered by the mask).
        pub inline fn canonical(self: Self) Self {
            return Self{ .addr = T.init(self.addr.value() & self.mask()), .mask_bits = self.mask_bits };
        }

        /// Print the address. The modifier is passed to either Ip4Addr or Ip6Addr unchanged,
        /// however it can be prepended with the optional 'R' modifier that uses the IP range
        /// format instead of the standard cidr prefix format.
        pub fn format(
            self: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            out_stream: anytype,
        ) !void {
            _ = options;

            if (fmt.len > 0 and fmt[0] == 'R') {
                const fmt_trunc = "{" ++ fmt[1..] ++ "}";
                const fmt_r = fmt_trunc ++ "-" ++ fmt_trunc;
                const r = self.addrRange();
                try std.fmt.format(out_stream, fmt_r, .{ r[0], r[1] });
            } else {
                try std.fmt.format(out_stream, "{" ++ fmt ++ "}" ++ "/{}", .{ self.addr, self.mask_bits });
            }
        }

        /// Test the inclusion relationship between two prefixes.
        pub inline fn testInclusion(self: Self, other: Self) Inclusion {
            const common_mask = @min(self.mask_bits, other.mask_bits);
            const related = math.shr(V, self.addr.value() ^ other.addr.value(), maxMaskBits - common_mask) == 0;
            if (!related) {
                return Inclusion.none;
            }

            return switch (math.order(self.mask_bits, other.mask_bits)) {
                .lt => Inclusion.super,
                .eq => Inclusion.eq,
                .gt => Inclusion.sub,
            };
        }

        /// Test if the address is within the range defined by the prefix.
        pub inline fn containsAddr(self: Self, a: T) bool {
            return math.shr(V, self.addr.value() ^ a.value(), maxMaskBits - self.mask_bits) == 0;
        }

        /// Two prefixes overlap if they are in the inclusion relationship
        pub inline fn overlaps(self: Self, other: Self) bool {
            return self.testInclusion(other) != Inclusion.none;
        }

        /// Convert between IPv4 and IPv6 prefixes
        /// Use '::ffff:0:0/96' for IPv4 mapped addresses.
        pub inline fn as(self: Self, comptime O: type) ?O {
            if (Self == O) {
                return self;
            }

            return switch (O.AddrType) {
                Ip6Addr => O.safeInit(self.addr.as(Ip6Addr).?, O.maxMaskBits - maxMaskBits + @as(O.MaskBitsType, self.mask_bits)),
                Ip4Addr => if (self.addr.as(Ip4Addr)) |a|
                    O.safeInit(a, @truncate(O.MaskBitsType, self.mask_bits - (maxMaskBits - O.maxMaskBits)))
                else
                    null,
                else => @compileError("unsupported prefix conversion from '" ++ @typeName(Self) ++ "' to '" ++ @typeName(O) + "'"),
            };
        }
    };
}

pub const Ip4Prefix = PrefixForAddrType(Ip4Addr);
pub const Ip6Prefix = PrefixForAddrType(Ip6Addr);

pub const PrefixType = enum {
    v4,
    v6,
};

/// A union that allows to work with both prefix types.
/// Only high-level operations are supported. Unwrap the concrete
/// prefix type to do any sort of low-level or bit operations.
pub const Prefix = union(PrefixType) {
    v4: Ip4Prefix,
    v6: Ip6Prefix,

    pub fn fromIp4Prefix(p: Ip4Prefix) Prefix {
        return Prefix{ .v4 = p };
    }

    pub fn fromIp6Prefix(p: Ip6Prefix) Prefix {
        return Prefix{ .v6 = p };
    }
};

test "Prefix/trivial init" {
    const addr4 = Ip4Addr.init(1);
    const addr6 = Ip6Addr.init(2);
    const addr6_1 = Ip6Addr.init(3);

    try testing.expectEqual(Ip4Prefix{ .addr = addr4, .mask_bits = 3 }, try Ip4Prefix.init(addr4, 3));
    try testing.expectEqual(Ip6Prefix{ .addr = addr6, .mask_bits = 3 }, try Ip6Prefix.init(addr6, 3));

    const prefix = try Ip6Prefix.init(addr6, 32);
    try testing.expectEqual(Ip6Prefix{ .addr = addr6_1, .mask_bits = 32 }, Ip6Prefix.initAnother(addr6_1, prefix));

    try testing.expectError(error.Overflow, Ip4Prefix.init(addr4, 33));
    try testing.expectError(error.Overflow, Ip6Prefix.init(addr6, 129));

    try testing.expectEqual(u6, Ip4Prefix.MaskBitsType);
    try testing.expectEqual(u8, Ip6Prefix.MaskBitsType);
}

test "Prefix/parse4" {
    try testing.expectEqual(
        Ip4Prefix{ .addr = Ip4Addr.fromArray(u8, [_]u8{ 192, 0, 2, 1 }), .mask_bits = 24 },
        try Ip4Prefix.parse("192.0.2.1/24"),
    );

    try testing.expectEqual(
        Ip4Prefix{ .addr = Ip4Addr.fromArray(u8, [_]u8{ 192, 0, 2, 1 }), .mask_bits = 0 },
        try Ip4Prefix.parse("192.0.2.1/0"),
    );

    try testing.expectEqual(
        Ip4Prefix{ .addr = Ip4Addr.fromArray(u8, [_]u8{ 192, 0, 2, 1 }), .mask_bits = 32 },
        try Ip4Prefix.parse("192.0.2.1/32"),
    );

    try testing.expectError(Ip4Prefix.ParseError.NotEnoughOctets, Ip4Prefix.parse("192.0.2/24"));
    try testing.expectError(Ip4Prefix.ParseError.NoBitMask, Ip4Prefix.parse("192.0.2/"));
    try testing.expectError(Ip4Prefix.ParseError.NoBitMask, Ip4Prefix.parse("192.0.2"));
    try testing.expectError(Ip4Prefix.ParseError.Overflow, Ip4Prefix.parse("192.0.2.1/33"));
    try testing.expectError(Ip4Prefix.ParseError.InvalidCharacter, Ip4Prefix.parse("192.0.2.1/test"));
    try testing.expectError(Ip4Prefix.ParseError.InvalidCharacter, Ip4Prefix.parse("192.0.2.1/-1"));
}

test "Prefix/parse6" {
    try testing.expectEqual(
        Ip6Prefix{ .addr = Ip6Addr.fromArray(u16, [_]u16{ 0x2001, 0xdb8, 0, 0, 0, 0, 0, 0x1 }), .mask_bits = 96 },
        try Ip6Prefix.parse("2001:db8::1/96"),
    );

    try testing.expectEqual(
        Ip6Prefix{ .addr = Ip6Addr.fromArray(u16, [_]u16{ 0x2001, 0xdb8, 0, 0, 0, 0, 0, 0x1 }), .mask_bits = 0 },
        try Ip6Prefix.parse("2001:db8::1/0"),
    );

    try testing.expectEqual(
        Ip6Prefix{ .addr = Ip6Addr.fromArray(u16, [_]u16{ 0x2001, 0xdb8, 0, 0, 0, 0, 0, 0x1 }), .mask_bits = 128 },
        try Ip6Prefix.parse("2001:db8::1/128"),
    );

    try testing.expectError(Ip6Prefix.ParseError.NotEnoughSegments, Ip6Prefix.parse("2001:db8:1/24"));
    try testing.expectError(Ip6Prefix.ParseError.NoBitMask, Ip6Prefix.parse("2001:db8::1/"));
    try testing.expectError(Ip6Prefix.ParseError.NoBitMask, Ip6Prefix.parse("2001:db8::1"));
    try testing.expectError(Ip6Prefix.ParseError.Overflow, Ip6Prefix.parse("2001:db8::1/129"));
    try testing.expectError(Ip6Prefix.ParseError.InvalidCharacter, Ip6Prefix.parse("2001:db8::1/test"));
    try testing.expectError(Ip6Prefix.ParseError.InvalidCharacter, Ip6Prefix.parse("2001:db8::1/-1"));
}

test "Prefix/canonicalize" {
    try testing.expectEqual(try Ip6Prefix.parse("2001:db8::/48"), (try Ip6Prefix.parse("2001:db8::403:201/48")).canonical());
    try testing.expectEqual(try Ip6Prefix.parse("2001:0db8:8000::/33"), (try Ip6Prefix.parse("2001:db8:85a3::8a2e:370:7334/33")).canonical());
    try testing.expectEqual(try Ip4Prefix.parse("192.0.2.0/24"), (try Ip4Prefix.parse("192.0.2.48/24")).canonical());
    try testing.expectEqual(try Ip4Prefix.parse("37.224.0.0/11"), (try Ip4Prefix.parse("37.228.215.135/11")).canonical());
}

test "Prefix/addrRange" {
    try testing.expectEqual(
        [2]Ip6Addr{
            try Ip6Addr.parse("2001:0db8:85a3:0000:0000:0000:0000:0000"),
            try Ip6Addr.parse("2001:0db8:85a3:001f:ffff:ffff:ffff:ffff"),
        },
        (try Ip6Prefix.parse("2001:db8:85a3::8a2e:370:7334/59")).addrRange(),
    );

    try testing.expectEqual(
        [2]Ip4Addr{
            try Ip4Addr.parse("37.228.214.0"),
            try Ip4Addr.parse("37.228.215.255"),
        },
        (try Ip4Prefix.parse("37.228.215.135/23")).addrRange(),
    );
}

test "Prefix/format" {
    const prefix4 = "192.0.2.16/24";
    const prefix6 = "2001:0db8:85a3::1/96";

    try testing.expectFmt("192.0.2.16/24", "{}", .{try Ip4Prefix.parse(prefix4)});
    try testing.expectFmt("c0.0.2.10/24", "{x}", .{try Ip4Prefix.parse(prefix4)});
    try testing.expectFmt("192.0.2.0-192.0.2.255", "{R}", .{try Ip4Prefix.parse(prefix4)});
    try testing.expectFmt("c0.00.02.00-c0.00.02.ff", "{RX}", .{try Ip4Prefix.parse(prefix4)});

    try testing.expectFmt("2001:db8:85a3::1/96", "{}", .{try Ip6Prefix.parse(prefix6)});
    try testing.expectFmt("2001:0db8:85a3::0001/96", "{X}", .{try Ip6Prefix.parse(prefix6)});
    try testing.expectFmt("2001:db8:85a3::-2001:db8:85a3::ffff:ffff", "{R}", .{try Ip6Prefix.parse(prefix6)});
    try testing.expectFmt("2001:db8:85a3:0:0:0:0:0-2001:db8:85a3:0:0:0:ffff:ffff", "{RE}", .{try Ip6Prefix.parse(prefix6)});
}

test "Prefix/contansAddress" {
    try testing.expect((try Ip4Prefix.parse("10.11.12.13/0")).containsAddr(try Ip4Addr.parse("192.168.1.1")));
    try testing.expect((try Ip4Prefix.parse("10.11.12.13/8")).containsAddr(try Ip4Addr.parse("10.6.3.5")));
    try testing.expect((try Ip4Prefix.parse("10.11.12.13/32")).containsAddr(try Ip4Addr.parse("10.11.12.13")));
    try testing.expect(!(try Ip4Prefix.parse("192.0.2.0/25")).containsAddr(try Ip4Addr.parse("192.0.2.192")));

    try testing.expect((try Ip6Prefix.parse("2001:db8::/0")).containsAddr(try Ip6Addr.parse("3001:db8::1")));
    try testing.expect((try Ip6Prefix.parse("2001:db8::/8")).containsAddr(try Ip6Addr.parse("2002:db8::1")));
    try testing.expect((try Ip6Prefix.parse("2001:db8::/16")).containsAddr(try Ip6Addr.parse("2001:db8::2")));
    try testing.expect(!(try Ip6Prefix.parse("2001:db8::cafe:0/112")).containsAddr(try Ip6Addr.parse("2001:db8::beef:7")));
}

test "Prefix/inclusion" {
    const prefixes4 = [_]Ip4Prefix{
        try Ip4Prefix.parse("10.11.12.13/0"),
        try Ip4Prefix.parse("10.11.12.13/3"),
        try Ip4Prefix.parse("10.11.12.13/24"),
        try Ip4Prefix.parse("10.11.12.13/31"),
        try Ip4Prefix.parse("10.11.12.13/32"),
    };

    for (prefixes4) |p, i| {
        try testing.expectEqual(Inclusion.eq, p.testInclusion(p));
        try testing.expect(p.overlaps(p));
        for (prefixes4[0..i]) |prev| {
            try testing.expectEqual(Inclusion.sub, p.testInclusion(prev));
            try testing.expect(p.overlaps(prev));
        }
        if (i == prefixes4.len - 1) continue;
        for (prefixes4[i + 1 ..]) |next| {
            try testing.expectEqual(Inclusion.super, p.testInclusion(next));
            try testing.expect(p.overlaps(next));
        }
    }

    try testing.expectEqual(Inclusion.none, (try Ip4Prefix.parse("192.168.73.0/24")).testInclusion(try Ip4Prefix.parse("192.168.74.0/24")));
    try testing.expect(!(try Ip4Prefix.parse("192.168.73.0/24")).overlaps(try Ip4Prefix.parse("192.168.74.0/24")));

    const prefixes6 = [_]Ip6Prefix{
        try Ip6Prefix.parse("2001:db8:cafe::1/0"),
        try Ip6Prefix.parse("2001:db8:cafe::1/3"),
        try Ip6Prefix.parse("2001:db8:cafe::1/32"),
        try Ip6Prefix.parse("2001:db8:cafe::1/127"),
        try Ip6Prefix.parse("2001:db8:cafe::1/128"),
    };

    for (prefixes6) |p, i| {
        try testing.expectEqual(Inclusion.eq, p.testInclusion(p));
        try testing.expect(p.overlaps(p));
        for (prefixes6[0..i]) |prev| {
            try testing.expectEqual(Inclusion.sub, p.testInclusion(prev));
            try testing.expect(p.overlaps(prev));
        }
        if (i == prefixes6.len - 1) continue;
        for (prefixes6[i + 1 ..]) |next| {
            try testing.expectEqual(Inclusion.super, p.testInclusion(next));
            try testing.expect(p.overlaps(next));
        }
    }

    try testing.expectEqual(Inclusion.none, (try Ip6Prefix.parse("2001:db8:cafe::1/48")).testInclusion(try Ip6Prefix.parse("2001:db8:beef::1/48")));
    try testing.expect(!(try Ip6Prefix.parse("2001:db8:cafe::1/48")).overlaps(try Ip6Prefix.parse("2001:db8:beef::1/48")));
}

test "Prefix/conversion" {
    try testing.expectEqual(try Ip6Prefix.parse("::ffff:0a0b:0c0d/112"), (try Ip4Prefix.parse("10.11.12.13/16")).as(Ip6Prefix).?);
    try testing.expectEqual(try Ip6Prefix.parse("::ffff:0a0b:0c0d/128"), (try Ip4Prefix.parse("10.11.12.13/32")).as(Ip6Prefix).?);
    try testing.expectEqual(try Ip4Prefix.parse("10.11.12.13/16"), (try Ip6Prefix.parse("::ffff:0a0b:0c0d/112")).as(Ip4Prefix).?);
    try testing.expectEqual(try Ip4Prefix.parse("10.11.12.13/32"), (try Ip6Prefix.parse("::ffff:0a0b:0c0d/128")).as(Ip4Prefix).?);
    try testing.expect(null == (try Ip6Prefix.parse("2001::ffff:0a0b:0c0d/48")).as(Ip4Prefix));
}
