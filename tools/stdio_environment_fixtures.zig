const std = @import("std");

pub fn run(client: anytype) !void {
    const profile_v2 = try client.callTool("zigar_project_profile_v2", "{\"apply\":false}");
    defer client.allocator.free(profile_v2);
    try client.expectPathJson(profile_v2, "profile.schema_version", .{ .integer = 2 });
    try client.expectPathJson(profile_v2, "applied", .{ .bool = false });

    const profile_bootstrap = try client.callTool("zigar_profile_bootstrap", "{}");
    defer client.allocator.free(profile_bootstrap);
    try client.expectPathString(profile_bootstrap, "kind", "zigar_profile_bootstrap");
    try client.expectPathString(profile_bootstrap, "path", ".zigar/profile.json");

    const env_pack = try client.callTool("zigar_env_pack", "{\"probe_backends\":false,\"include_hashes\":false}");
    defer client.allocator.free(env_pack);
    try client.expectPathString(env_pack, "kind", "zigar_env_pack");
    try client.expectPathJson(env_pack, "schema_version", .{ .integer = 1 });

    const zvm_switch = try client.callTool("zigar_zvm_switch_plan", "{\"version\":\"0.16.0\"}");
    defer client.allocator.free(zvm_switch);
    try client.expectPathJson(zvm_switch, "plan_only", .{ .bool = true });
    try client.expectPathJson(zvm_switch, "mutates_environment", .{ .bool = false });

    const backend_plan = try client.callTool("zigar_backend_install_plan", "{\"backend\":\"zflame\",\"manager\":\"manual\"}");
    defer client.allocator.free(backend_plan);
    try client.expectPathJson(backend_plan, "plan_only", .{ .bool = true });
    try client.expectPathString(backend_plan, "plans.0.backend", "zflame");

    const backend_conformance = try client.callTool("zigar_backend_conformance", "{\"backend\":\"zflame\",\"probe_backends\":false}");
    defer client.allocator.free(backend_conformance);
    try client.expectPathString(backend_conformance, "run_state", "plan_only");
    try client.expectPathString(backend_conformance, "scenarios.0.name", "zflame_recursive_folded_svg");

    const backend_evidence = try client.callTool("zigar_backend_evidence_pack", "{\"apply\":false}");
    defer client.allocator.free(backend_evidence);
    try client.expectPathJson(backend_evidence, "evidence.available", .{ .bool = false });
    try client.expectPathJson(backend_evidence, "applied", .{ .bool = false });
}
