"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const { spawnSync } = require("node:child_process");

const packageRoot = path.resolve(__dirname, "..");
const cli = path.join(packageRoot, "bin", "zigar-skills.js");

function run(args) {
  return spawnSync(process.execPath, [cli, ...args], {
    cwd: packageRoot,
    encoding: "utf8",
  });
}

test("lists shipped skills", () => {
  const result = run(["list"]);

  assert.equal(result.status, 0);
  assert.match(result.stdout, /^zigar-development$/m);
  assert.equal(result.stderr, "");
});

test("prints the path to a shipped skill", () => {
  const result = run(["path", "zigar-development"]);
  const skillPath = result.stdout.trim();

  assert.equal(result.status, 0);
  assert.equal(path.basename(skillPath), "zigar-development");
  assert.equal(fs.existsSync(path.join(skillPath, "SKILL.md")), true);
});

test("rejects unknown skills", () => {
  const result = run(["path", "missing-skill"]);

  assert.equal(result.status, 1);
  assert.match(result.stderr, /Unknown skill: missing-skill/);
});

test("shipped skill has complete frontmatter", () => {
  const skill = fs.readFileSync(
    path.join(packageRoot, "skills", "zigar-development", "SKILL.md"),
    "utf8",
  );

  assert.match(skill, /^---\nname: zigar-development\n/m);
  assert.match(skill, /^description: Use when developing zigar itself,/m);
  assert.doesNotMatch(skill, /TODO/);
});
