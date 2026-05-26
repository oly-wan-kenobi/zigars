const std = @import("std");
const subject = @import("discovery.zig");
const zigar_capabilities = subject.zigar_capabilities;
const zigar_tool_index = subject.zigar_tool_index;
const zigar_schema = subject.zigar_schema;
const zigar_backend_catalog = subject.zigar_backend_catalog;
const zigar_doctor = subject.zigar_doctor;
const zigar_workspace_info = subject.zigar_workspace_info;
const zigar_metrics = subject.zigar_metrics;
const zigar_http_status = subject.zigar_http_status;
const zig_command_plan = subject.zig_command_plan;
const zig_tool_plan = subject.zig_tool_plan;
const zig_toolchain_resolve = subject.zig_toolchain_resolve;

test "discovery definitions expose capability metadata" {
    try @import("std").testing.expect(zigar_capabilities.description.len > 0);
}
