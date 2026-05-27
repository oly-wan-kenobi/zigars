#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");

const packageRoot = path.resolve(__dirname, "..");
const skillsRoot = path.join(packageRoot, "skills");

function listSkills() {
  return fs
    .readdirSync(skillsRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort();
}

function printHelp() {
  console.log(`zigar-skills

Usage:
  zigar-skills list
  zigar-skills path [skill-name]
  zigar-skills root
  zigar-skills help
`);
}

function main(argv) {
  const [command = "list", skillName] = argv;

  if (command === "help" || command === "--help" || command === "-h") {
    printHelp();
    return 0;
  }

  if (command === "list") {
    for (const name of listSkills()) {
      console.log(name);
    }
    return 0;
  }

  if (command === "root") {
    console.log(packageRoot);
    return 0;
  }

  if (command === "path") {
    if (skillName === undefined) {
      console.log(skillsRoot);
      return 0;
    }

    if (!/^[a-z0-9-]+$/.test(skillName)) {
      console.error(`Invalid skill name: ${skillName}`);
      return 2;
    }

    const skillPath = path.join(skillsRoot, skillName);
    if (!fs.existsSync(path.join(skillPath, "SKILL.md"))) {
      console.error(`Unknown skill: ${skillName}`);
      return 1;
    }

    console.log(skillPath);
    return 0;
  }

  console.error(`Unknown command: ${command}`);
  printHelp();
  return 2;
}

process.exitCode = main(process.argv.slice(2));
