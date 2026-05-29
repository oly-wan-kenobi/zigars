//! Coverage-only imports for modules that otherwise have no direct unit tests.
//! Keeping this list explicit prevents coverage regressions when files are moved.

test {
    _ = @import("../app/result_shape.zig");
    _ = @import("../app/usecases/core/command_output.zig");
    _ = @import("../domain/evidence.zig");
    _ = @import("../domain/zig/backend_catalog.zig");
    _ = @import("../infra/backends/definitions.zig");
    _ = @import("../manifest/aggregate.zig");
    _ = @import("../manifest/all_definitions.zig");
    _ = @import("../manifest/definitions.zig");
    _ = @import("../manifest/groups.zig");
    _ = @import("../manifest/types.zig");
    _ = @import("../manifest/definitions/adoption.zig");
    _ = @import("../manifest/definitions/agent.zig");
    _ = @import("../manifest/definitions/ci.zig");
    _ = @import("../manifest/definitions/core.zig");
    _ = @import("../manifest/definitions/diagnostics.zig");
    _ = @import("../manifest/definitions/diagnostics_schemas.zig");
    _ = @import("../manifest/definitions/discovery.zig");
    _ = @import("../manifest/definitions/docs.zig");
    _ = @import("../manifest/definitions/environment_profiles.zig");
    _ = @import("../manifest/definitions/formatting.zig");
    _ = @import("../manifest/definitions/foundation.zig");
    _ = @import("../manifest/definitions/performance.zig");
    _ = @import("../manifest/definitions/phase6.zig");
    _ = @import("../manifest/definitions/profiling.zig");
    _ = @import("../manifest/definitions/runtime_ux.zig");
    _ = @import("../manifest/definitions/static_analysis.zig");
    _ = @import("../manifest/definitions/static_evidence.zig");
    _ = @import("../manifest/definitions/transactional_editing.zig");
    _ = @import("../manifest/definitions/validation_workflows.zig");
    _ = @import("../manifest/definitions/zls.zig");
    _ = @import("../manifest/definitions/zwanzig.zig");
}
