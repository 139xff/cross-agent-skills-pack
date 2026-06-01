# Cross-Agent Skills Pack

This is a Windows-first package for keeping one canonical copy of each Agent
Skill and exposing selected skills to supported agents through per-skill NTFS
Junctions.

## Supported Agents

| Agent | Generated user-level view |
| --- | --- |
| Claude Code | `~/.claude/skills/` |
| Codex | `~/.agents/skills/` |
| Cursor | `~/.cursor/skills/` |
| Gemini CLI | `~/.gemini/skills/` |

Each generated view contains one Junction per enabled skill. The package never
replaces an entire agent skill directory with a Junction.

## Source Of Truth

- `skills/` contains canonical skills exposed to all four agents.
- `skills-disabled/` contains canonical skills retained for manual use.
- `config/skills.json` records policy, provenance, and managed Junctions.
- Agent skill directories are generated views, not editing locations.
- `reports/` contains local JSON diagnostics from import, sync, and validation.

Edit a canonical copy in this package, then run synchronization. Do not edit a
generated Junction view as if it were a separate copy.

## Requirements

Use Windows PowerShell 5.1 or newer on Windows with NTFS-backed agent skill
directories. Junction creation is intentionally Windows-specific. The scripts
do not create symbolic links or manage non-Windows agent layouts.

## Setup

Initialize local state after cloning. The generated `config/skills.json`,
canonical skill directories, agent views, reports, backups, and vendored
third-party skills are intentionally excluded from version control:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Initialize-AgentSkills.ps1
```

Run setup from the package root and review dry-run reports before making live
changes:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Import-AgentSkills.ps1 -DryRun
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Sync-AgentSkills.ps1 -DryRun
```

Import valid local skills into canonical storage, validate the copies, then
review synchronization once more:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Import-AgentSkills.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-AgentSkills.ps1 -SkipGeneratedViews
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Sync-AgentSkills.ps1 -DryRun
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Sync-AgentSkills.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-AgentSkills.ps1
```

Newly discovered skills default to `skills-disabled/`. Skills found in the
legacy workspace folders retain their active or disabled classification.

## Enable And Disable

Preview changes first:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Enable-Skill.ps1 demo-skill -DryRun
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Disable-Skill.ps1 demo-skill -DryRun
```

Apply the reviewed change:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Enable-Skill.ps1 demo-skill
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Disable-Skill.ps1 demo-skill
```

Enabling moves the canonical directory into `skills/` and restores all four
generated views. Disabling moves it into `skills-disabled/` and removes only
Junctions that the package can verify as managed.

## Chinese Keywords

`config/skill-tags.zh-CN.json` assigns multiple Chinese domain labels to every
canonical skill. Apply changes after editing the tag index:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Apply-ChineseSkillTags.ps1 -DryRun
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Apply-ChineseSkillTags.ps1
```

The script stores structured `tagsZh` arrays in `config/skills.json` and
appends the same labels to each canonical `SKILL.md` description. Agent-native
skill discovery reads descriptions, so enabled skills can use the Chinese
labels as semantic routing keywords. Disabled skills still require explicit
enablement before they become discoverable by generated agent views.

## Adopt Existing Agent Directories

Synchronization preserves an existing ordinary directory when it occupies a
desired generated-view path. After reviewing the conflict report, migrate
matching directories explicitly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Adopt-AgentSkillViews.ps1 -Agent codex -DryRun
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Adopt-AgentSkillViews.ps1 -Agent codex
```

Adoption compares the complete directory fingerprint first. It moves only
identical ordinary directories into `backups/`, then creates package-managed
Junctions. It preserves differing content, files, and existing reparse points.

## Safety

Import copies skill directories into the package and does not retain external
Junctions as canonical storage. Synchronization preserves unrelated files,
directories, and Junctions. An occupied desired path is reported as a conflict
instead of being overwritten.

Removal requires manifest ownership and a matching package target. Managed
targets must stay inside this package. Validation reports invalid metadata,
duplicate canonical roots, external or broken Junctions, stale disabled views,
and unrelated generated-view conflicts without deleting anything.

The scripts read skill frontmatter and the package manifest only. They do not
read or serialize agent credentials or complete agent settings files. Existing
agent-root reparse points are preserved and reported for explicit manual review.

## Validation And Tests

Validate canonical storage without inspecting generated views:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-AgentSkills.ps1 -SkipGeneratedViews
```

Run the isolated fixture integration suite:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-AgentSkillsPack.ps1
```

The fixture suite copies scripts into a temporary package and uses temporary
fake agent roots. It does not synchronize live agent directories.

## Open Source Scope

This repository publishes the MIT-licensed synchronization framework, tests,
documentation, manifest template, and optional Chinese keyword index. It does
not redistribute locally imported skills or vendored third-party bundles.
Install third-party skills from their upstream repositories and review their
licenses before importing them into local canonical storage.
