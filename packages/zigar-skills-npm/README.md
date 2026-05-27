# @zigars/skills

`@zigars/skills` ships client-consumable skills for zigar-aware development
workflows. It is separate from `@zigars/mcp`: the MCP package starts the local
zigar server, while this package distributes agent instructions that tell clients
how to use zigar effectively.

The package has no install side effects. It does not configure an MCP client,
copy files into a user profile, or claim that skills are part of the base MCP
protocol.

## Usage

List shipped skills:

```sh
npx -y @zigars/skills@0.2.0 list
```

Print the package skill directory:

```sh
npx -y @zigars/skills@0.2.0 path
```

Print one skill directory:

```sh
npx -y @zigars/skills@0.2.0 path zigar-development
```

Clients that support filesystem skills can copy or reference the printed skill
directory according to that client's documentation.

## Shipped Skills

- `zigar-development`: dogfood zigar while developing zigar itself, including
  server changes, repo docs, package tooling, validation, and skill refinement.

## Maintainer Notes

Keep skills under `skills/<skill-name>/`. Each skill should contain a concise
`SKILL.md`, optional `agents/openai.yaml`, and optional one-level references.
Do not duplicate zigar's MCP tools in skills; route agents to the connected MCP
server and keep deterministic behavior inside the server.

Validate before publishing:

```sh
npm test
npm run pack:dry
```

Also run the skill validator from the client skill tooling you use when it is
available.
