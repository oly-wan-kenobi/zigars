const std = @import("std");
const package = @import("build.zig.zon");
const release_targets = @import("tools/release_targets.zig");

pub fn build(b: *std.Build) void {
    const version = package.version;
    const semantic_version = std.SemanticVersion.parse(version) catch @panic("invalid build.zig.zon version");
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mcp_dep = b.dependency("mcp", .{
        .target = target,
        .optimize = optimize,
    });
    const mcp_mod = mcp_dep.module("mcp");

    const zigar_mod = addZigarModule(b, "zigar", target, optimize, mcp_mod, build_options);
    const exe_mod = addZigarExecutableModule(b, target, optimize, zigar_mod, mcp_mod);
    const exe = b.addExecutable(.{
        .name = "zigar",
        .root_module = exe_mod,
        .version = semantic_version,
    });
    b.installArtifact(exe);

    const tools_mod = b.createModule(.{
        .root_source_file = b.path("tools/zigar_tools.zig"),
        .target = target,
        .optimize = optimize,
    });
    tools_mod.addImport("mcp", mcp_mod);
    tools_mod.addImport("zigar", zigar_mod);
    const tools_exe = b.addExecutable(.{
        .name = "zigar-tools",
        .root_module = tools_mod,
    });

    const release_optimize: std.builtin.OptimizeMode = .ReleaseSafe;
    const release_mcp_dep = b.dependency("mcp", .{
        .target = target,
        .optimize = release_optimize,
    });
    const release_mcp_mod = release_mcp_dep.module("mcp");
    const release_zigar_mod = addZigarModule(b, "zigar-release-check", target, release_optimize, release_mcp_mod, build_options);
    const release_exe_mod = addZigarExecutableModule(b, target, release_optimize, release_zigar_mod, release_mcp_mod);
    const release_exe = b.addExecutable(.{
        .name = "zigar-release-check",
        .root_module = release_exe_mod,
        .version = semantic_version,
    });

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run zigar");
    run_step.dependOn(&run_cmd.step);

    const lib_tests = b.addTest(.{ .name = "zigar-lib-tests", .root_module = zigar_mod, .use_llvm = true });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const exe_tests = b.addTest(.{ .name = "zigar-exe-tests", .root_module = exe_mod, .use_llvm = true });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const tools_tests = b.addTest(.{ .name = "zigar-tools-tests", .root_module = tools_mod, .use_llvm = true });
    const run_tools_tests = b.addRunArtifact(tools_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_tools_tests.step);

    const test_bin_dir: std.Build.Step.InstallArtifact.Options.Dir = .{ .override = .{ .custom = "test-bin" } };
    const install_lib_tests = b.addInstallArtifact(lib_tests, .{ .dest_dir = test_bin_dir });
    const install_exe_tests = b.addInstallArtifact(exe_tests, .{ .dest_dir = test_bin_dir });
    const install_tools_tests = b.addInstallArtifact(tools_tests, .{ .dest_dir = test_bin_dir });
    const install_test_bins_step = b.step("install-test-bins", "Install compiled test executables for coverage tools");
    install_test_bins_step.dependOn(&install_lib_tests.step);
    install_test_bins_step.dependOn(&install_exe_tests.step);
    install_test_bins_step.dependOn(&install_tools_tests.step);

    const tool_index_cmd = b.addRunArtifact(tools_exe);
    tool_index_cmd.addArg("generate-tool-index");
    const tool_index_step = b.step("tool-index", "Regenerate docs/tool-index.generated.md");
    tool_index_step.dependOn(&tool_index_cmd.step);

    const docs_check_cmd = b.addRunArtifact(tools_exe);
    docs_check_cmd.addArgs(&.{ "generate-tool-index", "--check" });
    const docs_check_step = b.step("docs-check", "Check generated tool-index documentation");
    docs_check_step.dependOn(&docs_check_cmd.step);

    const json_check_cmd = b.addRunArtifact(tools_exe);
    json_check_cmd.addArgs(&.{ "check-json", "src/tool_catalog.json", "tests/fixtures/http-smoke.expect.json" });
    const json_check_step = b.step("json-check", "Validate JSON fixtures and catalogs");
    json_check_step.dependOn(&json_check_cmd.step);

    const version_cmd = b.addRunArtifact(tools_exe);
    version_cmd.addArg("version");
    const version_step = b.step("version", "Print zigar package version");
    version_step.dependOn(&version_cmd.step);

    const smoke_cmd = addHttpSmokeCommand(b, tools_exe, exe.getEmittedBin());
    const smoke_step = b.step("smoke", "Run HTTP MCP smoke test against the built zigar artifact");
    smoke_step.dependOn(&smoke_cmd.step);

    const stdio_fixtures_cmd = addStdioFixturesCommand(b, tools_exe, exe.getEmittedBin());
    const stdio_fixtures_step = b.step("stdio-fixtures", "Run stdio MCP fixture integration tests");
    stdio_fixtures_step.dependOn(&stdio_fixtures_cmd.step);

    const integration_step = b.step("integration", "Run default HTTP and stdio MCP integration tests");
    integration_step.dependOn(smoke_step);
    integration_step.dependOn(stdio_fixtures_step);

    const coverage_cmd = addCoverageCommand(b, tools_exe);
    coverage_cmd.step.dependOn(install_test_bins_step);
    const coverage_step = b.step("coverage", "Run test binaries, require kcov, and enforce line coverage floors");
    coverage_step.dependOn(&coverage_cmd.step);

    const release_smoke_cmd = addHttpSmokeCommand(b, tools_exe, release_exe.getEmittedBin());
    release_smoke_cmd.step.dependOn(install_test_bins_step);

    const release_stdio_fixtures_cmd = addStdioFixturesCommand(b, tools_exe, release_exe.getEmittedBin());
    release_stdio_fixtures_cmd.step.dependOn(&release_smoke_cmd.step);

    const release_coverage_cmd = addCoverageCommand(b, tools_exe);
    release_coverage_cmd.step.dependOn(&release_stdio_fixtures_cmd.step);

    const backend_conformance_contract_cmd = b.addSystemCommand(&.{ "bash", ".github/scripts/backend-conformance-contract-smoke.sh", "--binary" });
    backend_conformance_contract_cmd.addFileArg(release_exe.getEmittedBin());
    backend_conformance_contract_cmd.step.dependOn(&release_coverage_cmd.step);
    const backend_conformance_contract_step = b.step("backend-conformance-contract", "Smoke-test backend conformance evidence report contract");
    backend_conformance_contract_step.dependOn(&backend_conformance_contract_cmd.step);

    const fmt_check_cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "fmt", "--check", "build.zig", "build.zig.zon", "src", "tools" });
    const fmt_check_step = b.step("fmt-check", "Check Zig formatting");
    fmt_check_step.dependOn(&fmt_check_cmd.step);

    const release_safe_step = b.step("release-safe", "Compile zigar with ReleaseSafe optimization");
    release_safe_step.dependOn(&release_exe.step);

    const hygiene_cmd = b.addRunArtifact(tools_exe);
    hygiene_cmd.addArg("artifact-hygiene");
    const hygiene_step = b.step("artifact-hygiene", "Check generated artifacts are not tracked");
    hygiene_step.dependOn(&hygiene_cmd.step);

    const architecture_guard_cmd = b.addRunArtifact(tools_exe);
    architecture_guard_cmd.addArg("architecture-guard");
    const architecture_guard_step = b.step("architecture-guard", "Check Phase 10 architecture dependency guards");
    architecture_guard_step.dependOn(&architecture_guard_cmd.step);

    const public_contracts_cmd = b.addRunArtifact(tools_exe);
    public_contracts_cmd.addArg("public-contracts");
    const public_contracts_step = b.step("public-contracts", "Check public MCP contract invariants");
    public_contracts_step.dependOn(&public_contracts_cmd.step);

    const release_check_step = b.step("release-check", "Run the full local release gate");
    release_check_step.dependOn(fmt_check_step);
    release_check_step.dependOn(docs_check_step);
    release_check_step.dependOn(json_check_step);
    release_check_step.dependOn(test_step);
    release_check_step.dependOn(release_safe_step);
    release_check_step.dependOn(&release_coverage_cmd.step);
    release_check_step.dependOn(backend_conformance_contract_step);
    release_check_step.dependOn(hygiene_step);
    release_check_step.dependOn(architecture_guard_step);
    release_check_step.dependOn(public_contracts_step);

    const dist_cmd = b.addRunArtifact(tools_exe);
    dist_cmd.addArgs(&.{ "dist", "--out-dir", "dist", "--version", version });
    for (release_targets.all) |release_target| {
        const dist_target = resolveReleaseTarget(b, release_target.triple);
        const dist_mcp_dep = b.dependency("mcp", .{
            .target = dist_target,
            .optimize = release_optimize,
        });
        const dist_mcp_mod = dist_mcp_dep.module("mcp");
        const dist_zigar_mod = addZigarModule(b, b.fmt("zigar-dist-{s}", .{release_target.package_name}), dist_target, release_optimize, dist_mcp_mod, build_options);
        const dist_exe_mod = addZigarExecutableModule(b, dist_target, release_optimize, dist_zigar_mod, dist_mcp_mod);
        const dist_exe = b.addExecutable(.{
            .name = "zigar",
            .root_module = dist_exe_mod,
            .version = semantic_version,
        });
        dist_cmd.addArgs(&.{ "--package", release_target.package_name, "--exe", release_target.exe_name, "--binary" });
        dist_cmd.addFileArg(dist_exe.getEmittedBin());
    }
    const dist_step = b.step("dist", "Build ReleaseSafe archives and checksums under dist/assets");
    dist_step.dependOn(&dist_cmd.step);

    const release_asset_smoke_cmd = b.addRunArtifact(tools_exe);
    release_asset_smoke_cmd.addArgs(&.{ "dist-smoke", "--assets-dir", "dist/assets", "--version", version });
    release_asset_smoke_cmd.step.dependOn(dist_step);
    const release_asset_smoke_step = b.step("release-asset-smoke", "Verify release archives, checksums, and native archive runtime");
    release_asset_smoke_step.dependOn(&release_asset_smoke_cmd.step);
}

