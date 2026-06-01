param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Name,

    [switch]$DryRun,

    [hashtable]$AgentRoots
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'AgentSkills.Common.ps1')

function Set-SkillManifestMode {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest,

        [Parameter(Mandatory = $true)]
        [string]$SkillName,

        [Parameter(Mandatory = $true)]
        [string]$Mode
    )

    $skillsProperty = $Manifest.PSObject.Properties['skills']
    if ($null -eq $skillsProperty) {
        $Manifest | Add-Member -MemberType NoteProperty -Name 'skills' -Value ([pscustomobject]@{})
        $skillsProperty = $Manifest.PSObject.Properties['skills']
    }

    $entryProperty = $skillsProperty.Value.PSObject.Properties[$SkillName]
    if ($null -eq $entryProperty) {
        $entry = [pscustomobject]@{}
        $skillsProperty.Value | Add-Member -MemberType NoteProperty -Name $SkillName -Value $entry
    }
    else {
        $entry = $entryProperty.Value
    }

    $entry | Add-Member -MemberType NoteProperty -Name 'mode' -Value $Mode -Force
    $entry | Add-Member -MemberType NoteProperty -Name 'updatedAt' -Value ([DateTime]::UtcNow.ToString('o')) -Force
}

function Read-SkillManifest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageRoot
    )

    $command = Get-Command -Name 'Read-AgentSkillsManifest' -ErrorAction Stop
    if ($command.Parameters.ContainsKey('PackageRoot')) {
        return & $command -PackageRoot $PackageRoot
    }

    return & $command
}

function Write-SkillManifest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageRoot,

        [Parameter(Mandatory = $true)]
        [object]$Manifest
    )

    $command = Get-Command -Name 'Write-AgentSkillsManifest' -ErrorAction Stop
    $arguments = @{}
    if ($command.Parameters.ContainsKey('PackageRoot')) {
        $arguments['PackageRoot'] = $PackageRoot
    }

    if ($command.Parameters.ContainsKey('Manifest')) {
        $arguments['Manifest'] = $Manifest
        & $command @arguments
        return
    }

    & $command $Manifest @arguments
}

$skillName = Normalize-SkillName -Name $Name
if ([string]::IsNullOrWhiteSpace($skillName) -or $Name -cne $skillName) {
    throw "Skill name '$Name' is not normalized. Use '$skillName'."
}

$packageRoot = [System.IO.Path]::GetFullPath((Get-AgentSkillsPackageRoot))
$enabledRoot = [System.IO.Path]::GetFullPath((Join-Path $packageRoot 'skills'))
$disabledRoot = [System.IO.Path]::GetFullPath((Join-Path $packageRoot 'skills-disabled'))
$sourcePath = [System.IO.Path]::GetFullPath((Join-Path $enabledRoot $skillName))
$destinationPath = [System.IO.Path]::GetFullPath((Join-Path $disabledRoot $skillName))

Assert-PathWithinRoot -Path $sourcePath -Root $enabledRoot
Assert-PathWithinRoot -Path $destinationPath -Root $disabledRoot

$sourceExists = Test-Path -LiteralPath $sourcePath
$destinationExists = Test-Path -LiteralPath $destinationPath

if ($sourceExists -and $destinationExists) {
    throw "Skill '$skillName' appears in both canonical roots."
}

if (-not $sourceExists -and -not $destinationExists) {
    throw "Skill '$skillName' does not exist in either canonical root."
}

if ($sourceExists -and -not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
    throw "Canonical skill source is not a directory: $sourcePath"
}

if ($destinationExists -and -not (Test-Path -LiteralPath $destinationPath -PathType Container)) {
    throw "Canonical skill destination is not a directory: $destinationPath"
}

$syncScript = Join-Path $PSScriptRoot 'Sync-AgentSkills.ps1'
$syncParameters = @{}
if ($PSBoundParameters.ContainsKey('AgentRoots')) {
    $syncParameters['AgentRoots'] = $AgentRoots
}

if ($DryRun) {
    Write-Output "DRY-RUN: would disable skill '$skillName'."
    $syncParameters['DryRun'] = $true
    & $syncScript @syncParameters
    return
}

$manifest = Read-SkillManifest -PackageRoot $packageRoot
Set-SkillManifestMode -Manifest $manifest -SkillName $skillName -Mode 'manual'

if ($sourceExists) {
    if (-not (Test-Path -LiteralPath $disabledRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $disabledRoot -Force | Out-Null
    }

    Move-Item -LiteralPath $sourcePath -Destination $destinationPath
}

Write-SkillManifest -PackageRoot $packageRoot -Manifest $manifest
Write-Output "Disabled skill '$skillName'."
& $syncScript @syncParameters
