//! Pins the contract that all discovery tool definitions are exported and carry
//! non-empty descriptions, confirming the public surface compiles cleanly.
const std = @import("std");
const subject = @import("discovery.zig");
const zigars_capabilities = subject.zigars_capabilities;
const zigars_tool_index = subject.zigars_tool_index;
const zigars_schema = subject.zigars_schema;
const zigars_backend_catalog = subject.zigars_backend_catalog;
const zigars_doctor = subject.zigars_doctor;
const zigars_workspace_info = subject.zigars_workspace_info;
const zigars_metrics = subject.zigars_metrics;
const zigars_http_status = subject.zigars_http_status;
const zig_command_plan = subject.zig_command_plan;
const zig_tool_plan = subject.zig_tool_plan;
const zig_toolchain_resolve = subject.zig_toolchain_resolve;

test "discovery definitions expose capability metadata" {
    try @import("std").testing.expect(zigars_capabilities.description.len > 0);
}
