const std = @import("std");
const math_alias = @import("math.zig");
const nested_alias = @import("dep/nested.zig");
const fake_text = "@import(\"fake.zig\")";
// const commented = @import("commented.zig");

pub const Outer = struct {
    pub const Inner = struct {
        pub const nested_import = @import("nested.zig");

        pub fn nested(comptime T: type, value: T) T {
            return value;
        }

        test "nested \"escaped\" text" {}
    };

    pub const Namespace = struct {
        pub const ReExported = error{ Missing, Invalid };
    };

    pub fn generic(comptime T: type, value: T) !T {
        return value;
    }
};

const LocalErrors = error{ NotFound, Busy };

fn inferredFailure(flag: bool) !void {
    if (flag) return error.NotFound;
}

fn explicitFailure() LocalErrors!void {
    return error.Busy;
}

comptime {
    const Generated = struct {
        pub fn run() void {}
    };
    _ = Generated;
}

const named = struct {};

test "outer works" {}
test "escaped \"quote\" text" {}
test named {}
