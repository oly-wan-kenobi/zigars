const std = @import("std");
const subject = @import("adoption.zig");
const zigars_adoption_pack = subject.zigars_adoption_pack;
const zigars_client_config_generate = subject.zigars_client_config_generate;
const zigars_smoke_plan = subject.zigars_smoke_plan;
const zigars_conformance_report = subject.zigars_conformance_report;

test "adoption definitions expose rollout metadata" {
    try @import("std").testing.expect(zigars_adoption_pack.description.len > 0);
}
