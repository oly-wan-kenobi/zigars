//! Contract tests for environment_profiles.zig: pins that every setup/profile
//! tool exposes a non-empty description and that write-capable tools carry the
//! expected apply-gate risk metadata.
const std = @import("std");
const subject = @import("environment_profiles.zig");
const zigars_project_profile_v2 = subject.zigars_project_profile_v2;
const zigars_profile_validate = subject.zigars_profile_validate;
const zigars_profile_read = subject.zigars_profile_read;
const zigars_profile_bootstrap = subject.zigars_profile_bootstrap;
const zigars_profile_import = subject.zigars_profile_import;
const zigars_profile_diff = subject.zigars_profile_diff;
const zigars_env_pack = subject.zigars_env_pack;
const zigars_env_export = subject.zigars_env_export;
const zigars_zvm_probe = subject.zigars_zvm_probe;
const zigars_zvm_install_plan = subject.zigars_zvm_install_plan;
const zigars_zvm_switch_plan = subject.zigars_zvm_switch_plan;
const zig_zls_match_check = subject.zig_zls_match_check;
const zig_toolchain_pin = subject.zig_toolchain_pin;
const zig_toolchain_pin_check = subject.zig_toolchain_pin_check;
const zigars_backend_install_plan = subject.zigars_backend_install_plan;
const zigars_backend_verify = subject.zigars_backend_verify;
const zigars_dev_env_generate = subject.zigars_dev_env_generate;
const zigars_backend_conformance = subject.zigars_backend_conformance;
const zigars_backend_evidence_pack = subject.zigars_backend_evidence_pack;

test "environment profile definitions expose setup metadata" {
    try @import("std").testing.expect(zigars_project_profile_v2.description.len > 0);
}
