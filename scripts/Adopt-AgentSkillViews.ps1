[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('claude', 'codex', 'cursor', 'gemini')]
    [string]$Agent,

    [switch]$DryRun,

    [hashtable]$AgentRoots
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'AgentSkills.Common.ps1')

function Add-AdoptionAction {
    param(
        [System.Collections.IList]$Actions,
        [string]$Action,
        [string]$Skill,
        [string]$Path,
        [string]$TargetPath,
        [AllowNull()]
        [string]$BackupPath
    )

    [void]$Actions.Add([pscustomobject]@{
            action     = $Action
            agent      = $Agent
            skill      = $Skill
            path       = $Path
            targetPath = $TargetPath
            backupPath = $BackupPath
        })
}

function Add-AdoptionConcern {
    param(
        [System.Collections.IList]$Concerns,
        [string]$Type,
        [AllowNull()]
        [string]$Skill,
        [AllowNull()]
        [string]$Path,
        [string]$Message
    )

    [void]$Concerns.Add([pscustomobject]@{
            type    = $Type
            agent   = $Agent
            skill   = $Skill
            path    = $Path
            message = $Message
        })
}

$actions = New-Object System.Collections.ArrayList
$concerns = New-Object System.Collections.ArrayList
$changedFiles = New-Object System.Collections.ArrayList
$packageRoot = ConvertTo-AgentSkillsFullPath -Path (Join-Path $PSScriptRoot '..')
$status = $(if ($DryRun) { 'dry-run' } else { 'completed' })
$fatalError = $null

