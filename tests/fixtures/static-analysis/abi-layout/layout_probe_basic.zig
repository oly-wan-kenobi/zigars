pub const Header = extern struct {
    tag: u8,
    payload: u64,
};

pub const PackedBits = packed struct {
    a: u3,
    b: u5,
    c: u8,
};

pub const Payload = extern union {
    integer: u32,
    pointer: ?*anyopaque,
};

pub const WireTag = enum(u16) {
    ok = 1,
    fail = 2,
};

pub const SentinelPointer = extern struct {
    name: [*:0]const u8,
    len: usize,
};

pub const ExplicitAlignment = extern struct {
    small: u8,
    aligned: u32 align(16),
};

pub const Padding = extern struct {
    first: u8,
    second: u32,
    third: u16,
};
