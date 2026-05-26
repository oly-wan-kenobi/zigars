const std = @import("std");
const subject = @import("environment_profiles.zig");
const zigar_setup_elicit = subject.zigar_setup_elicit;
const zigar_profile_elicit = subject.zigar_profile_elicit;
const zigar_backend_elicit = subject.zigar_backend_elicit;
const zigar_project_profile_v2 = subject.zigar_project_profile_v2;
const zigar_profile_validate = subject.zigar_profile_validate;
const zigar_profile_read = subject.zigar_profile_read;
const zigar_profile_bootstrap = subject.zigar_profile_bootstrap;
const zigar_profile_import = subject.zigar_profile_import;
const zigar_profile_diff = subject.zigar_profile_diff;
const zigar_env_pack = subject.zigar_env_pack;
const zigar_env_export = subject.zigar_env_export;
const zigar_zvm_probe = subject.zigar_zvm_probe;
const zigar_zvm_install_plan = subject.zigar_zvm_install_plan;
const zigar_zvm_switch_plan = subject.zigar_zvm_switch_plan;
const zig_zls_match_check = subject.zig_zls_match_check;
const zig_toolchain_pin = subject.zig_toolchain_pin;
const zig_toolchain_pin_check = subject.zig_toolchain_pin_check;
const zigar_backend_install_plan = subject.zigar_backend_install_plan;
const zigar_backend_verify = subject.zigar_backend_verify;
const zigar_dev_env_generate = subject.zigar_dev_env_generate;
const zigar_backend_conformance = subject.zigar_backend_conformance;
const zigar_backend_evidence_pack = subject.zigar_backend_evidence_pack;

test "environment profile definitions expose setup metadata" {
    try @import("std").testing.expect(zigar_setup_elicit.description.len > 0);
}
