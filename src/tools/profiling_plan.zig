const std = @import("std");
const builtin = @import("builtin");
const zigar = @import("zigar");
const common = @import("common.zig");

const backend_contracts = zigar.backend_contracts;
const argString = common.argString;

pub const capture_semantics = "zigar does not execute or define profiler capture semantics; external profilers own sampling, permissions, symbols, privilege requirements, and output fidelity.";

pub fn profilePlanValue(allocator: std.mem.Allocator, args: ?std.json.Value) !std.json.Value {
    const binary = argString(args, "binary") orelse "zig-out/bin/<app>";
    const requested_platform = argString(args, "platform");
    const selected_platform = if (requested_platform) |platform| platform else detectedPlatform();
    const output_prefix = argString(args, "output_prefix") orelse ".zigar-cache/profile/profile";
    const svg_output = try std.fmt.allocPrint(allocator, "{s}.svg", .{output_prefix});

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_profile_plan" });
    try obj.put(allocator, "binary", .{ .string = binary });
    try obj.put(allocator, "detected_platform", .{ .string = detectedPlatform() });
    if (requested_platform) |platform| {
        try obj.put(allocator, "requested_platform", .{ .string = platform });
    } else {
        try obj.put(allocator, "requested_platform", .null);
    }
    try obj.put(allocator, "selected_platform", .{ .string = selected_platform });
    try obj.put(allocator, "capture_semantics", .{ .string = capture_semantics });
    try obj.put(allocator, "supported_zflame_formats", try stringArrayValue(allocator, backend_contracts.zflame_format_names[0..]));
    try obj.put(allocator, "recommended_plan_ids", try recommendedPlanIdsValue(allocator, selected_platform));
    try obj.put(allocator, "plans", try capturePlansValue(allocator, binary, output_prefix, svg_output));
    try obj.put(allocator, "diff_workflow", try diffWorkflowValue(allocator, output_prefix));
    return .{ .object = obj };
}

fn detectedPlatform() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "macos",
        .freebsd => "freebsd",
        .illumos => "illumos",
        .windows => "windows",
        else => @tagName(builtin.os.tag),
    };
}

fn capturePlansValue(allocator: std.mem.Allocator, binary: []const u8, output_prefix: []const u8, svg_output: []const u8) !std.json.Value {
    var plans = std.json.Array.init(allocator);
    errdefer plans.deinit();
    try plans.append(try capturePlanValue(allocator, .{
        .id = "linux_perf",
        .platforms = &.{"linux"},
        .required_profiler = "perf",
        .captured_output = try std.fmt.allocPrint(allocator, "{s}.perf.data", .{output_prefix}),
        .zflame_format = .perf,
        .command = try std.fmt.allocPrint(allocator, "perf record -F 997 -g -o {s}.perf.data -- {s}", .{ output_prefix, binary }),
        .prerequisites = &.{ "Linux perf installed", "kernel perf_event permissions allow sampling", "binary built with symbols or usable debug info" },
        .limitations = &.{ "perf privilege, callchain mode, kernel settings, and symbolization quality are external to zigar", capture_semantics },
        .svg_output = svg_output,
    }));
    try plans.append(try capturePlanValue(allocator, .{
        .id = "macos_sample",
        .platforms = &.{"macos"},
        .required_profiler = "sample",
        .captured_output = try std.fmt.allocPrint(allocator, "{s}.sample.txt", .{output_prefix}),
        .zflame_format = .sample,
        .command = try std.fmt.allocPrint(allocator, "sample <pid> 10 -file {s}.sample.txt", .{output_prefix}),
        .prerequisites = &.{ "macOS sample available", "target process is already running", "terminal has required sampling permissions" },
        .limitations = &.{ "sample attaches to an existing pid instead of launching the binary", capture_semantics },
        .svg_output = svg_output,
    }));
    try plans.append(try capturePlanValue(allocator, .{
        .id = "macos_xctrace",
        .platforms = &.{"macos"},
        .required_profiler = "xctrace",
        .captured_output = try std.fmt.allocPrint(allocator, "{s}.trace", .{output_prefix}),
        .zflame_format = .xctrace,
        .command = try std.fmt.allocPrint(allocator, "xcrun xctrace record --template \"Time Profiler\" --output {s}.trace --launch -- {s}", .{ output_prefix, binary }),
        .prerequisites = &.{ "Xcode command line tools", "Time Profiler template available", "binary can be launched by xctrace" },
        .limitations = &.{ "xctrace capture templates and trace contents are controlled by Apple tooling", capture_semantics },
        .svg_output = svg_output,
    }));
    try plans.append(try capturePlanValue(allocator, .{
        .id = "dtrace",
        .platforms = &.{ "macos", "freebsd", "illumos" },
        .required_profiler = "dtrace",
        .captured_output = try std.fmt.allocPrint(allocator, "{s}.dtrace.txt", .{output_prefix}),
        .zflame_format = .dtrace,
        .command = try std.fmt.allocPrint(allocator, "sudo dtrace -x ustackframes=100 -n 'profile-997 /pid == $target/ {{ @[ustack()] = count(); }}' -c '{s}' -o {s}.dtrace.txt", .{ binary, output_prefix }),
        .prerequisites = &.{ "DTrace available on the host", "required privileges granted", "target binary and symbols visible to DTrace" },
        .limitations = &.{ "DTrace availability and restrictions vary by OS release and security policy", capture_semantics },
        .svg_output = svg_output,
    }));
    try plans.append(try capturePlanValue(allocator, .{
        .id = "vtune",
        .platforms = &.{ "linux", "windows" },
        .required_profiler = "vtune",
        .captured_output = try std.fmt.allocPrint(allocator, "{s}.vtune", .{output_prefix}),
        .zflame_format = .vtune,
        .command = try std.fmt.allocPrint(allocator, "vtune -collect hotspots -result-dir {s}.vtune -- {s}", .{ output_prefix, binary }),
        .prerequisites = &.{ "Intel VTune installed", "project license/environment configured", "VTune can launch or attach to the target" },
        .limitations = &.{ "VTune collection mode, result schema, and permissions are external to zigar", capture_semantics },
        .svg_output = svg_output,
    }));
    try plans.append(try capturePlanValue(allocator, .{
        .id = "already_folded_recursive",
        .platforms = &.{ "linux", "macos", "freebsd", "illumos", "windows" },
        .required_profiler = "already-folded recursive stacks",
        .captured_output = try std.fmt.allocPrint(allocator, "{s}.folded", .{output_prefix}),
        .zflame_format = .recursive,
        .command = try std.fmt.allocPrint(allocator, "<external folded-stack producer> > {s}.folded", .{output_prefix}),
        .prerequisites = &.{ "input is folded-stack text in recursive format", "capture or stack collapsing happened outside zigar" },
        .limitations = &.{ "zigar renders folded stacks but does not verify how they were captured or collapsed", capture_semantics },
        .svg_output = svg_output,
    }));
    return .{ .array = plans };
}

