# Cross-Agent Skills Pack Design

## Goal

Turn this workspace into a portable Windows-first Agent Skills package. Keep one
canonical copy of each skill in the project and expose generated Junction-based
views for Claude Code, Codex, Cursor, and Gemini CLI.

The package must support two usage modes:

- `auto`: expose the skill to each supported agent so the agent may select it
  automatically when the request matches its description.
- `manual`: retain the skill in the package without exposing it by default.
  Users may enable it later through a management script.

## Supported Agents

| Agent | User-level skill directory |
| --- | --- |
| Claude Code | `~/.claude/skills/` |
| Codex | `~/.agents/skills/` |
| Cursor | `~/.cursor/skills/` |
| Gemini CLI | `~/.gemini/skills/` |

Use one Junction per skill in each target directory. Do not Junction an entire
agent skill root to the package because per-skill links allow selective enable
and disable operations and avoid replacing agent-owned entries.

## Package Layout

```text
agent-skills-pack/
|-- skills/                         # Canonical skills exposed by default
|-- skills-disabled/                # Canonical skills retained but not exposed
|-- config/
|   `-- skills.json                 # Package policy and import metadata
|-- reports/                        # Generated import and validation reports
|-- scripts/
|   |-- AgentSkills.Common.ps1      # Shared paths, validation, and Junction helpers
|   |-- Import-AgentSkills.ps1      # Import local valid skills into canonical storage
|   |-- Sync-AgentSkills.ps1        # Reconcile generated views for all supported agents
|   |-- Enable-Skill.ps1            # Move a skill into skills/ and reconcile views
|   |-- Disable-Skill.ps1           # Move a skill into skills-disabled/ and remove views
|   `-- Test-AgentSkills.ps1        # Validate canonical storage and generated views
`-- README.md                       # User-facing setup and command reference
```

Generated reports remain local diagnostics. Scripts must not copy or print
credentials from agent configuration files.

## Canonical Skill Model

Each immediate child directory under `skills/` or `skills-disabled/` is one
canonical skill. A valid canonical skill must contain `SKILL.md` with YAML
frontmatter that includes a non-empty `name` and `description`.

Use the directory name as the package identifier. Require it to match the
frontmatter `name` after normalization to lowercase hyphen-case. Treat duplicate
identifiers and mismatched names as validation errors.

Store package-level policy in `config/skills.json`:

```json
{
  "schemaVersion": 1,
  "agents": ["claude", "codex", "cursor", "gemini"],
  "skills": {
    "example-skill": {
      "mode": "auto",
      "source": "C:\\source\\example-skill",
      "importedAt": "2026-06-01T00:00:00Z"
    }
  }
}
```

The directory location remains authoritative for enabled state. The manifest
records policy, provenance, and timestamps so the package is inspectable and
portable.

## Import

`Import-AgentSkills.ps1` scans these existing local sources when they exist:

1. `~/.agents/skills/`
2. `~/.claude/skills/`
3. `~/.cursor/skills/`
4. `~/.gemini/skills/`
5. The legacy workspace folders `claude-skills/` and
   `claude-skills-disabled/`

Only import directories with a valid `SKILL.md`. Ignore empty placeholders and
broken Junctions while recording them in the import report.

For each unique skill identifier:

1. Prefer an existing canonical copy if present.
2. Otherwise select the first valid source according to the ordered source list.
3. Preserve legacy classification when the identifier exists in either legacy
   workspace folder.
4. Place newly discovered skills in `skills-disabled/` by default.
5. Record identical duplicates as aliases in the report.
6. Record content conflicts in the report and leave the selected canonical copy
   unchanged. Do not silently overwrite it.

Copy imported source content into the package. Do not retain external Junctions
inside canonical storage.

## Synchronization

`Sync-AgentSkills.ps1` reconciles package-managed Junctions in each supported
agent directory:

1. Create missing agent skill roots when needed.
2. For every skill in `skills/`, create or repair a Junction named after the
   skill that targets the canonical package directory.
3. For every skill in `skills-disabled/`, remove only Junctions previously
   created by this package.
4. Preserve unrelated directories, files, and Junctions owned by the user or an
   agent installer.
5. Stop and report a conflict when a desired Junction path is occupied by an
   unrelated entry.

Track package-managed Junctions in `config/skills.json`. Never remove a path
solely because it has the same name as a canonical skill.

Agent-specific behavior:

- Claude Code: expose `auto` skills through `~/.claude/skills/`.
- Codex: expose `auto` skills through `~/.agents/skills/`.
- Cursor: expose `auto` skills through `~/.cursor/skills/`. Keep this dedicated
  view even when Cursor can also discover `~/.agents/skills/`, because Cursor
  versions have differed in discovery and slash-menu behavior.
- Gemini CLI: expose `auto` skills through `~/.gemini/skills/`. Gemini may also
  discover the `~/.agents/skills/` alias, but the dedicated view keeps behavior
  explicit and testable.

## Enable And Disable

`Enable-Skill.ps1 <name>` moves one canonical skill from `skills-disabled/` to
`skills/`, updates its manifest mode to `auto`, and runs synchronization.

`Disable-Skill.ps1 <name>` moves one canonical skill from `skills/` to
`skills-disabled/`, updates its manifest mode to `manual`, and runs
synchronization.

These scripts operate only on canonical package directories and
package-managed Junctions. They must refuse ambiguous states such as a skill
appearing in both canonical roots.

## Safety And Error Handling

- Resolve and validate absolute paths before recursive copies, moves, or
  removals.
- Restrict recursive operations to the package roots and explicitly named
  agent skill roots.
- Back up no external configuration files because the package does not edit
  them.
- Preserve unrelated entries in agent skill roots.
- Use terminating errors for unsafe or ambiguous operations.
- Write a timestamped JSON report for imports and validation failures.
- Never read or serialize API keys, tokens, or complete agent settings files.

Existing agent-root Junctions are preserved and reported for explicit manual
review. The package does not remove or replace whole agent skill roots.

## Validation

`Test-AgentSkills.ps1` checks:

- Every canonical skill contains `SKILL.md`.
- Required YAML frontmatter fields exist.
- Directory names match normalized skill names.
- No skill exists in both canonical roots.
- No canonical skill directory is an external Junction.
- Enabled skills have correct Junctions in all four target roots.
- Disabled skills have no package-managed Junctions in target roots.
- Managed Junction targets resolve inside this package.
- Broken Junctions and unrelated path conflicts are reported without deletion.

## Implementation Strategy

Use subagents during implementation to work on independent surfaces:

1. One subagent drafts the shared PowerShell module and synchronization logic.
2. One subagent drafts import and conflict-reporting logic.
3. One subagent drafts validation and fixture-based tests.
4. The main agent integrates the changes, reviews path-safety behavior, runs
   tests, and performs a dry-run import before touching live agent roots.

Require a dry-run mode for import, synchronization, enable, and disable scripts.
Run live synchronization only after dry-run output is reviewed.

## Acceptance Criteria

- A fresh checkout can import all valid skills found on the current machine.
- Empty placeholders and broken links are reported rather than copied.
- Every enabled canonical skill appears as a valid Junction in each supported
  agent directory.
- Disabling one skill removes only package-managed Junctions for that skill.
- Enabling it restores those Junctions.
- Re-running import and synchronization is idempotent.
- Unrelated user-managed skills remain untouched.
- Reports contain no secrets.
