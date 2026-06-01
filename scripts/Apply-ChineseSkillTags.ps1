[CmdletBinding()]
param(
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'AgentSkills.Common.ps1')

function Get-CanonicalSkillDirectories {
    param([string]$PackageRoot)

    foreach ($mode in @('auto', 'manual')) {
        $rootName = if ($mode -eq 'auto') { 'skills' } else { 'skills-disabled' }
        $root = Join-Path $PackageRoot $rootName
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory -Force |
                Where-Object { $_.Name -notlike '.import-*' } |
                Sort-Object Name)) {
            [pscustomobject]@{
                name = $directory.Name
                mode = $mode
                path = $directory.FullName
            }
        }
    }
}

function Get-ObjectPropertyNames {
    param([object]$InputObject)

    return @($InputObject.PSObject.Properties | ForEach-Object { $_.Name })
}

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Set-SkillDescriptionTags {
    param(
        [string]$SkillPath,
        [string[]]$Tags,
        [string]$Marker,
        [switch]$DryRun
    )

    $metadata = Get-SkillMetadata -SkillPath $SkillPath
    $metadataPath = $metadata.MetadataPath
    $content = [System.IO.File]::ReadAllText($metadataPath)
    $newline = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $hasTrailingNewline = $content.EndsWith("`n")
    $lines = @($content -split '\r?\n')
    if ($hasTrailingNewline -and $lines.Count -gt 0 -and $lines[-1] -eq '') {
        $lines = @($lines[0..($lines.Count - 2)])
    }

    if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') {
        throw "Skill metadata must begin with YAML frontmatter: $metadataPath"
    }

    $closingIndex = -1
    for ($lineIndex = 1; $lineIndex -lt $lines.Count; $lineIndex++) {
        if ($lines[$lineIndex].Trim() -eq '---') {
            $closingIndex = $lineIndex
            break
        }
    }

    if ($closingIndex -lt 0) {
        throw "Skill metadata frontmatter is not closed: $metadataPath"
    }

    $descriptionIndex = -1
    for ($lineIndex = 1; $lineIndex -lt $closingIndex; $lineIndex++) {
        if ($lines[$lineIndex] -match '^description\s*:') {
            $descriptionIndex = $lineIndex
            break
        }
    }

    if ($descriptionIndex -lt 0) {
        throw "Skill metadata requires a description: $metadataPath"
    }

    $descriptionEndIndex = $descriptionIndex
    $rawValue = ($lines[$descriptionIndex] -replace '^description\s*:\s*', '').Trim()
    if ($rawValue -match '^[>|][+-]?$' -or [string]::IsNullOrWhiteSpace($rawValue)) {
        for ($lineIndex = $descriptionIndex + 1; $lineIndex -lt $closingIndex; $lineIndex++) {
            $line = $lines[$lineIndex]
            if ($line.Length -gt 0 -and -not [char]::IsWhiteSpace($line[0])) {
                break
            }

            $descriptionEndIndex = $lineIndex
        }
    }

    $escapedMarker = [regex]::Escape($Marker)
    $baseDescription = ([regex]::Replace(
            [string]$metadata.Description,
            "\s*$escapedMarker.*$",
            ''
        )).Trim()
    $taggedDescription = '{0} {1}{2}.' -f $baseDescription, $Marker, ($Tags -join ', ')

    $updatedLines = New-Object 'System.Collections.Generic.List[string]'
    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
        if ($lineIndex -eq $descriptionIndex) {
            $updatedLines.Add('description: >-')
            $updatedLines.Add('  ' + $taggedDescription)
            $lineIndex = $descriptionEndIndex
            continue
        }

        $updatedLines.Add($lines[$lineIndex])
    }

    if (-not $DryRun) {
        $updatedContent = $updatedLines -join $newline
        if ($hasTrailingNewline) {
            $updatedContent += $newline
        }

        Write-Utf8NoBom -Path $metadataPath -Content $updatedContent
    }

    return $taggedDescription
}

