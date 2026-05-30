//! Fake optional-backend fixtures used by release-gate conformance checks.
//! Each function simulates one real external tool (zwanzig, ZLint, zflame,
//! diff-folded) closely enough to exercise the argument contract without
//! requiring the real tool to be installed.  Errors and diagnostic messages
//! go to stderr; successful output goes to stdout.
const std = @import("std");
const zigars = @import("zigars");

const Io = std.Io;
const backend_contracts = zigars.domain.zig.backend_contracts;

/// Simulates zwanzig for conformance testing.  Supports `--help`, graph-dump
/// modes (`--dump-cfg`, `--dump-exploded-graph`, etc.), and lint modes
/// (`--format json|sarif`).  Rejects the stale `--dot` flag and mix-ups
/// between graph and lint invocation forms.  Returns `error.InvalidArguments`
/// for bad usage; caller does not own any allocations from this function.
pub fn fakeZwanzig(io: Io, args: []const []const u8) !void {
    if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) {
        try stdoutWrite(io, "fake zwanzig help\n--format json|sarif\n--dump-cfg <dir> <file>\n--dump-exploded-graph <dir> <file>\n--dump-annotated-cfg <dir> <file>\n--dump-path-trace <dir> <file>\n");
        return;
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "--dot")) return fakeBackendUsageError(io, "fake zwanzig rejected stale --dot graph flag\n");
    if (args.len > 0 and zwanzigGraphModeName(args[0]) != null) {
        if (args.len < 3) return fakeBackendUsageError(io, "fake zwanzig graph requires <flag> <output-dir> <source>\n");
        try writeFakeDot(io, args[1], zwanzigGraphModeName(args[0]).?);
        return;
    }

    if (args.len < 3 or !std.mem.eql(u8, args[0], "--format")) {
        return fakeBackendUsageError(io, "fake zwanzig lint requires --format <json|sarif> <path>\n");
    }
    const format = args[1];
    if (!std.mem.eql(u8, format, "json") and !std.mem.eql(u8, format, "sarif")) {
        return fakeBackendUsageError(io, "fake zwanzig rejected unsupported --format value\n");
    }
    var i: usize = 2;
    var saw_path = false;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "--do") or std.mem.eql(u8, arg, "--skip")) {
            if (i + 1 >= args.len) return fakeBackendUsageError(io, "fake zwanzig option requires a value\n");
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--dump-") or std.mem.eql(u8, arg, "--dot")) {
            return fakeBackendUsageError(io, "fake zwanzig graph flags must use zig_analysis_graphs typed mode\n");
        }
        saw_path = true;
        break;
    }
    if (!saw_path) return fakeBackendUsageError(io, "fake zwanzig lint requires a workspace path\n");
    if (std.mem.eql(u8, format, "sarif")) {
        try stdoutWrite(io, "{\"version\":\"2.1.0\",\"runs\":[{\"tool\":{\"driver\":{\"name\":\"fake-zwanzig\"}}}]}\n");
    } else {
        try stdoutWrite(io, "{\"diagnostics\":[]}\n");
    }
}

/// Simulates ZLint for conformance testing.  Supports `--help`, `--print-ast`,
/// `--rules --format json`, and `--format json [--fix|--fix-dangerously] <path>`.
/// Returns a minimal well-formed JSON response on success.  Bad argument
/// sequences return `error.InvalidArguments`.
pub fn fakeZlint(io: Io, args: []const []const u8) !void {
    if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) {
        try stdoutWrite(io, "fake ZLint help\n--format json\n--rules --format json\n--print-ast <file>\n--fix\n--fix-dangerously\n");
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[0], "--print-ast")) {
        try stdoutWrite(io, "Printing AST for ");
        try stdoutWrite(io, args[1]);
        try stdoutWrite(io, "\n{\"symbols\":[{\"name\":\"main\",\"references\":[{\"flags\":[\"call\"]}]}]}\n");
        return;
    }
    if (args.len >= 3 and std.mem.eql(u8, args[0], "--rules") and std.mem.eql(u8, args[1], "--format") and std.mem.eql(u8, args[2], "json")) {
        try stdoutWrite(io, "{\"rules\":[{\"id\":\"fake.zlint.rule\",\"severity\":\"warning\",\"category\":\"style\",\"description\":\"fake ZLint rule\"}]}\n");
        return;
    }
    if (args.len < 3 or !std.mem.eql(u8, args[0], "--format") or !std.mem.eql(u8, args[1], "json")) {
        return fakeBackendUsageError(io, "fake ZLint requires --format json <path>\n");
    }
    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "--fix") or std.mem.eql(u8, arg, "--fix-dangerously")) {
            try stdoutWrite(io, "{\"findings\":[]}\n");
            return;
        }
    }
    try stdoutWrite(io, "{\"findings\":[{\"rule\":\"fake.zlint.rule\",\"severity\":\"warning\",\"path\":\"src/main.zig\",\"line\":1,\"column\":15,\"message\":\"fake ZLint finding\"}]}\n");
}

