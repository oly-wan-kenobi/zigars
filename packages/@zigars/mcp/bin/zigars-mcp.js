#!/usr/bin/env node

"use strict";

const { main } = require("../dist/src/cli");

main(process.argv.slice(2), {
  stdout: process.stdout,
  stderr: process.stderr,
  platform: process.platform,
  arch: process.arch,
});
