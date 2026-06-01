[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:WorkspaceRoot = Split-Path -Parent $PSScriptRoot
$script:RequiredScripts = @(
    'AgentSkills.Common.ps1'
    'Initialize-AgentSkills.ps1'
    'Import-AgentSkills.ps1'
    'Sync-AgentSkills.ps1'
    'Adopt-AgentSkillViews.ps1'
    'Enable-Skill.ps1'
    'Disable-Skill.ps1'
    'Test-AgentSkills.ps1'
)
$script:Failures = 0
$script:TemporaryRoots = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-False {
    param(
        [bool]$Condition,
        [string]$Message
    )

    Assert-True -Condition (-not $Condition) -Message $Message
}

function Assert-Matches {
    param(
        [string]$Actual,
        [string]$Pattern,
        [string]$Message
    )

    if ($Actual -notmatch $Pattern) {
        throw "Assertion failed: $Message`nPattern: $Pattern`nActual:`n$Actual"
    }
}

function Invoke-Test {
    param(
        [string]$Name,
        [scriptblock]$Body
    )

    try {
        & $Body
        Write-Host "PASS: $Name"
    }
    catch {
        $script:Failures++
        Write-Host "FAIL: $Name" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function New-TemporaryRoot {
    param([string]$Label)

    $path = Join-Path ([System.IO.Path]::GetTempPath()) (
        'agent-skills-pack-{0}-{1}' -f $Label, [guid]::NewGuid().ToString('N')
    )
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $script:TemporaryRoots.Add($path)
    return $path
}

function Write-Utf8File {
    param(
        [string]$Path,
        [string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8
}

function New-Skill {
    param(
        [string]$Root,
        [string]$Name,
        [string]$Description = 'Fixture skill used by integration tests.',
        [string]$Body = '# Fixture Skill',
        [string]$FrontmatterName = $Name
    )

    $skillRoot = Join-Path $Root $Name
    New-Item -ItemType Directory -Path $skillRoot -Force | Out-Null
    Write-Utf8File -Path (Join-Path $skillRoot 'SKILL.md') -Content @"
---
name: $FrontmatterName
description: $Description
---

$Body
"@
    return $skillRoot
}

function New-FixturePackage {
    $root = New-TemporaryRoot -Label 'package'
    foreach ($relativePath in @('scripts', 'config', 'reports', 'skills', 'skills-disabled')) {
        New-Item -ItemType Directory -Path (Join-Path $root $relativePath) -Force | Out-Null
    }

    foreach ($scriptName in $script:RequiredScripts) {
        Copy-Item -LiteralPath (Join-Path $script:WorkspaceRoot "scripts\$scriptName") `
            -Destination (Join-Path $root "scripts\$scriptName")
    }

    $fixtureManifest = Join-Path $root 'config\skills.json'
    Write-Utf8File -Path $fixtureManifest -Content @'
{
  "schemaVersion": 1,
  "agents": ["claude", "codex", "cursor", "gemini"],
  "skills": {},
  "managedLinks": {}
}
'@

    return $root
}

function New-AgentRoots {
    $root = New-TemporaryRoot -Label 'agents'
    $agentRoots = @{}
    foreach ($agent in @('claude', 'codex', 'cursor', 'gemini')) {
        $agentRoot = Join-Path $root $agent
        New-Item -ItemType Directory -Path $agentRoot -Force | Out-Null
        $agentRoots[$agent] = $agentRoot
    }
    return $agentRoots
}

function New-UninitializedFixturePackage {
    $root = New-TemporaryRoot -Label 'uninitialized-package'
    New-Item -ItemType Directory -Path (Join-Path $root 'scripts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'config') -Force | Out-Null
    foreach ($scriptName in @('AgentSkills.Common.ps1', 'Initialize-AgentSkills.ps1')) {
        Copy-Item -LiteralPath (Join-Path $script:WorkspaceRoot "scripts\$scriptName") `
            -Destination (Join-Path $root "scripts\$scriptName")
    }

    Copy-Item -LiteralPath (Join-Path $script:WorkspaceRoot 'config\skills.example.json') `
        -Destination (Join-Path $root 'config\skills.example.json')
    return $root
}

function Invoke-PackScript {
    param(
        [string]$Path,
        [hashtable]$Parameters = @{}
    )

    $output = & $Path @Parameters 2>&1 | Out-String
    return $output
}

function Get-ReportEvidence {
    param(
        [string]$PackageRoot,
        [string]$Output
    )

    $reportText = @(
        Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'reports') -Filter '*.json' -File |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }
    ) -join "`n"
    return "$Output`n$reportText"
}

function ConvertTo-SingleQuotedLiteral {
    param([string]$Value)

    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-ValidatorProcess {
    param(
        [string]$PackageRoot,
        [hashtable]$AgentRoots,
        [switch]$SkipGeneratedViews
    )

    $pairs = foreach ($agent in @('claude', 'codex', 'cursor', 'gemini')) {
        '{0} = {1}' -f $agent, (ConvertTo-SingleQuotedLiteral -Value $AgentRoots[$agent])
    }
    $validatorPath = Join-Path $PackageRoot 'scripts\Test-AgentSkills.ps1'
    $skip = if ($SkipGeneratedViews) { ' -SkipGeneratedViews' } else { '' }
    $command = '$agentRoots = @{ ' + ($pairs -join '; ') + ' }; & ' +
        (ConvertTo-SingleQuotedLiteral -Value $validatorPath) +
        ' -AgentRoots $agentRoots' + $skip
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command 2>&1 | Out-String
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output
    }
}

function Test-IsJunction {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    $item = Get-Item -LiteralPath $Path -Force
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -and
        [string]$item.LinkType -eq 'Junction')
}

try {
    $missingScripts = @(
        foreach ($scriptName in $script:RequiredScripts) {
            $path = Join-Path $script:WorkspaceRoot "scripts\$scriptName"
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                $scriptName
            }
        }
    )
    if ($missingScripts.Count -gt 0) {
        throw "Missing required workspace scripts: $($missingScripts -join ', ')"
    }

    Invoke-Test 'initializer creates local state once without overwriting it' {
        $packageRoot = New-UninitializedFixturePackage
        $initializeScript = Join-Path $packageRoot 'scripts\Initialize-AgentSkills.ps1'
        $manifestPath = Join-Path $packageRoot 'config\skills.json'

        $firstOutput = Invoke-PackScript -Path $initializeScript
        Assert-True -Condition (Test-Path -LiteralPath $manifestPath -PathType Leaf) `
            -Message 'initializer should create config\skills.json from the public template'
        Assert-Matches -Actual $firstOutput -Pattern '(?i)initialized' `
            -Message 'initializer should report first-run initialization'

        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $manifest.skills | Add-Member -MemberType NoteProperty -Name 'preserve-me' `
            -Value ([pscustomobject]@{ mode = 'manual' })
        Write-Utf8File -Path $manifestPath -Content ($manifest | ConvertTo-Json -Depth 10)

        $secondOutput = Invoke-PackScript -Path $initializeScript
        $preserved = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True -Condition ($null -ne $preserved.skills.PSObject.Properties['preserve-me']) `
            -Message 'initializer must preserve an existing local manifest'
        Assert-Matches -Actual $secondOutput -Pattern '(?i)already initialized' `
            -Message 'initializer should report that existing local state was preserved'
    }

    Invoke-Test 'dry-run import reports work without mutating canonical storage' {
        $packageRoot = New-FixturePackage
        $sourceRoot = New-TemporaryRoot -Label 'import-dry-run'
        New-Skill -Root $sourceRoot -Name 'demo-skill' | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $sourceRoot 'empty-placeholder') | Out-Null

        $output = Invoke-PackScript -Path (Join-Path $packageRoot 'scripts\Import-AgentSkills.ps1') `
            -Parameters @{ DryRun = $true; SourceRoots = @($sourceRoot) }
        $evidence = Get-ReportEvidence -PackageRoot $packageRoot -Output $output

        Assert-False -Condition (Test-Path -LiteralPath (Join-Path $packageRoot 'skills\demo-skill')) `
            -Message 'dry-run import must not create an enabled canonical copy'
        Assert-False -Condition (Test-Path -LiteralPath (Join-Path $packageRoot 'skills-disabled\demo-skill')) `
            -Message 'dry-run import must not create a disabled canonical copy'
        Assert-Matches -Actual $evidence -Pattern '(?i)demo-skill' `
            -Message 'dry-run report should mention the planned skill import'
        Assert-Matches -Actual $evidence -Pattern '(?i)(placeholder|empty-placeholder)' `
            -Message 'dry-run report should mention the empty placeholder'
    }

    Invoke-Test 'live import creates a disabled canonical copy' {
        $packageRoot = New-FixturePackage
        $sourceRoot = New-TemporaryRoot -Label 'import-live'
        New-Skill -Root $sourceRoot -Name 'demo-skill' | Out-Null

        Invoke-PackScript -Path (Join-Path $packageRoot 'scripts\Import-AgentSkills.ps1') `
            -Parameters @{ SourceRoots = @($sourceRoot) } | Out-Null

        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $packageRoot 'skills-disabled\demo-skill\SKILL.md')) `
            -Message 'newly imported skills should default to disabled canonical storage'
    }

    Invoke-Test 'live import preserves an empty legacy active placeholder classification' {
        $packageRoot = New-FixturePackage
        $sourceRoot = New-TemporaryRoot -Label 'import-legacy-active-placeholder'
        New-Skill -Root $sourceRoot -Name 'demo-skill' | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $packageRoot 'claude-skills\demo-skill') -Force | Out-Null

        Invoke-PackScript -Path (Join-Path $packageRoot 'scripts\Import-AgentSkills.ps1') `
            -Parameters @{ SourceRoots = @($sourceRoot) } | Out-Null

        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $packageRoot 'skills\demo-skill\SKILL.md')) `
            -Message 'legacy active placeholder names should import into enabled canonical storage'
        Assert-False -Condition (Test-Path -LiteralPath (Join-Path $packageRoot 'skills-disabled\demo-skill')) `
            -Message 'legacy active placeholder names should not import into disabled canonical storage'
    }

    Invoke-Test 'dry-run import reports identical duplicates and content conflicts' {
        $packageRoot = New-FixturePackage
        $sourceOne = New-TemporaryRoot -Label 'import-source-one'
        $sourceTwo = New-TemporaryRoot -Label 'import-source-two'
        $sourceThree = New-TemporaryRoot -Label 'import-source-three'
        New-Skill -Root $sourceOne -Name 'shared-skill' -Body '# Same content' | Out-Null
        New-Skill -Root $sourceTwo -Name 'shared-skill' -Body '# Same content' | Out-Null
        New-Skill -Root $sourceThree -Name 'shared-skill' -Body '# Different content' | Out-Null

        $output = Invoke-PackScript -Path (Join-Path $packageRoot 'scripts\Import-AgentSkills.ps1') `
            -Parameters @{ DryRun = $true; SourceRoots = @($sourceOne, $sourceTwo, $sourceThree) }
        $evidence = Get-ReportEvidence -PackageRoot $packageRoot -Output $output

        Assert-Matches -Actual $evidence -Pattern '(?i)(duplicate|alias)' `
            -Message 'import report should distinguish an identical duplicate'
        Assert-Matches -Actual $evidence -Pattern '(?i)conflict' `
            -Message 'import report should distinguish conflicting skill content'
    }

    Invoke-Test 'dry-run sync plans views without mutating agent roots' {
        $packageRoot = New-FixturePackage
        $agentRoots = New-AgentRoots
        New-Skill -Root (Join-Path $packageRoot 'skills') -Name 'demo-skill' | Out-Null

        $output = Invoke-PackScript -Path (Join-Path $packageRoot 'scripts\Sync-AgentSkills.ps1') `
            -Parameters @{ DryRun = $true; AgentRoots = $agentRoots }
        $evidence = Get-ReportEvidence -PackageRoot $packageRoot -Output $output
        Assert-False -Condition ($evidence -match '(?i)("status"\s*:\s*"failed"|sync status:\s*failed)') `
            -Message "dry-run sync should complete before planned views are checked:`n$evidence"
        Assert-Matches -Actual $evidence `
            -Pattern '(?i)(create|planned|demo-skill)' `
            -Message 'dry-run sync should report planned work'
        foreach ($agent in $agentRoots.Keys) {
            Assert-False -Condition (Test-Path -LiteralPath (Join-Path $agentRoots[$agent] 'demo-skill')) `
                -Message "dry-run sync must not create the $agent view"
        }
    }

    Invoke-Test 'sync, disable, and enable reconcile four managed Junction views only' {
        $packageRoot = New-FixturePackage
        $agentRoots = New-AgentRoots
        New-Skill -Root (Join-Path $packageRoot 'skills') -Name 'demo-skill' | Out-Null
        $unrelatedPath = Join-Path $agentRoots['claude'] 'unrelated-skill'
        New-Skill -Root $agentRoots['claude'] -Name 'unrelated-skill' | Out-Null

        $syncOutput = Invoke-PackScript -Path (Join-Path $packageRoot 'scripts\Sync-AgentSkills.ps1') `
            -Parameters @{ AgentRoots = $agentRoots }
        $syncEvidence = Get-ReportEvidence -PackageRoot $packageRoot -Output $syncOutput
        Assert-False -Condition ($syncEvidence -match '(?i)("status"\s*:\s*"failed"|sync status:\s*failed)') `
            -Message "sync should complete before Junction views are checked:`n$syncEvidence"
        foreach ($agent in $agentRoots.Keys) {
            Assert-True -Condition (Test-IsJunction -Path (Join-Path $agentRoots[$agent] 'demo-skill')) `
                -Message "sync should create the $agent Junction view"
        }

        Invoke-PackScript -Path (Join-Path $packageRoot 'scripts\Disable-Skill.ps1') `
            -Parameters @{ Name = 'demo-skill'; AgentRoots = $agentRoots } | Out-Null
        foreach ($agent in $agentRoots.Keys) {
            Assert-False -Condition (Test-Path -LiteralPath (Join-Path $agentRoots[$agent] 'demo-skill')) `
                -Message "disable should remove the package-managed $agent view"
        }
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $unrelatedPath 'SKILL.md')) `
            -Message 'disable should preserve unrelated paths'

        Invoke-PackScript -Path (Join-Path $packageRoot 'scripts\Enable-Skill.ps1') `
            -Parameters @{ Name = 'demo-skill'; AgentRoots = $agentRoots } | Out-Null
        foreach ($agent in $agentRoots.Keys) {
            Assert-True -Condition (Test-IsJunction -Path (Join-Path $agentRoots[$agent] 'demo-skill')) `
                -Message "enable should restore the package-managed $agent Junction view"
        }

        $validation = Invoke-ValidatorProcess -PackageRoot $packageRoot -AgentRoots $agentRoots
        Assert-True -Condition ($validation.ExitCode -eq 0) `
            -Message "validator should accept synchronized views: $($validation.Output)"
    }

    Invoke-Test 'sync reports occupied unrelated paths without replacing them' {
        $packageRoot = New-FixturePackage
        $agentRoots = New-AgentRoots
        New-Skill -Root (Join-Path $packageRoot 'skills') -Name 'demo-skill' | Out-Null
        $conflictPath = Join-Path $agentRoots['claude'] 'demo-skill'
        New-Item -ItemType Directory -Path $conflictPath | Out-Null
        Write-Utf8File -Path (Join-Path $conflictPath 'keep.txt') -Content 'preserve me'

        $output = Invoke-PackScript -Path (Join-Path $packageRoot 'scripts\Sync-AgentSkills.ps1') `
            -Parameters @{ AgentRoots = $agentRoots }
        $evidence = Get-ReportEvidence -PackageRoot $packageRoot -Output $output

        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $conflictPath 'keep.txt')) `
            -Message 'sync should preserve an unrelated occupied path'
        Assert-False -Condition ($evidence -match '(?i)("status"\s*:\s*"failed"|sync status:\s*failed)') `
            -Message "sync should report unrelated occupied paths without failing:`n$evidence"
        Assert-Matches -Actual $evidence `
            -Pattern '(?i)(conflict|occupied|unrelated)' `
            -Message 'sync should report an unrelated occupied-path conflict'
    }

    Invoke-Test 'adoption dry-run preserves matching directories and live adoption backs them up before linking' {
        $packageRoot = New-FixturePackage
        $agentRoots = New-AgentRoots
        New-Skill -Root (Join-Path $packageRoot 'skills') -Name 'demo-skill' | Out-Null
        New-Skill -Root $agentRoots['codex'] -Name 'demo-skill' | Out-Null

        $dryRunOutput = Invoke-PackScript -Path (Join-Path $packageRoot 'scripts\Adopt-AgentSkillViews.ps1') `
            -Parameters @{ Agent = 'codex'; AgentRoots = $agentRoots; DryRun = $true }
        $dryRunEvidence = Get-ReportEvidence -PackageRoot $packageRoot -Output $dryRunOutput
        Assert-Matches -Actual $dryRunEvidence -Pattern '(?i)(planned-adopt|backup|demo-skill)' `
            -Message 'adoption dry-run should report the matching directory migration'
        Assert-False -Condition (Test-IsJunction -Path (Join-Path $agentRoots['codex'] 'demo-skill')) `
            -Message 'adoption dry-run must not replace the existing directory'

        $liveOutput = Invoke-PackScript -Path (Join-Path $packageRoot 'scripts\Adopt-AgentSkillViews.ps1') `
            -Parameters @{ Agent = 'codex'; AgentRoots = $agentRoots }
        $liveEvidence = Get-ReportEvidence -PackageRoot $packageRoot -Output $liveOutput
        Assert-False -Condition ($liveEvidence -match '(?i)("status"\s*:\s*"failed"|adoption status:\s*failed)') `
            -Message "live adoption should complete for matching directories:`n$liveEvidence"
        Assert-True -Condition (Test-IsJunction -Path (Join-Path $agentRoots['codex'] 'demo-skill')) `
            -Message 'live adoption should replace the matching directory with a Junction'
        $backups = @(Get-ChildItem -LiteralPath (Join-Path $packageRoot 'backups') -Recurse -Filter 'SKILL.md' -File)
        Assert-True -Condition ($backups.Count -eq 1) `
            -Message 'live adoption should retain one backup copy before linking'
    }

    Invoke-Test 'adoption refuses directories whose content differs from the canonical skill' {
        $packageRoot = New-FixturePackage
        $agentRoots = New-AgentRoots
        New-Skill -Root (Join-Path $packageRoot 'skills') -Name 'demo-skill' -Body '# Canonical' | Out-Null
        New-Skill -Root $agentRoots['codex'] -Name 'demo-skill' -Body '# Different' | Out-Null

        $output = Invoke-PackScript -Path (Join-Path $packageRoot 'scripts\Adopt-AgentSkillViews.ps1') `
            -Parameters @{ Agent = 'codex'; AgentRoots = $agentRoots }
        $evidence = Get-ReportEvidence -PackageRoot $packageRoot -Output $output

        Assert-False -Condition (Test-IsJunction -Path (Join-Path $agentRoots['codex'] 'demo-skill')) `
            -Message 'adoption must preserve a differing external directory'
        Assert-Matches -Actual $evidence -Pattern '(?i)(different|fingerprint|refus)' `
            -Message 'adoption should report why differing content was preserved'
    }

    Invoke-Test 'validator rejects invalid frontmatter' {
        $packageRoot = New-FixturePackage
        $agentRoots = New-AgentRoots
        Write-Utf8File -Path (Join-Path $packageRoot 'skills-disabled\invalid-skill\SKILL.md') -Content @'
---
name: invalid-skill
---

# Missing description
'@

        $validation = Invoke-ValidatorProcess -PackageRoot $packageRoot -AgentRoots $agentRoots `
            -SkipGeneratedViews
        Assert-True -Condition ($validation.ExitCode -ne 0) `
            -Message 'validator should return non-zero for invalid frontmatter'
        Assert-Matches -Actual $validation.Output -Pattern '(?i)(description|metadata|frontmatter)' `
            -Message 'validator should explain the invalid metadata'
    }

    Invoke-Test 'validator rejects duplicate canonical roots' {
        $packageRoot = New-FixturePackage
        $agentRoots = New-AgentRoots
        New-Skill -Root (Join-Path $packageRoot 'skills') -Name 'duplicate-skill' | Out-Null
        New-Skill -Root (Join-Path $packageRoot 'skills-disabled') -Name 'duplicate-skill' | Out-Null

        $validation = Invoke-ValidatorProcess -PackageRoot $packageRoot -AgentRoots $agentRoots `
            -SkipGeneratedViews
        Assert-True -Condition ($validation.ExitCode -ne 0) `
            -Message 'validator should return non-zero for duplicate canonical roots'
        Assert-Matches -Actual $validation.Output -Pattern '(?i)duplicate' `
            -Message 'validator should explain the duplicate canonical skill'
    }
}
finally {
    foreach ($temporaryRoot in $script:TemporaryRoots) {
        if (Test-Path -LiteralPath $temporaryRoot) {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($script:Failures -gt 0) {
    throw "$($script:Failures) integration test(s) failed."
}

Write-Host 'All Agent Skills pack integration tests passed.'