/// Simulates zflame for conformance testing.  Accepts `--help` and the
/// canonical form `<format> [--title=…] [--colors=…] <input>`.  Rejects
/// stale option syntax (bare `--palette`) and validates the format string
/// via `backend_contracts.parseZflameFormat`.  Writes a minimal SVG to stdout.
pub fn fakeZflame(io: Io, args: []const []const u8) !void {
    if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) {
        try stdoutWrite(io, "fake zflame help\nusage: zflame <format> [--title=<text>] [--colors=<palette>] <input>\n");
        return;
    }
    if (args.len < 2) return fakeBackendUsageError(io, "fake zflame requires <format> <input>\n");
    if (backend_contracts.parseZflameFormat(args[0]) == null) {
        return fakeBackendUsageError(io, "fake zflame rejected unsupported format\n");
    }
    var input_count: usize = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--hash")) continue;
        if (std.mem.startsWith(u8, arg, "--title=") or
            std.mem.startsWith(u8, arg, "--subtitle=") or
            std.mem.startsWith(u8, arg, "--colors=") or
            std.mem.startsWith(u8, arg, "--width=") or
            std.mem.startsWith(u8, arg, "--min-width="))
        {
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            return fakeBackendUsageError(io, "fake zflame rejected stale or unsupported option syntax\n");
        }
        input_count += 1;
        if (i + 1 != args.len) return fakeBackendUsageError(io, "fake zflame input must be the final argument\n");
    }
    if (input_count != 1) return fakeBackendUsageError(io, "fake zflame requires exactly one input\n");
    try stdoutWrite(io, "<svg xmlns=\"http://www.w3.org/2000/svg\"><title>fake flamegraph</title></svg>\n");
}

/// Simulates diff-folded for conformance testing.  Expects exactly
/// `--output=<path> before.folded after.folded` and writes a small folded
/// stack sample to the output file.  Any other argument shape returns
/// `error.InvalidArguments`.
pub fn fakeDiffFolded(io: Io, args: []const []const u8) !void {
    if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) {
        try stdoutWrite(io, "fake diff-folded help\nusage: diff-folded --output=<path> before.folded after.folded\n");
        return;
    }
    if (args.len != 3 or !std.mem.startsWith(u8, args[0], "--output=")) {
        return fakeBackendUsageError(io, "fake diff-folded requires --output=<path> before after\n");
    }
    const output = args[0]["--output=".len..];
    if (output.len == 0) return fakeBackendUsageError(io, "fake diff-folded output must be non-empty\n");
    if (std.fs.path.dirname(output)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = output, .data = "main;delta 2\n" });
    try stdoutWrite(io, "wrote folded diff\n");
}

/// Maps a zwanzig graph flag to the contract mode name.
fn zwanzigGraphModeName(flag: []const u8) ?[]const u8 {
    inline for (std.meta.tags(backend_contracts.ZwanzigGraphMode)) |mode| {
        if (std.mem.eql(u8, flag, mode.flag())) return mode.name();
    }
    return null;
}

/// Writes a minimal DOT graph for a fake zwanzig graph mode.
fn writeFakeDot(io: Io, output_dir: []const u8, mode: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, output_dir);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/fake-{s}.dot", .{ output_dir, mode });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "digraph fake { start -> end }\n" });
    try stdoutWrite(io, "wrote fake graph\n");
}

/// Writes `message` to stderr and returns an invalid-arguments error.
/// Any write failure propagates to the caller rather than being silenced,
/// so diagnostic output is never silently dropped.
fn fakeBackendUsageError(io: Io, message: []const u8) !void {
    try Io.File.stderr().writeStreamingAll(io, message);
    return error.InvalidArguments;
}

/// Writes successful fake-backend output to stdout.
fn stdoutWrite(io: Io, bytes: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, bytes);
}

test "fake backend graph mode rejects unknown flags" {
    try std.testing.expect(zwanzigGraphModeName("--not-a-graph-mode") == null);
}
