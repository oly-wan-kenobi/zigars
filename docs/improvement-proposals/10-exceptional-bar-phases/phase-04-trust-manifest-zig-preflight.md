# Phase 4 - Trust Manifest And Zig Preflight

Status: ready for implementation
Primary source sections:
[08 section 3.4](../08-exceptional-bar-action-plan.md#34-trust-disclosure),
[09 section 6](../09-exceptional-bar-deep-research-findings.md#6-trust-and-supply-chain-research)

## Objective

Make zigars' trust posture visible at connection time and catch incompatible
Zig versions before users rely on misleading tool results.

## Ordered Tasks

### P4-T1 Define The Trust Manifest Shape

Define a machine-readable trust manifest with:

- schema version;
- workspace root and cache root;
- path policy summary;
- source-write policy and `apply=true` requirement;
- subprocess classes for Zig, ZLS, optional lint/static-analysis/profiling
  backends, runtime diagnostic tools, and npm shim downloads;
- default output/body limits;
- HTTP local-only posture;
- optional backend status or a pointer to `zigars_doctor`;
- audit-log status when Phase 3 exists;
- release/checksum/attestation status when known.

Acceptance criteria:

- The manifest is deterministic except for explicitly runtime-specific fields.
- It does not claim OS sandboxing.
- It can be returned as JSON and a readable text fallback.

Likely files:

- `src/app/usecases/environment/trust.zig`
- `src/domain/trust.zig`
- `src/adapters/mcp/tools/environment.zig`

### P4-T2 Expose The Manifest At Connection Time

Expose the manifest through the `initialize` result or a clearly linked
resource if the raw initialize payload becomes too large.

Acceptance criteria:

- Clients can discover the trust manifest without already knowing a tool name.
- `initialize` remains compatible with MCP clients that ignore unknown fields.
- If exposed as a resource, it has a stable URI and is listed through the
  normal resource path.

Likely files:

- `src/adapters/mcp/server.zig`
- `src/adapters/mcp/resources.zig`
- `src/bootstrap/runtime.zig`

### P4-T3 Extend `zigars_trust_report`

Align the existing trust report with the manifest so the connection-time view
and tool view do not drift.

Acceptance criteria:

- `zigars_trust_report` includes manifest-equivalent fields or a superset.
- Existing callers remain compatible.
- Tests cover workspace/cache roots, path policy, source-write policy, backend
  classes, and audit status when available.

Likely files:

- `src/app/usecases/environment/trust.zig`
- `src/app/usecases/environment/doctor.zig`
- `src/adapters/mcp/tools/environment.zig`

### P4-T4 Add Zig Version Preflight In Doctor

Compare observed `zig version` with `build.zig.zon` `minimum_zig_version`.

Acceptance criteria:

- `zigars_doctor` reports compatible, incompatible, unavailable, and unprobed
  states.
- The result includes resolution text for mismatches.
- Tests cover exact match, incompatible version, missing Zig, and
  probe-disabled behavior.

Likely files:

- `src/app/usecases/environment/doctor.zig`
- `src/app/usecases/environment/doctor_tests.zig`
- `src/bootstrap/config.zig`

### P4-T5 Add Startup Zig Version Warning Or Failure

Add startup behavior for incompatible Zig versions.

Acceptance criteria:

- The policy is explicit: fail fast or emit a structured startup warning.
- Silent mismatch is not allowed.
- Stderr contains the same resolution as `zigars_doctor`.
- README and trust docs describe the policy.

### P4-T6 Update Trust Documentation

Update [docs/trust.md](../../trust.md), [README.md](../../../README.md), and
related setup docs.

Acceptance criteria:

- Docs explain the trust manifest and where clients can read it.
- Docs explain Zig preflight behavior.
- Docs keep optional backends optional.
- Docs keep checksum and attestation wording aligned with Phase 5 if that phase
  has landed; otherwise state current checksum-only behavior.

## Out Of Scope

- Do not implement npm attestation verification here.
- Do not add new optional backend installers.
- Do not claim byte-identical determinism.

## Validation

```sh
zig fmt build.zig build.zig.zon src tools
zig build test
zig build docs-check json-check
```

If the initialize payload or resource list changes, update representative MCP
smoke fixtures.
