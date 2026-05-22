const std = @import("std");
const cli_io = @import("cli_io.zig");
const mcp_contracts = @import("mcp_contracts.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub fn run(allocator: Allocator, io: Io, args: []const []const u8) !void {
    if (args.len != 0) return error.InvalidArguments;
    if (!(try checkAll(allocator, io))) return error.PublicContractsFailed;
    try cli_io.stdoutWrite(io, "public contracts ok\n");
}

pub fn checkAll(allocator: Allocator, io: Io) !bool {
    var ok = true;
    ok = (try mcp_contracts.checkNoPatchContract(allocator, io)) and ok;
    ok = (try mcp_contracts.checkAdvertisedCapabilityContract(allocator, io)) and ok;
    ok = (try mcp_contracts.checkPublicSurfaceContract(allocator, io)) and ok;
    return ok;
}