try {
    $packageRoot = Get-AgentSkillsPackageRoot
    $enabledRoot = Assert-PathWithinRoot -Path (Join-Path $packageRoot 'skills') -Root $packageRoot
    $backupsRoot = Assert-PathWithinRoot -Path (Join-Path $packageRoot 'backups') -Root $packageRoot
    $batchName = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $batchRoot = Assert-PathWithinRoot -Path (Join-Path (Join-Path $backupsRoot $batchName) $Agent) -Root $backupsRoot
    $manifest = Read-AgentSkillsManifest -PackageRoot $packageRoot
    $resolvedAgentRoots = Get-AgentSkillRoots -AgentRoots $AgentRoots
    $agentRoot = ConvertTo-AgentSkillsFullPath -Path ([string]$resolvedAgentRoots[$Agent])
    $agentRootItem = Get-AgentSkillsPathItem -Path $agentRoot
    $manifestChanged = $false

    if ($null -eq $agentRootItem -or -not $agentRootItem.PSIsContainer) {
        throw "Agent skill root is unavailable: $agentRoot"
    }

    if ($agentRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Agent skill root must not be a reparse point: $agentRoot"
    }

    foreach ($skillDirectory in @(Get-ChildItem -LiteralPath $enabledRoot -Force -Directory | Sort-Object Name)) {
        $skillName = Normalize-SkillName -Name $skillDirectory.Name
        if ($skillDirectory.Name -cne $skillName) {
            Add-AdoptionConcern `
                -Concerns $concerns `
                -Type 'invalid-canonical-name' `
                -Skill $skillDirectory.Name `
                -Path $skillDirectory.FullName `
                -Message "Canonical directory name must match normalized skill name '$skillName'."
            continue
        }

        $targetPath = Assert-PathWithinRoot -Path $skillDirectory.FullName -Root $enabledRoot
        $linkPath = Assert-PathWithinRoot -Path (Join-Path $agentRoot $skillName) -Root $agentRoot
        $item = Get-AgentSkillsPathItem -Path $linkPath

        if ($null -eq $item) {
            continue
        }

        if (Test-PackageManagedLink `
                -Manifest $manifest `
                -Agent $Agent `
                -SkillName $skillName `
                -LinkPath $linkPath `
                -TargetPath $targetPath `
                -PackageRoot $packageRoot) {
            Add-AdoptionAction `
                -Actions $actions `
                -Action 'already-managed' `
                -Skill $skillName `
                -Path $linkPath `
                -TargetPath $targetPath `
                -BackupPath $null
            continue
        }

        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Add-AdoptionConcern `
                -Concerns $concerns `
                -Type 'occupied-reparse-point' `
                -Skill $skillName `
                -Path $linkPath `
                -Message 'Existing path is a reparse point and was preserved.'
            continue
        }

        if (-not $item.PSIsContainer) {
            Add-AdoptionConcern `
                -Concerns $concerns `
                -Type 'occupied-non-directory' `
                -Skill $skillName `
                -Path $linkPath `
                -Message 'Existing path is not a directory and was preserved.'
            continue
        }

        $targetFingerprint = Get-DirectoryFingerprint -Path $targetPath
        $existingFingerprint = Get-DirectoryFingerprint -Path $linkPath
        if ($targetFingerprint -ne $existingFingerprint) {
            Add-AdoptionConcern `
                -Concerns $concerns `
                -Type 'fingerprint-mismatch' `
                -Skill $skillName `
                -Path $linkPath `
                -Message 'Existing directory content differs from the canonical skill and was preserved.'
            continue
        }

        $backupPath = Assert-PathWithinRoot -Path (Join-Path $batchRoot $skillName) -Root $backupsRoot
        Add-AdoptionAction `
            -Actions $actions `
            -Action $(if ($DryRun) { 'planned-adopt' } else { 'adopted' }) `
            -Skill $skillName `
            -Path $linkPath `
            -TargetPath $targetPath `
            -BackupPath $backupPath

        if ($DryRun) {
            continue
        }

        if (Test-Path -LiteralPath $backupPath) {
            throw "Backup path already exists: $backupPath"
        }

        New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force | Out-Null
        Move-Item -LiteralPath $linkPath -Destination $backupPath -ErrorAction Stop
        try {
            New-PackageSkillJunction `
                -Manifest $manifest `
                -Agent $Agent `
                -SkillName $skillName `
                -AgentSkillRoot $agentRoot `
                -TargetPath $targetPath `
                -PackageRoot $packageRoot | Out-Null
            $manifestChanged = $true
        }
        catch {
            if (-not (Test-Path -LiteralPath $linkPath) -and (Test-Path -LiteralPath $backupPath)) {
                Move-Item -LiteralPath $backupPath -Destination $linkPath -ErrorAction Stop
            }

            throw
        }
    }

    if ($manifestChanged) {
        $manifestPath = Write-AgentSkillsManifest -Manifest $manifest -PackageRoot $packageRoot
        [void]$changedFiles.Add($manifestPath)
    }

    if ($concerns.Count -gt 0) {
        $status = $(if ($DryRun) { 'dry-run-with-concerns' } else { 'completed-with-concerns' })
    }
}
catch {
    $fatalError = $_
    $status = 'failed'
    Add-AdoptionConcern `
        -Concerns $concerns `
        -Type 'fatal-error' `
        -Skill $null `
        -Path $null `
        -Message $_.Exception.Message
}

$report = [pscustomobject]@{
    schemaVersion = 1
    operation     = 'adopt'
    generatedAt   = [DateTime]::UtcNow.ToString('o')
    status        = $status
    dryRun        = [bool]$DryRun
    agent         = $Agent
    actions       = @($actions)
    changedFiles  = @($changedFiles)
    concerns      = @($concerns)
    summary       = [pscustomobject]@{
        actionCount  = $actions.Count
        concernCount = $concerns.Count
    }
}

try {
    $reportPath = Write-AgentSkillsReport -ReportType 'adopt' -Data $report -PackageRoot $packageRoot
    Write-Output "Adoption status: $status; actions: $($actions.Count); concerns: $($concerns.Count)"
    Write-Output "Report: $reportPath"
}
catch {
    Write-Error "Unable to write adoption report: $($_.Exception.Message)"
    exit 1
}

if ($null -ne $fatalError) {
    exit 1
}