const CapturePlanSpec = struct {
    id: []const u8,
    platforms: []const []const u8,
    required_profiler: []const u8,
    captured_output: []const u8,
    zflame_format: backend_contracts.ZflameFormat,
    command: []const u8,
    prerequisites: []const []const u8,
    limitations: []const []const u8,
    svg_output: []const u8,
};

fn capturePlanValue(allocator: std.mem.Allocator, spec: CapturePlanSpec) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "id", .{ .string = spec.id });
    try obj.put(allocator, "platforms", try stringArrayValue(allocator, spec.platforms));
    try obj.put(allocator, "required_profiler", .{ .string = spec.required_profiler });
    try obj.put(allocator, "recommended_external_command", .{ .string = spec.command });
    try obj.put(allocator, "expected_captured_output_path", .{ .string = spec.captured_output });
    try obj.put(allocator, "zflame_input_format", .{ .string = spec.zflame_format.name() });
    try obj.put(allocator, "next_zigar_command", try nextZigarCommandValue(allocator, spec.zflame_format, spec.captured_output, spec.svg_output));
    try obj.put(allocator, "prerequisites", try stringArrayValue(allocator, spec.prerequisites));
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, spec.limitations));
    try obj.put(allocator, "capture_owned_by", .{ .string = "external_profiler" });
    try obj.put(allocator, "capture_semantics", .{ .string = capture_semantics });
    return .{ .object = obj };
}

fn nextZigarCommandValue(allocator: std.mem.Allocator, format: backend_contracts.ZflameFormat, input: []const u8, output: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "tool", .{ .string = "zig_flamegraph" });
    try obj.put(allocator, "format", .{ .string = format.name() });
    try obj.put(allocator, "input", .{ .string = input });
    try obj.put(allocator, "output", .{ .string = output });
    try obj.put(allocator, "command", .{ .string = try std.fmt.allocPrint(allocator, "zig_flamegraph {{\"format\":\"{s}\",\"input\":\"{s}\",\"output\":\"{s}\"}}", .{ format.name(), input, output }) });
    return .{ .object = obj };
}

fn recommendedPlanIdsValue(allocator: std.mem.Allocator, platform: []const u8) !std.json.Value {
    if (std.mem.eql(u8, platform, "linux")) return stringArrayValue(allocator, &.{ "linux_perf", "vtune", "already_folded_recursive" });
    if (std.mem.eql(u8, platform, "macos")) return stringArrayValue(allocator, &.{ "macos_xctrace", "macos_sample", "dtrace", "already_folded_recursive" });
    if (std.mem.eql(u8, platform, "freebsd") or std.mem.eql(u8, platform, "illumos")) return stringArrayValue(allocator, &.{ "dtrace", "already_folded_recursive" });
    if (std.mem.eql(u8, platform, "windows")) return stringArrayValue(allocator, &.{ "vtune", "already_folded_recursive" });
    return stringArrayValue(allocator, &.{"already_folded_recursive"});
}

fn diffWorkflowValue(allocator: std.mem.Allocator, output_prefix: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "tool", .{ .string = "zig_flamegraph_diff" });
    try obj.put(allocator, "required_inputs", try stringArrayValue(allocator, &.{ "before.folded", "after.folded" }));
    try obj.put(allocator, "canonical_diff_backend", .{ .string = "diff-folded" });
    try obj.put(allocator, "canonical_renderer", .{ .string = "zflame recursive" });
    try obj.put(allocator, "suggested_output", .{ .string = try std.fmt.allocPrint(allocator, "{s}-diff.svg", .{output_prefix}) });
    try obj.put(allocator, "capture_semantics", .{ .string = capture_semantics });
    return .{ .object = obj };
}

fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (values) |value| try array.append(.{ .string = value });
    return .{ .array = array };
}
