const std = @import("std");
const core = @import("shared_core.zig");

const classifyDiagnosticMessage = core.classifyDiagnosticMessage;
const ownedString = core.ownedString;

pub fn lspDiagnosticsInsightsValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    const value_obj = switch (value) {
        .object => |o| o,
        else => {
            var empty = std.json.ObjectMap.empty;
            try empty.put(allocator, "finding_count", .{ .integer = 0 });
            try empty.put(allocator, "findings", .{ .array = std.json.Array.init(allocator) });
            try empty.put(allocator, "primary", .null);
            try empty.put(allocator, "next_actions", .{ .array = std.json.Array.init(allocator) });
            return .{ .object = empty };
        },
    };
    const uri = switch (value_obj.get("uri") orelse .null) {
        .string => |s| s,
        else => null,
    };
    const items = value_obj.get("diagnostics") orelse value_obj.get("items") orelse std.json.Value{ .array = std.json.Array.init(allocator) };
    const item_array = switch (items) {
        .array => |a| a,
        else => std.json.Array.init(allocator),
    };

    var findings = std.json.Array.init(allocator);
    var error_count: i64 = 0;
    var warning_count: i64 = 0;
    var info_count: i64 = 0;
    var primary_message: ?[]const u8 = null;
    var primary_path: ?[]const u8 = uri;
    var primary_line: ?i64 = null;
    var primary_column: ?i64 = null;
    var primary_severity: []const u8 = "info";

    for (item_array.items) |item| {
        const item_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const message = switch (item_obj.get("message") orelse .null) {
            .string => |s| s,
            else => continue,
        };
        const severity_code = switch (item_obj.get("severity") orelse .null) {
            .integer => |i| i,
            else => 3,
        };
        const severity = lspSeverityName(severity_code);
        if (std.mem.eql(u8, severity, "error")) {
            error_count += 1;
        } else if (std.mem.eql(u8, severity, "warning")) {
            warning_count += 1;
        } else {
            info_count += 1;
        }
        const start = lspDiagnosticStart(item_obj.get("range") orelse .null);
        var finding = std.json.ObjectMap.empty;
        try finding.put(allocator, "source", .{ .string = "zls" });
        try finding.put(allocator, "severity", .{ .string = severity });
        try finding.put(allocator, "message", try ownedString(allocator, message));
        if (uri) |u| {
            try finding.put(allocator, "uri", try ownedString(allocator, u));
        } else {
            try finding.put(allocator, "uri", .null);
        }
        if (start.line) |line_no| {
            try finding.put(allocator, "line", .{ .integer = line_no });
        } else {
            try finding.put(allocator, "line", .null);
        }
        if (start.column) |col_no| {
            try finding.put(allocator, "column", .{ .integer = col_no });
        } else {
            try finding.put(allocator, "column", .null);
        }
        try findings.append(.{ .object = finding });

        if (primary_message == null or (std.mem.eql(u8, severity, "error") and !std.mem.eql(u8, primary_severity, "error"))) {
            primary_message = message;
            primary_line = start.line;
            primary_column = start.column;
            primary_severity = severity;
            primary_path = uri;
        }
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "finding_count", .{ .integer = @intCast(findings.items.len) });
    try obj.put(allocator, "error_count", .{ .integer = error_count });
    try obj.put(allocator, "warning_count", .{ .integer = warning_count });
    try obj.put(allocator, "info_count", .{ .integer = info_count });
    try obj.put(allocator, "findings", .{ .array = findings });
    if (primary_message) |message| {
        var primary = std.json.ObjectMap.empty;
        try primary.put(allocator, "source", .{ .string = "zls" });
        try primary.put(allocator, "severity", .{ .string = primary_severity });
        try primary.put(allocator, "message", try ownedString(allocator, message));
        if (primary_path) |path| {
            try primary.put(allocator, "uri", try ownedString(allocator, path));
        } else {
            try primary.put(allocator, "uri", .null);
        }
        if (primary_line) |line_no| {
            try primary.put(allocator, "line", .{ .integer = line_no });
        } else {
            try primary.put(allocator, "line", .null);
        }
        if (primary_column) |col_no| {
            try primary.put(allocator, "column", .{ .integer = col_no });
        } else {
            try primary.put(allocator, "column", .null);
        }
        try obj.put(allocator, "primary", .{ .object = primary });
        try obj.put(allocator, "category", .{ .string = classifyDiagnosticMessage(message) });
        try obj.put(allocator, "next_actions", try lspNextActions(allocator, primary_path, primary_line, primary_column, primary_severity, message));
    } else {
        try obj.put(allocator, "primary", .null);
        try obj.put(allocator, "category", .{ .string = "none" });
        try obj.put(allocator, "next_actions", .{ .array = std.json.Array.init(allocator) });
    }
    return .{ .object = obj };
}

pub const LspStart = struct {
    line: ?i64 = null,
    column: ?i64 = null,
};

pub fn lspDiagnosticStart(range_value: std.json.Value) LspStart {
    const range_obj = switch (range_value) {
        .object => |o| o,
        else => return .{},
    };
    const start_obj = switch (range_obj.get("start") orelse .null) {
        .object => |o| o,
        else => return .{},
    };
    const line_no = switch (start_obj.get("line") orelse .null) {
        .integer => |i| i + 1,
        else => null,
    };
    const col_no = switch (start_obj.get("character") orelse .null) {
        .integer => |i| i + 1,
        else => null,
    };
    return .{ .line = line_no, .column = col_no };
}

pub fn lspSeverityName(code: i64) []const u8 {
    return switch (code) {
        1 => "error",
        2 => "warning",
        3 => "info",
        4 => "hint",
        else => "info",
    };
}

pub fn lspNextActions(allocator: std.mem.Allocator, uri: ?[]const u8, line_no: ?i64, col_no: ?i64, severity: []const u8, message: []const u8) !std.json.Value {
    var actions = std.json.Array.init(allocator);
    if (uri) |u| {
        if (line_no) |line_value| {
            if (col_no) |col_value| {
                try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Open {s}:{d}:{d} and address the primary ZLS {s}: {s}", .{ u, line_value, col_value, severity, message }) });
            } else {
                try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Open {s}:{d} and address the primary ZLS {s}: {s}", .{ u, line_value, severity, message }) });
            }
        } else {
            try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Inspect {s} and address the primary ZLS {s}: {s}", .{ u, severity, message }) });
        }
    } else {
        try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Address the primary ZLS {s}: {s}", .{ severity, message }) });
    }
    try actions.append(try ownedString(allocator, "Rerun zig_diagnostics after the focused edit."));
    return .{ .array = actions };
}
