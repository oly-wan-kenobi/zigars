//! Aggregate public-contracts release gate.
//! Runs the three MCP contract groups — no-patch, advertised capability, and
//! public surface — and is the entry point for `zig-tools public-contracts`.
const std = @import("std");
const cli_io = @import("../common/cli_io.zig");
const mcp_contracts = @import("mcp_contracts.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// CLI entry point; accepts no arguments.
/// Returns `error.PublicContractsFailed` if any contract check fails.
pub fn run(allocator: Allocator, io: Io, args: []const []const u8) !void {
    if (args.len != 0) return error.InvalidArguments;
    if (!(try checkAll(allocator, io))) return error.PublicContractsFailed;
    try cli_io.stdoutWrite(io, "public contracts ok\n");
}

/// Runs all three MCP contract groups and returns `true` only when all pass.
/// Failures in individual groups are reported to stderr by the group checks;
/// this function accumulates their `bool` results without short-circuiting.
pub fn checkAll(allocator: Allocator, io: Io) !bool {
    var ok = true;
    ok = (try mcp_contracts.checkNoPatchContract(allocator, io)) and ok;
    ok = (try mcp_contracts.checkAdvertisedCapabilityContract(allocator, io)) and ok;
    ok = (try mcp_contracts.checkPublicSurfaceContract(allocator, io)) and ok;
    return ok;
}

test "public contracts command exposes aggregate check entrypoint" {
    try std.testing.expect(@hasDecl(@This(), "checkAll"));
}
