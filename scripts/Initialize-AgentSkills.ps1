[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'AgentSkills.Common.ps1')

$packageRoot = Get-AgentSkillsPackageRoot
$configRoot = Join-Path $packageRoot 'config'
$templatePath = Join-Path $configRoot 'skills.example.json'
$manifestPath = Join-Path $configRoot 'skills.json'

if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
    throw "Manifest template does not exist: $templatePath"
}

foreach ($directoryName in @('config', 'skills', 'skills-disabled', 'reports', 'backups')) {
    $directoryPath = Join-Path $packageRoot $directoryName
    Assert-PathWithinRoot -Path $directoryPath -Root $packageRoot | Out-Null
    if (-not (Test-Path -LiteralPath $directoryPath -PathType Container)) {
        New-Item -ItemType Directory -Path $directoryPath -Force -ErrorAction Stop | Out-Null
    }
}

if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    Read-AgentSkillsManifest -PackageRoot $packageRoot | Out-Null
    Write-Output "Agent Skills pack is already initialized: $manifestPath"
    return
}

$template = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8 -ErrorAction Stop |
    ConvertFrom-Json -ErrorAction Stop
Assert-AgentSkillsManifestObject -Manifest $template
Write-AgentSkillsManifest -Manifest $template -PackageRoot $packageRoot | Out-Null
Write-Output "Initialized Agent Skills pack: $manifestPath"