fn addZigarModule(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mcp_mod: *std.Build.Module,
    build_options: *std.Build.Step.Options,
) *std.Build.Module {
    const zigar_mod = b.addModule(name, .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zigar_mod.addImport("mcp", mcp_mod);
    zigar_mod.addOptions("zigar_build_options", build_options);
    return zigar_mod;
}

fn addHttpSmokeCommand(b: *std.Build, tools_exe: *std.Build.Step.Compile, binary: std.Build.LazyPath) *std.Build.Step.Run {
    const cmd = b.addRunArtifact(tools_exe);
    cmd.addArgs(&.{ "http-smoke", "--binary" });
    cmd.addFileArg(binary);
    cmd.addArgs(&.{ "--workspace", "." });
    return cmd;
}

fn addStdioFixturesCommand(b: *std.Build, tools_exe: *std.Build.Step.Compile, binary: std.Build.LazyPath) *std.Build.Step.Run {
    const cmd = b.addRunArtifact(tools_exe);
    cmd.addArgs(&.{ "stdio-fixtures", "--binary" });
    cmd.addFileArg(binary);
    return cmd;
}

fn addCoverageCommand(b: *std.Build, tools_exe: *std.Build.Step.Compile) *std.Build.Step.Run {
    const cmd = b.addRunArtifact(tools_exe);
    cmd.addArgs(&.{ "coverage", "--no-build", "--require-kcov" });
    return cmd;
}

fn addZigarExecutableModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zigar_mod: *std.Build.Module,
    mcp_mod: *std.Build.Module,
) *std.Build.Module {
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zigar", zigar_mod);
    exe_mod.addImport("mcp", mcp_mod);
    return exe_mod;
}

fn resolveReleaseTarget(b: *std.Build, triple: []const u8) std.Build.ResolvedTarget {
    const query = std.Build.parseTargetQuery(.{ .arch_os_abi = triple }) catch @panic("invalid release target");
    return b.resolveTargetQuery(query);
}
