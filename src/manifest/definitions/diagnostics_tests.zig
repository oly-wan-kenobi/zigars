const std = @import("std");
const subject = @import("diagnostics.zig");
const zig_debug_plan = subject.zig_debug_plan;
const zig_lldb_backtrace = subject.zig_lldb_backtrace;
const zig_core_inspect = subject.zig_core_inspect;
const zig_debug_frame_summary = subject.zig_debug_frame_summary;
const zig_sanitizer_fusion = subject.zig_sanitizer_fusion;
const zig_panic_trace_analyze = subject.zig_panic_trace_analyze;
const zig_crash_repro_plan = subject.zig_crash_repro_plan;
const zig_heaptrack_run = subject.zig_heaptrack_run;
const zig_heaptrack_summary = subject.zig_heaptrack_summary;
const zig_valgrind_memcheck = subject.zig_valgrind_memcheck;
const zig_callgrind_report = subject.zig_callgrind_report;
const zig_fuzz_plan = subject.zig_fuzz_plan;
const zig_afl_run = subject.zig_afl_run;
const zig_libfuzzer_run = subject.zig_libfuzzer_run;
const zig_fuzz_crash_minimize = subject.zig_fuzz_crash_minimize;
const zig_fuzz_corpus_summary = subject.zig_fuzz_corpus_summary;
const zig_binary_size = subject.zig_binary_size;
const zig_binary_size_diff = subject.zig_binary_size_diff;
const zig_objdump_summary = subject.zig_objdump_summary;
const zig_dwarfdump_check = subject.zig_dwarfdump_check;
const zig_symbolize = subject.zig_symbolize;
const zig_qemu_test = subject.zig_qemu_test;
const zig_cross_smoke = subject.zig_cross_smoke;
const zig_target_runtime_plan = subject.zig_target_runtime_plan;
const zig_embedded_detect = subject.zig_embedded_detect;
const zig_microzig_plan = subject.zig_microzig_plan;
const zig_board_profile = subject.zig_board_profile;
const zig_flash_plan = subject.zig_flash_plan;

test "diagnostics definitions expose debug metadata" {
    try @import("std").testing.expect(zig_debug_plan.description.len > 0);
}
