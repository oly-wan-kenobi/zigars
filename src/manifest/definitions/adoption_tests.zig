const std = @import("std");
const subject = @import("adoption.zig");
const zigar_adoption_pack = subject.zigar_adoption_pack;
const zigar_client_config_generate = subject.zigar_client_config_generate;
const zigar_smoke_plan = subject.zigar_smoke_plan;
const zigar_conformance_report = subject.zigar_conformance_report;

test "adoption definitions expose rollout metadata" {
    try @import("std").testing.expect(zigar_adoption_pack.description.len > 0);
}
