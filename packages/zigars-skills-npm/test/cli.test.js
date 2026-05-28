"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const { spawnSync } = require("node:child_process");

const packageRoot = path.resolve(__dirname, "..");
const cli = path.join(packageRoot, "bin", "zigars-skills.js");
const skillsRoot = path.join(packageRoot, "skills");
const expectedSkills = [
  "zigars-ci-forensics",
  "zigars-compile-error-triage",
  "zigars-comptime-diagnose",
  "zigars-cross-target-artifact-auditor",
  "zigars-dependency-steward",
  "zigars-docs-example-steward",
  "zigars-evidence-contract",
  "zigars-ffi-abi-guardian",
  "zigars-handoff-resume",
  "zigars-incremental-validation",
  "zigars-io-016-migration",
  "zigars-memory-fuzz-forensics",
  "zigars-performance-regression-investigator",
  "zigars-release-claim-auditor",
  "zigars-runtime-crash-forensics",
  "zigars-safe-refactor",
  "zigars-toolchain-pin-and-doctor",
  "zigars-zig-version-migrator",
  "zigars-zon-hash-sync",
];

function run(args) {
  return spawnSync(process.execPath, [cli, ...args], {
    cwd: packageRoot,
    encoding: "utf8",
  });
}

test("lists shipped skills", () => {
  const result = run(["list"]);

  assert.equal(result.status, 0);
  assert.deepEqual(result.stdout.trim().split("\n"), expectedSkills);
  assert.equal(result.stderr, "");
});

test("prints the path to a shipped skill", () => {
  for (const skill of expectedSkills) {
    const result = run(["path", skill]);
    const skillPath = result.stdout.trim();

    assert.equal(result.status, 0);
    assert.equal(path.basename(skillPath), skill);
    assert.equal(fs.existsSync(path.join(skillPath, "SKILL.md")), true);
  }
});

test("prints the package root for plugin and extension clients", () => {
  const result = run(["root"]);

  assert.equal(result.status, 0);
  assert.equal(result.stdout.trim(), packageRoot);
  assert.equal(fs.existsSync(path.join(packageRoot, ".claude-plugin", "plugin.json")), true);
  assert.equal(fs.existsSync(path.join(packageRoot, "gemini-extension.json")), true);
});

test("rejects unknown skills", () => {
  const result = run(["path", "missing-skill"]);

  assert.equal(result.status, 1);
  assert.match(result.stderr, /Unknown skill: missing-skill/);
});

test("shipped skills have complete frontmatter", () => {
  for (const name of expectedSkills) {
    const skill = fs.readFileSync(path.join(skillsRoot, name, "SKILL.md"), "utf8");

    assert.match(skill, new RegExp(`^---\\nname: ${name}\\n`, "m"));
    assert.match(skill, /^description: Use when /m);
    assert.doesNotMatch(skill, /TODO/);
  }
});

test("shipped skills have OpenAI interface metadata", () => {
  for (const name of expectedSkills) {
    const metadata = fs.readFileSync(
      path.join(skillsRoot, name, "agents", "openai.yaml"),
      "utf8",
    );

    assert.match(metadata, /^interface:\n/m);
    assert.match(metadata, /display_name: ".+"/);
    assert.match(metadata, /short_description: ".+"/);
    assert.match(metadata, new RegExp(`default_prompt: ".+\\$${name}.+"`));
  }
});

test("ships Claude Code plugin metadata", () => {
  const manifest = JSON.parse(
    fs.readFileSync(path.join(packageRoot, ".claude-plugin", "plugin.json"), "utf8"),
  );

  assert.equal(manifest.name, "zigars-skills");
  assert.equal(manifest.version, "0.2.0");
  assert.match(manifest.description, /Agent skills/);
  assert.equal(manifest.keywords.includes("claude-code"), true);
});

test("ships Gemini CLI extension metadata", () => {
  const manifest = JSON.parse(
    fs.readFileSync(path.join(packageRoot, "gemini-extension.json"), "utf8"),
  );

  assert.equal(manifest.name, "zigars-skills");
  assert.equal(manifest.version, "0.2.0");
  assert.match(manifest.description, /Agent skills/);
});
