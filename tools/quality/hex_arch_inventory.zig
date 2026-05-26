const std = @import("std");
const cli_io = @import("../common/cli_io.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const max_file_bytes = 4 * 1024 * 1024;

const Options = struct {
    strict_root_files: bool = true,
};

const forbidden_adapter_root_tokens = [_][]const u8{
    "tool_handlers.zig",
    "tool_registry.zig",
    "tool_metadata.zig",
    "tool_manifest.zig",
    "zigar.tool_handlers",
    "zigar.tool_registry",
    "zigar.tool_metadata",
    "zigar.tool_manifest",
};

const final_root_allowlist = [_][]const u8{
    "src/main.zig",
    "src/root.zig",
};

const Inventory = struct {
    root_files: usize = 0,
    retired_tools_files: usize = 0,
    retired_tools_import_violations: usize = 0,
    adapter_root_import_violations: usize = 0,
    strict_root_violations: usize = 0,

    fn ok(self: Inventory) bool {
        return self.retired_tools_import_violations == 0 and
            self.adapter_root_import_violations == 0 and
            self.strict_root_violations == 0;
    }
};

pub fn run(allocator: Allocator, io: Io, args: []const []const u8) !void {
    const options = try parseOptions(io, args);
    const inventory = try scan(allocator, io, options);
    try printSummary(io, inventory, options);
    if (!inventory.ok()) return error.HexArchitectureInventoryFailed;
}

fn parseOptions(io: Io, args: []const []const u8) !Options {
    var options: Options = .{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--strict-root-files")) {
            options.strict_root_files = true;
        } else if (std.mem.eql(u8, arg, "--root-inventory-only")) {
            options.strict_root_files = false;
        } else {
            return cli_io.unexpectedArgument(io, "hex-architecture-inventory", arg, "hex-architecture-inventory [--strict-root-files|--root-inventory-only]");
        }
    }
    return options;
}

pub fn scan(allocator: Allocator, io: Io, options: Options) !Inventory {
    var inventory: Inventory = .{};
    try scanSrcTree(allocator, io, options, &inventory);
    return inventory;
}

fn scanSrcTree(allocator: Allocator, io: Io, options: Options, inventory: *Inventory) !void {
    var dir = Io.Dir.cwd().openDir(io, "src", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const source_path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(source_path);

        if (isRootFile(source_path)) {
            inventory.root_files += 1;
            if (options.strict_root_files and !containsPath(&final_root_allowlist, source_path)) {
                try cli_io.stderrPrint(io, "hex architecture inventory: root Zig file remains outside final allowlist: {s}\n", .{source_path});
                inventory.strict_root_violations += 1;
            }
        }
        if (std.mem.startsWith(u8, source_path, "src/tools/")) inventory.retired_tools_files += 1;

        const bytes = try cli_io.readFileAlloc(allocator, io, source_path, max_file_bytes);
        defer allocator.free(bytes);
        try checkRetiredToolsImport(io, source_path, bytes, inventory);
        try checkAdapterRootImports(io, source_path, bytes, inventory);
    }
}

fn checkRetiredToolsImport(io: Io, source_path: []const u8, bytes: []const u8, inventory: *Inventory) !void {
    if (std.mem.indexOf(u8, bytes, "@import(\"tools/") == null) return;
    if (std.mem.startsWith(u8, source_path, "src/adapters/mcp/")) return;
    if (std.mem.startsWith(u8, source_path, "src/tools/")) return;
    try cli_io.stderrPrint(io, "hex architecture inventory: retired src/tools import outside MCP adapter: {s}\n", .{source_path});
    inventory.retired_tools_import_violations += 1;
}

fn checkAdapterRootImports(io: Io, source_path: []const u8, bytes: []const u8, inventory: *Inventory) !void {
    if (!std.mem.startsWith(u8, source_path, "src/adapters/mcp/")) return;
    if (std.mem.startsWith(u8, source_path, "src/adapters/mcp/server.zig")) return;
    if (std.mem.startsWith(u8, source_path, "src/adapters/mcp/server/")) return;
    for (forbidden_adapter_root_tokens) |token| {
        if (std.mem.indexOf(u8, bytes, token)) |_| {
            try cli_io.stderrPrint(io, "hex architecture inventory: MCP adapter imports retired root `{s}` in {s}\n", .{ token, source_path });
            inventory.adapter_root_import_violations += 1;
        }
    }
}

fn printSummary(io: Io, inventory: Inventory, options: Options) !void {
    var buffer: [1024]u8 = undefined;
    var writer = Io.File.stdout().writer(io, &buffer);
    try writer.interface.print(
        "hex architecture inventory: root_files={d} retired_src_tools_files={d} retired_tools_import_violations={d} adapter_root_import_violations={d}",
        .{
            inventory.root_files,
            inventory.retired_tools_files,
            inventory.retired_tools_import_violations,
            inventory.adapter_root_import_violations,
        },
    );
    if (options.strict_root_files) {
        try writer.interface.print(" strict_root_violations={d}", .{inventory.strict_root_violations});
    }
    try writer.interface.writeAll("\n");
    try writer.interface.flush();
}

fn isRootFile(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "src/")) return false;
    const rest = path["src/".len..];
    return std.mem.indexOfScalar(u8, rest, '/') == null;
}

fn containsPath(comptime paths: []const []const u8, path: []const u8) bool {
    for (paths) |candidate| {
        if (std.mem.eql(u8, candidate, path)) return true;
    }
    return false;
}

test "root file classification is depth one under src" {
    try std.testing.expect(isRootFile("src/main.zig"));
    try std.testing.expect(!isRootFile("src/adapters/mcp/root.zig"));
}

test "root strictness defaults to fail closed" {
    const options: Options = .{};
    try std.testing.expect(options.strict_root_files);
    try std.testing.expect(containsPath(&final_root_allowlist, "src/main.zig"));
    try std.testing.expect(!containsPath(&final_root_allowlist, "src/backend_catalog.zig"));
}