function Write-TagReports {
    param(
        [string]$PackageRoot,
        [System.Collections.IList]$Rows,
        [switch]$DryRun
    )

    if ($DryRun) {
        return
    }

    $reportRoot = Join-Path $PackageRoot 'reports'
    if (-not (Test-Path -LiteralPath $reportRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null
    }

    $markdownPath = Join-Path $reportRoot 'skill-tags.zh-CN.md'
    $csvPath = Join-Path $reportRoot 'skill-tags.zh-CN.csv'
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine('# Chinese Skill Tag Index')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine(('Generated: {0}' -f [DateTime]::UtcNow.ToString('o')))
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('| Skill | Mode | Chinese tags |')
    [void]$builder.AppendLine('| --- | --- | --- |')
    foreach ($row in $Rows) {
        [void]$builder.AppendLine(('| `{0}` | `{1}` | {2} |' -f $row.skill, $row.mode, ($row.tagsZh -join ', ')))
    }

    Write-Utf8NoBom -Path $markdownPath -Content $builder.ToString()
    $csv = ($Rows |
            Select-Object skill, mode, @{ Name = 'tagsZh'; Expression = { $_.tagsZh -join ',' } }, skillPath |
            ConvertTo-Csv -NoTypeInformation) -join [Environment]::NewLine
    Write-Utf8NoBom -Path $csvPath -Content ($csv + [Environment]::NewLine)
}

$packageRoot = Get-AgentSkillsPackageRoot
$configPath = Join-Path $packageRoot 'config\skill-tags.zh-CN.json'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Chinese tag configuration does not exist: $configPath"
}

$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$marker = [string]$config.descriptionMarker
if ([string]::IsNullOrWhiteSpace($marker)) {
    throw "Chinese tag configuration requires descriptionMarker."
}

$tagSkills = Get-ObjectPropertyNames -InputObject $config.skills
$canonicalSkills = @(Get-CanonicalSkillDirectories -PackageRoot $packageRoot)
$canonicalNames = @($canonicalSkills | ForEach-Object { $_.name })
$missing = @($canonicalNames | Where-Object { $_ -notin $tagSkills })
$unknown = @($tagSkills | Where-Object { $_ -notin $canonicalNames })
if ($missing.Count -gt 0 -or $unknown.Count -gt 0) {
    throw "Chinese tag coverage mismatch. Missing: $($missing -join ', '). Unknown: $($unknown -join ', ')."
}

$manifest = Read-AgentSkillsManifest -PackageRoot $packageRoot
$updatedAt = [DateTime]::UtcNow.ToString('o')
$rows = New-Object System.Collections.Generic.List[object]
foreach ($skill in @($canonicalSkills | Sort-Object name)) {
    $tags = @($config.skills.PSObject.Properties[$skill.name].Value)
    if ($tags.Count -lt 3) {
        throw "Skill '$($skill.name)' must define at least three Chinese tags."
    }

    $duplicates = @($tags | Group-Object | Where-Object { $_.Count -gt 1 })
    if ($duplicates.Count -gt 0) {
        throw "Skill '$($skill.name)' contains duplicate Chinese tags: $($duplicates.Name -join ', ')."
    }

    foreach ($tag in $tags) {
        if ([string]::IsNullOrWhiteSpace([string]$tag)) {
            throw "Skill '$($skill.name)' contains an empty Chinese tag."
        }
    }

    $description = Set-SkillDescriptionTags `
        -SkillPath $skill.path `
        -Tags $tags `
        -Marker $marker `
        -DryRun:$DryRun

    $entry = $manifest.skills.PSObject.Properties[$skill.name].Value
    $entry | Add-Member -MemberType NoteProperty -Name 'tagsZh' -Value @($tags) -Force
    $entry | Add-Member -MemberType NoteProperty -Name 'tagsLanguage' -Value 'zh-CN' -Force
    $entry | Add-Member -MemberType NoteProperty -Name 'tagsUpdatedAt' -Value $updatedAt -Force
    $entry | Add-Member -MemberType NoteProperty -Name 'keywordRouting' -Value 'description+manifest-tags' -Force

    $rows.Add([pscustomobject]@{
            skill       = $skill.name
            mode        = $skill.mode
            tagsZh      = @($tags)
            description = $description
            skillPath   = $skill.path
        })
}

if (-not $DryRun) {
    Write-AgentSkillsManifest -Manifest $manifest -PackageRoot $packageRoot | Out-Null
}

Write-TagReports -PackageRoot $packageRoot -Rows $rows -DryRun:$DryRun
Write-Output ('Chinese tags {0}: {1} skill(s), {2} tag assignment(s).' -f
    $(if ($DryRun) { 'validated' } else { 'applied' }),
    $rows.Count,
    @($rows | ForEach-Object { $_.tagsZh } | ForEach-Object { $_ }).Count)
