const std = @import("std");

pub fn run(client: anytype) !void {
    const profile_v2 = try client.callTool("zigars_project_profile_v2", "{\"apply\":false}");
    defer client.allocator.free(profile_v2);
    try client.expectPathJson(profile_v2, "profile.schema_version", .{ .integer = 2 });
    try client.expectPathJson(profile_v2, "applied", .{ .bool = false });

    const profile_apply = try client.callTool("zigars_project_profile_v2", "{\"apply\":true}");
    defer client.allocator.free(profile_apply);
    try client.expectPathJson(profile_apply, "applied", .{ .bool = true });

    const profile_read = try client.callTool("zigars_profile_read", "{}");
    defer client.allocator.free(profile_read);
    try client.expectPathJson(profile_read, "exists", .{ .bool = true });
    try client.expectPathJson(profile_read, "validation.valid", .{ .bool = true });

    const profile_validate = try client.callTool("zigars_profile_validate", "{}");
    defer client.allocator.free(profile_validate);
    try client.expectPathJson(profile_validate, "validation.valid", .{ .bool = true });

    const profile_diff = try client.callTool("zigars_profile_diff", "{}");
    defer client.allocator.free(profile_diff);
    try client.expectPathJson(profile_diff, "current_exists", .{ .bool = true });

    const profile_bootstrap = try client.callTool("zigars_profile_bootstrap", "{}");
    defer client.allocator.free(profile_bootstrap);
    try client.expectPathString(profile_bootstrap, "kind", "zigars_profile_bootstrap");
    try client.expectPathString(profile_bootstrap, "path", ".zigars/profile.json");

    const env_pack = try client.callTool("zigars_env_pack", "{\"probe_backends\":false,\"include_hashes\":false}");
    defer client.allocator.free(env_pack);
    try client.expectPathString(env_pack, "kind", "zigars_env_pack");
    try client.expectPathJson(env_pack, "schema_version", .{ .integer = 1 });

    const zvm_probe = try client.callTool("zigars_zvm_probe", "{\"zvm_path\":\"/definitely/missing/zvm\"}");
    defer client.allocator.free(zvm_probe);
    try client.expectPathJson(zvm_probe, "available", .{ .bool = false });

    const zvm_switch = try client.callTool("zigars_zvm_switch_plan", "{\"version\":\"0.16.0\"}");
    defer client.allocator.free(zvm_switch);
    try client.expectPathJson(zvm_switch, "plan_only", .{ .bool = true });
    try client.expectPathJson(zvm_switch, "mutates_environment", .{ .bool = false });

    const toolchain_pin = try client.callTool("zig_toolchain_pin", "{\"apply\":true,\"zig_version\":\"0.16.0\",\"zls_version\":\"0.16.0\"}");
    defer client.allocator.free(toolchain_pin);
    try client.expectPathJson(toolchain_pin, "applied", .{ .bool = true });

    const dev_env = try client.callTool("zigars_dev_env_generate", "{\"kind\":\"mise\",\"apply\":true}");
    defer client.allocator.free(dev_env);
    try client.expectPathJson(dev_env, "applied", .{ .bool = true });

    const backend_plan = try client.callTool("zigars_backend_install_plan", "{\"backend\":\"zflame\",\"manager\":\"manual\"}");
    defer client.allocator.free(backend_plan);
    try client.expectPathJson(backend_plan, "plan_only", .{ .bool = true });
    try client.expectPathString(backend_plan, "plans.0.backend", "zflame");

    const backend_conformance = try client.callTool("zigars_backend_conformance", "{\"backend\":\"zflame\",\"probe_backends\":false}");
    defer client.allocator.free(backend_conformance);
    try client.expectPathString(backend_conformance, "run_state", "plan_only");
    try client.expectPathString(backend_conformance, "scenarios.0.name", "zflame_recursive_folded_svg");

    const backend_evidence = try client.callTool("zigars_backend_evidence_pack", "{\"apply\":false}");
    defer client.allocator.free(backend_evidence);
    try client.expectPathJson(backend_evidence, "evidence.available", .{ .bool = false });
    try client.expectPathJson(backend_evidence, "applied", .{ .bool = false });
}

test "stdio environment fixture exposes run entrypoint" {
    try std.testing.expect(@hasDecl(@This(), "run"));
}
