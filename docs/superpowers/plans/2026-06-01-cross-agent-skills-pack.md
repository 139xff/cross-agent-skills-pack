# Cross-Agent Skills Pack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Windows-first portable Agent Skills package that imports local skills once and exposes selected skills to Claude Code, Codex, Cursor, and Gemini CLI through package-managed Junctions.

**Architecture:** Keep canonical skill copies under `skills/` and `skills-disabled/`. Use a shared PowerShell module for manifest handling, frontmatter validation, safe path checks, reports, and Junction operations. Keep agent roots as generated views and require `-DryRun` support before live filesystem changes.

**Tech Stack:** PowerShell 5.1+, JSON manifests, NTFS Junctions, fixture-based PowerShell integration tests.

---

### Task 1: Shared PowerShell Module

**Files:**
- Create: `scripts/AgentSkills.Common.ps1`
- Create: `config/skills.json`

- [ ] **Step 1: Define the manifest schema**

Create `config/skills.json` with:

```json
{
  "schemaVersion": 1,
  "agents": ["claude", "codex", "cursor", "gemini"],
  "skills": {},
  "managedLinks": {}
}
```

- [ ] **Step 2: Implement shared helpers**

Create `scripts/AgentSkills.Common.ps1` with functions for:

```powershell
Get-AgentSkillsPackageRoot
Get-AgentSkillRoots
Read-AgentSkillsManifest
Write-AgentSkillsManifest
Normalize-SkillName
Get-SkillMetadata
Test-PathWithinRoot
Assert-PathWithinRoot
Get-DirectoryFingerprint
Write-AgentSkillsReport
Get-ReparsePointTarget
Test-PackageManagedLink
Ensure-AgentSkillRoot
New-PackageSkillJunction
Remove-PackageSkillJunction
```

Require `Get-SkillMetadata` to parse the first YAML frontmatter block without
loading agent settings. Require Junction removal helpers to validate the target
and manifest ownership before removal.

- [ ] **Step 3: Verify module syntax**

Run:

```powershell
$null = [System.Management.Automation.Language.Parser]::ParseFile(
  "$PWD\scripts\AgentSkills.Common.ps1",
  [ref]$null,
  [ref]$null
)
```

Expected: exit code `0`.

### Task 2: Synchronization

**Files:**
- Create: `scripts/Sync-AgentSkills.ps1`

- [ ] **Step 1: Add a failing fixture scenario**

Use a temporary package root and temporary agent roots. Place one valid skill in
`skills/demo-skill/SKILL.md`, invoke synchronization with `-DryRun`, and assert
that no Junction is created while the result reports a planned create action.

- [ ] **Step 2: Implement synchronization**

Create `scripts/Sync-AgentSkills.ps1` with:

```powershell
param(
  [switch]$DryRun,
  [hashtable]$AgentRoots
)
```

Reconcile enabled skills to each agent root. Remove only links recorded in
`managedLinks`. Preserve unrelated entries and report agent-root reparse points
for explicit manual review.

- [ ] **Step 3: Verify dry-run**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Sync-AgentSkills.ps1 -DryRun
```

Expected: exit code `0`, JSON report path printed, no live agent-root mutation.

### Task 3: Import

**Files:**
- Create: `scripts/Import-AgentSkills.ps1`

- [ ] **Step 1: Add a failing fixture scenario**

Use temporary source roots containing one valid skill, one empty directory, one
duplicate valid skill, and one conflicting skill. Invoke import with `-DryRun`
and assert that the report distinguishes planned imports, placeholders,
duplicates, and conflicts without copying files.

- [ ] **Step 2: Implement import**

Create `scripts/Import-AgentSkills.ps1` with:

```powershell
param(
  [switch]$DryRun,
  [string[]]$SourceRoots,
  [switch]$SyncAfterImport
)
```

Use the ordered default roots from the design when `-SourceRoots` is omitted.
Copy valid skill folders into canonical storage, dereferencing Junction content.
Preserve legacy active/disabled classification, default newly found skills to
disabled, and never silently overwrite a canonical copy.

- [ ] **Step 3: Verify dry-run**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Import-AgentSkills.ps1 -DryRun
```

Expected: exit code `0`, report path printed, no canonical skill copies created.

### Task 4: Enable And Disable Commands

**Files:**
- Create: `scripts/Enable-Skill.ps1`
- Create: `scripts/Disable-Skill.ps1`

- [ ] **Step 1: Add failing fixture scenarios**

Test that enable moves a disabled canonical skill into `skills/`, updates its
manifest mode, and invokes sync. Test that disable performs the inverse. Test
that either command refuses a skill present in both canonical roots.

- [ ] **Step 2: Implement commands**

Create both scripts with:

```powershell
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$Name,
  [switch]$DryRun,
  [hashtable]$AgentRoots
)
```

Resolve absolute source and destination paths under the package root before
moving. Delegate generated-view reconciliation to `Sync-AgentSkills.ps1`.

- [ ] **Step 3: Verify syntax**

Parse both scripts with the PowerShell parser. Expected: exit code `0`.

### Task 5: Validation, Integration Tests, And Documentation

**Files:**
- Create: `scripts/Test-AgentSkills.ps1`
- Create: `tests/Test-AgentSkillsPack.ps1`
- Create: `README.md`
- Create: `.gitignore`

- [ ] **Step 1: Implement validation command**

Create `scripts/Test-AgentSkills.ps1` with:

```powershell
param(
  [hashtable]$AgentRoots,
  [switch]$SkipGeneratedViews
)
```

Validate canonical metadata, duplicate roots, external Junctions, enabled and
disabled generated views, managed link targets, broken links, and unrelated
conflicts. Print a summary and return non-zero on errors.

- [ ] **Step 2: Implement fixture-based integration tests**

Create `tests/Test-AgentSkillsPack.ps1` using only built-in PowerShell. Create a
temporary package copy of the scripts and isolated fake agent roots. Cover:

```text
valid import
dry-run import has no mutations
placeholder reporting
duplicate and conflict reporting
sync creates four Junction views
dry-run sync has no mutations
disable removes managed links only
enable restores links
unrelated paths are preserved
validation catches invalid frontmatter
validation catches duplicate canonical roots
```

- [ ] **Step 3: Document usage**

Create `README.md` with setup, dry-run-first commands, live commands, supported
agents, source-of-truth rules, and safety behavior. Create `.gitignore` to ignore
generated `reports/*.json`.

- [ ] **Step 4: Run integration tests**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-AgentSkillsPack.ps1
```

Expected: all assertions pass and exit code `0`.

### Task 6: Live Import And Dry-Run Reconciliation

**Files:**
- Generated: `skills/**`
- Generated: `skills-disabled/**`
- Modify: `config/skills.json`
- Generated: `reports/*.json`

- [ ] **Step 1: Dry-run import**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Import-AgentSkills.ps1 -DryRun
```

Expected: valid skills are planned for import; empty placeholders and broken
links are reported; no canonical files change.

- [ ] **Step 2: Import canonical copies**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Import-AgentSkills.ps1
```

Expected: valid skill folders are copied into canonical storage and the manifest
records policy and provenance.

- [ ] **Step 3: Validate canonical package**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-AgentSkills.ps1 -SkipGeneratedViews
```

Expected: exit code `0`.

- [ ] **Step 4: Dry-run synchronization**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Sync-AgentSkills.ps1 -DryRun
```

Expected: planned Junction changes and any occupied-path conflicts are reported.
Do not run live synchronization without reviewing this report.
