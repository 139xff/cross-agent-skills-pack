param(
    [switch]$DryRun,
    [hashtable]$AgentRoots
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'AgentSkills.Common.ps1')

function Add-SyncAction {
    param(
        [System.Collections.IList]$Actions,
        [string]$Action,
        [string]$Agent,
        [AllowNull()]
        [string]$Skill,
        [string]$Path,
        [AllowNull()]
        [string]$TargetPath
    )

    [void]$Actions.Add([pscustomobject]@{
            action     = $Action
            agent      = $Agent
            skill      = $Skill
            path       = $Path
            targetPath = $TargetPath
        })
}

function Add-SyncConcern {
    param(
        [System.Collections.IList]$Concerns,
        [string]$Type,
        [AllowNull()]
        [string]$Agent,
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

function Get-SyncPathItem {
    param([string]$Path)

    $item = Get-AgentSkillsPathItem -Path $Path
    if ($null -ne $item) {
        return $item
    }

    $parent = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    if ([string]::IsNullOrWhiteSpace($parent) -or
        -not (Test-Path -LiteralPath $parent -PathType Container)) {
        return $null
    }

    return Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $leaf } |
        Select-Object -First 1
}

function Test-SyncReparsePoint {
    param([AllowNull()][object]$Item)

    return $null -ne $Item -and
        (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-SyncReparsePointTarget {
    param(
        [string]$Path,
        [AllowNull()]
        [object]$Item
    )

    $target = Get-ReparsePointTarget -Path $Path
    if (-not [string]::IsNullOrWhiteSpace([string]$target)) {
        return [string]$target
    }

    if ($null -eq $Item) {
        return $null
    }

    $targets = @($Item.Target | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($targets.Count -ne 1) {
        return $null
    }

    $target = [string]$targets[0]
    if (-not [System.IO.Path]::IsPathRooted($target)) {
        $target = Join-Path (Split-Path -Parent $Path) $target
    }

    return ConvertTo-AgentSkillsFullPath -Path $target
}

function Get-EnabledSkillMap {
    param(
        [string]$PackageRoot,
        [System.Collections.IList]$Concerns
    )

    $skills = @{}
    $enabledRoot = Join-Path $PackageRoot 'skills'
    if (-not (Test-Path -LiteralPath $enabledRoot -PathType Container)) {
        return $skills
    }

    foreach ($directory in @(Get-ChildItem -LiteralPath $enabledRoot -Force -Directory)) {
        if (Test-SyncReparsePoint -Item $directory) {
            Add-SyncConcern `
                -Concerns $Concerns `
                -Type 'external-canonical-link' `
                -Agent $null `
                -Skill $directory.Name `
                -Path $directory.FullName `
                -Message 'Enabled canonical skill is a reparse point and was not exposed.'
            continue
        }

        try {
            $metadata = Get-SkillMetadata -SkillPath $directory.FullName
            $normalizedDirectoryName = Normalize-SkillName -Name $directory.Name
            if ($directory.Name -cne $normalizedDirectoryName -or
                $metadata.NormalizedName -cne $normalizedDirectoryName) {
                throw "Canonical directory name and frontmatter name must match normalized identifier '$normalizedDirectoryName'."
            }

            if ($skills.ContainsKey($normalizedDirectoryName)) {
                throw "Duplicate enabled canonical skill identifier '$normalizedDirectoryName'."
            }

            $skills[$normalizedDirectoryName] = $directory.FullName
        }
        catch {
            Add-SyncConcern `
                -Concerns $Concerns `
                -Type 'invalid-enabled-skill' `
                -Agent $null `
                -Skill $directory.Name `
                -Path $directory.FullName `
                -Message $_.Exception.Message
        }
    }

    return $skills
}

function Get-AgentManagedLinkRecords {
    param(
        [object]$Manifest,
        [string]$Agent
    )

    $managedLinks = Get-AgentSkillsObjectProperty -InputObject $Manifest -Name 'managedLinks'
    foreach ($key in @(Get-ContainerPropertyNames -InputObject $managedLinks)) {
        $record = Get-AgentSkillsObjectProperty -InputObject $managedLinks -Name $key
        $recordAgent = [string](Get-AgentSkillsObjectProperty -InputObject $record -Name 'agent')
        if ([string]::Equals($recordAgent, $Agent, [System.StringComparison]::OrdinalIgnoreCase)) {
            $record
        }
    }
}

function Get-ContainerPropertyNames {
    param([AllowNull()][object]$InputObject)

    if ($null -eq $InputObject) {
        return @()
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        return @($InputObject.Keys)
    }

    return @(
        foreach ($property in $InputObject.PSObject.Properties) {
            $property.Name
        }
    )
}

function Prepare-AgentSkillRoot {
    param(
        [string]$Agent,
        [string]$Path,
        [switch]$DryRun,
        [System.Collections.IList]$Actions,
        [System.Collections.IList]$Concerns
    )

    $item = Get-SyncPathItem -Path $Path
    if ($null -ne $item -and (Test-SyncReparsePoint -Item $item)) {
        Add-SyncConcern `
            -Concerns $Concerns `
            -Type 'agent-root-reparse-point' `
            -Agent $Agent `
            -Skill $null `
            -Path $Path `
            -Message 'Agent skill root is a reparse point and was preserved.'
        return $false
    }

    if ($null -eq $item) {
        Add-SyncAction `
            -Actions $Actions `
            -Action $(if ($DryRun) { 'planned-create-agent-root' } else { 'created-agent-root' }) `
            -Agent $Agent `
            -Skill $null `
            -Path $Path `
            -TargetPath $null
    }

    try {
        Ensure-AgentSkillRoot -Path $Path -DryRun:$DryRun | Out-Null
        return $true
    }
    catch {
        Add-SyncConcern `
            -Concerns $Concerns `
            -Type 'agent-root-unavailable' `
            -Agent $Agent `
            -Skill $null `
            -Path $Path `
            -Message $_.Exception.Message
        return $false
    }
}

function Add-JunctionResultAction {
    param(
        [System.Collections.IList]$Actions,
        [object]$Result
    )

    Add-SyncAction `
        -Actions $Actions `
        -Action ([string]$Result.action) `
        -Agent ([string]$Result.agent) `
        -Skill ([string]$Result.skill) `
        -Path ([string]$Result.linkPath) `
        -TargetPath ([string]$Result.targetPath)
}

function Sync-EnabledSkill {
    param(
        [object]$Manifest,
        [string]$PackageRoot,
        [string]$Agent,
        [string]$AgentSkillRoot,
        [string]$SkillName,
        [string]$TargetPath,
        [switch]$DryRun,
        [System.Collections.IList]$Actions,
        [System.Collections.IList]$Concerns,
        [ref]$ManifestChanged
    )

    $linkPath = Join-Path $AgentSkillRoot $SkillName
    $item = Get-SyncPathItem -Path $linkPath
    if ($null -eq $item) {
        try {
            $result = New-PackageSkillJunction `
                -Manifest $Manifest `
                -Agent $Agent `
                -SkillName $SkillName `
                -AgentSkillRoot $AgentSkillRoot `
                -TargetPath $TargetPath `
                -PackageRoot $PackageRoot `
                -DryRun:$DryRun
            Add-JunctionResultAction -Actions $Actions -Result $result
            if (-not $DryRun) {
                $ManifestChanged.Value = $true
            }
        }
        catch {
            Add-SyncConcern `
                -Concerns $Concerns `
                -Type 'junction-create-failed' `
                -Agent $Agent `
                -Skill $SkillName `
                -Path $linkPath `
                -Message $_.Exception.Message
        }

        return
    }

    if (Test-PackageManagedLink `
            -Manifest $Manifest `
            -Agent $Agent `
            -SkillName $SkillName `
            -LinkPath $linkPath `
            -TargetPath $TargetPath `
            -PackageRoot $PackageRoot) {
        return
    }

    $record = Get-AgentSkillsManagedLinkRecord -Manifest $Manifest -Agent $Agent -SkillName $SkillName
    $recordedTarget = [string](Get-AgentSkillsObjectProperty -InputObject $record -Name 'targetPath')
    if ($null -ne $record -and
        -not [string]::IsNullOrWhiteSpace($recordedTarget) -and
        (Test-PackageManagedLink `
                -Manifest $Manifest `
                -Agent $Agent `
                -SkillName $SkillName `
                -LinkPath $linkPath `
                -TargetPath $recordedTarget `
                -PackageRoot $PackageRoot)) {
        try {
            $removeResult = Remove-PackageSkillJunction `
                -Manifest $Manifest `
                -Agent $Agent `
                -SkillName $SkillName `
                -AgentSkillRoot $AgentSkillRoot `
                -TargetPath $recordedTarget `
                -PackageRoot $PackageRoot `
                -DryRun:$DryRun
            Add-JunctionResultAction -Actions $Actions -Result $removeResult

            $createResult = New-PackageSkillJunction `
                -Manifest $Manifest `
                -Agent $Agent `
                -SkillName $SkillName `
                -AgentSkillRoot $AgentSkillRoot `
                -TargetPath $TargetPath `
                -PackageRoot $PackageRoot `
                -DryRun:$DryRun
            Add-JunctionResultAction -Actions $Actions -Result $createResult
            if (-not $DryRun) {
                $ManifestChanged.Value = $true
            }
        }
        catch {
            Add-SyncConcern `
                -Concerns $Concerns `
                -Type 'junction-repair-failed' `
                -Agent $Agent `
                -Skill $SkillName `
                -Path $linkPath `
                -Message $_.Exception.Message
        }

        return
    }

    Add-SyncConcern `
        -Concerns $Concerns `
        -Type 'occupied-unrelated-desired-path' `
        -Agent $Agent `
        -Skill $SkillName `
        -Path $linkPath `
        -Message 'Desired skill path is occupied by an unrelated or unverifiable entry and was preserved.'
}

function Remove-NoLongerEnabledManagedLinks {
    param(
        [object]$Manifest,
        [string]$PackageRoot,
        [hashtable]$EnabledSkills,
        [string]$Agent,
        [string]$AgentSkillRoot,
        [switch]$DryRun,
        [System.Collections.IList]$Actions,
        [System.Collections.IList]$Concerns,
        [ref]$ManifestChanged
    )

    foreach ($record in @(Get-AgentManagedLinkRecords -Manifest $Manifest -Agent $Agent)) {
        $skillName = [string](Get-AgentSkillsObjectProperty -InputObject $record -Name 'skill')
        if ($EnabledSkills.ContainsKey($skillName)) {
            continue
        }

        $recordedTarget = [string](Get-AgentSkillsObjectProperty -InputObject $record -Name 'targetPath')
        $recordedPath = [string](Get-AgentSkillsObjectProperty -InputObject $record -Name 'linkPath')
        try {
            $result = Remove-PackageSkillJunction `
                -Manifest $Manifest `
                -Agent $Agent `
                -SkillName $skillName `
                -AgentSkillRoot $AgentSkillRoot `
                -TargetPath $recordedTarget `
                -PackageRoot $PackageRoot `
                -DryRun:$DryRun
            Add-JunctionResultAction -Actions $Actions -Result $result
            if (-not $DryRun) {
                $ManifestChanged.Value = $true
            }
        }
        catch {
            Add-SyncConcern `
                -Concerns $Concerns `
                -Type 'managed-link-removal-refused' `
                -Agent $Agent `
                -Skill $skillName `
                -Path $recordedPath `
                -Message $_.Exception.Message
        }
    }
}

$actions = New-Object System.Collections.ArrayList
$concerns = New-Object System.Collections.ArrayList
$changedFiles = New-Object System.Collections.ArrayList
$packageRoot = ConvertTo-AgentSkillsFullPath -Path (Join-Path $PSScriptRoot '..')
$status = $(if ($DryRun) { 'dry-run' } else { 'completed' })
$fatalError = $null

try {
    $packageRoot = Get-AgentSkillsPackageRoot
    $manifest = Read-AgentSkillsManifest -PackageRoot $packageRoot
    $agentSkillRoots = Get-AgentSkillRoots -AgentRoots $AgentRoots
    $enabledSkills = Get-EnabledSkillMap -PackageRoot $packageRoot -Concerns $concerns
    $manifestChanged = $false

    foreach ($agent in @('claude', 'codex', 'cursor', 'gemini')) {
        $agentSkillRoot = [string]$agentSkillRoots[$agent]

        $rootReady = Prepare-AgentSkillRoot `
            -Agent $agent `
            -Path $agentSkillRoot `
            -DryRun:$DryRun `
            -Actions $actions `
            -Concerns $concerns
        if (-not $rootReady) {
            continue
        }

        foreach ($skillName in @($enabledSkills.Keys | Sort-Object)) {
            Sync-EnabledSkill `
                -Manifest $manifest `
                -PackageRoot $packageRoot `
                -Agent $agent `
                -AgentSkillRoot $agentSkillRoot `
                -SkillName $skillName `
                -TargetPath ([string]$enabledSkills[$skillName]) `
                -DryRun:$DryRun `
                -Actions $actions `
                -Concerns $concerns `
                -ManifestChanged ([ref]$manifestChanged)
        }

        Remove-NoLongerEnabledManagedLinks `
            -Manifest $manifest `
            -PackageRoot $packageRoot `
            -EnabledSkills $enabledSkills `
            -Agent $agent `
            -AgentSkillRoot $agentSkillRoot `
            -DryRun:$DryRun `
            -Actions $actions `
            -Concerns $concerns `
            -ManifestChanged ([ref]$manifestChanged)
    }

    if ($manifestChanged -and -not $DryRun) {
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
    Add-SyncConcern `
        -Concerns $concerns `
        -Type 'fatal-error' `
        -Agent $null `
        -Skill $null `
        -Path $null `
        -Message $_.Exception.Message
}

$report = [pscustomobject]@{
    schemaVersion = 1
    operation     = 'sync'
    generatedAt   = [DateTime]::UtcNow.ToString('o')
    status        = $status
    dryRun        = [bool]$DryRun
    actions       = @($actions)
    changedFiles  = @($changedFiles)
    concerns      = @($concerns)
    summary       = [pscustomobject]@{
        actionCount  = $actions.Count
        concernCount = $concerns.Count
    }
}

try {
    $reportPath = Write-AgentSkillsReport -ReportType 'sync' -Data $report -PackageRoot $packageRoot
    Write-Output "Sync status: $status; actions: $($actions.Count); concerns: $($concerns.Count)"
    Write-Output "Report: $reportPath"
}
catch {
    Write-Error "Unable to write synchronization report: $($_.Exception.Message)"
    exit 1
}

if ($null -ne $fatalError) {
    exit 1
}
