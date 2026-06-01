[CmdletBinding()]
param(
    [switch]$DryRun,
    [string[]]$SourceRoots,
    [switch]$SyncAfterImport
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'AgentSkills.Common.ps1')

function Get-ImportFullPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$BasePath
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded -eq '~') {
        $expanded = $HOME
    }
    elseif ($expanded.StartsWith('~\') -or $expanded.StartsWith('~/')) {
        $expanded = Join-Path -Path $HOME -ChildPath $expanded.Substring(2)
    }

    if (-not [System.IO.Path]::IsPathRooted($expanded)) {
        if ([string]::IsNullOrWhiteSpace($BasePath)) {
            $BasePath = (Get-Location).Path
        }

        $expanded = Join-Path -Path $BasePath -ChildPath $expanded
    }

    return [System.IO.Path]::GetFullPath($expanded).TrimEnd('\', '/')
}

function Test-ImportPathWithinRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $fullPath = (Get-ImportFullPath -Path $Path).TrimEnd('\', '/')
    $fullRoot = (Get-ImportFullPath -Path $Root).TrimEnd('\', '/')

    return $fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($fullRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-ImportPathWithinRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    if (-not (Test-ImportPathWithinRoot -Path $Path -Root $Root)) {
        throw "Unsafe path '$Path': expected a location within '$Root'."
    }

    if (Get-Command -Name 'Assert-PathWithinRoot' -ErrorAction SilentlyContinue) {
        Assert-PathWithinRoot -Path $Path -Root $Root
    }
}

function Invoke-CommonPathCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $command = Get-Command -Name $CommandName -ErrorAction Stop
    if ($command.Parameters.ContainsKey('Path')) {
        return & $command -Path $Path
    }
    elseif ($command.Parameters.ContainsKey('SkillPath')) {
        return & $command -SkillPath $Path
    }
    elseif ($command.Parameters.ContainsKey('SkillDirectory')) {
        return & $command -SkillDirectory $Path
    }
    elseif ($command.Parameters.ContainsKey('Directory')) {
        return & $command -Directory $Path
    }

    return & $command $Path
}

function Get-ImportSkillMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return Invoke-CommonPathCommand -CommandName 'Get-SkillMetadata' -Path $Path
}

function Get-ImportDirectoryFingerprint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return [string](Invoke-CommonPathCommand -CommandName 'Get-DirectoryFingerprint' -Path $Path)
}

function Get-NormalizedSkillName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $command = Get-Command -Name 'Normalize-SkillName' -ErrorAction Stop
    if ($command.Parameters.ContainsKey('Name')) {
        return [string](& $command -Name $Name)
    }
    elseif ($command.Parameters.ContainsKey('SkillName')) {
        return [string](& $command -SkillName $Name)
    }

    return [string](& $command $Name)
}

function Get-ImportObjectProperty {
    param(
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }

        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function Set-ImportObjectProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [object]$Value
    )

    if ($Object -is [System.Collections.IDictionary]) {
        $Object[$Name] = $Value
        return
    }

    $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
}

function Read-ImportManifest {
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

function Write-ImportManifest {
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

function Write-ImportReport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageRoot,

        [Parameter(Mandatory = $true)]
        [object]$Report
    )

    $command = Get-Command -Name 'Write-AgentSkillsReport' -ErrorAction Stop
    $arguments = @{}

    if ($command.Parameters.ContainsKey('PackageRoot')) {
        $arguments['PackageRoot'] = $PackageRoot
    }

    if ($command.Parameters.ContainsKey('Type')) {
        $arguments['Type'] = 'import'
    }
    elseif ($command.Parameters.ContainsKey('ReportType')) {
        $arguments['ReportType'] = 'import'
    }
    elseif ($command.Parameters.ContainsKey('Kind')) {
        $arguments['Kind'] = 'import'
    }
    elseif ($command.Parameters.ContainsKey('Prefix')) {
        $arguments['Prefix'] = 'import'
    }

    if ($command.Parameters.ContainsKey('Report')) {
        $arguments['Report'] = $Report
        return & $command @arguments
    }
    elseif ($command.Parameters.ContainsKey('Data')) {
        $arguments['Data'] = $Report
        return & $command @arguments
    }

    return & $command $Report @arguments
}

function Get-ImportReparsePointTarget {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        $target = Invoke-CommonPathCommand -CommandName 'Get-ReparsePointTarget' -Path $Path
        if ($target -is [System.Array]) {
            return [string]$target[0]
        }

        return [string]$target
    }
    catch {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSObject.Properties['Target']) {
            if ($item.Target -is [System.Array]) {
                return [string]$item.Target[0]
            }

            return [string]$item.Target
        }

        throw
    }
}

function Resolve-ImportReparsePointTarget {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$Target
    )

    if ([string]::IsNullOrWhiteSpace($Target)) {
        return $null
    }

    $normalizedTarget = $Target
    if ($normalizedTarget.StartsWith('\??\')) {
        $normalizedTarget = $normalizedTarget.Substring(4)
    }

    if (-not [System.IO.Path]::IsPathRooted($normalizedTarget)) {
        $normalizedTarget = Join-Path -Path (Split-Path -Parent $Path) -ChildPath $normalizedTarget
    }

    return Get-ImportFullPath -Path $normalizedTarget
}

function Test-ImportReparsePointBroken {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileSystemInfo]$Item
    )

    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
        return $false
    }

    try {
        $target = Get-ImportReparsePointTarget -Path $Item.FullName
        $resolvedTarget = Resolve-ImportReparsePointTarget -Path $Item.FullName -Target $target
        return [string]::IsNullOrWhiteSpace($resolvedTarget) -or -not (Test-Path -LiteralPath $resolvedTarget)
    }
    catch {
        return $true
    }
}

function Copy-ImportDirectoryDereferenced {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [Parameter(Mandatory = $true)]
        [hashtable]$Visited
    )

    $sourceItem = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
    $effectiveSource = $sourceItem.FullName
    if (($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        $target = Get-ImportReparsePointTarget -Path $sourceItem.FullName
        $effectiveSource = Resolve-ImportReparsePointTarget -Path $sourceItem.FullName -Target $target
        if ([string]::IsNullOrWhiteSpace($effectiveSource) -or -not (Test-Path -LiteralPath $effectiveSource -PathType Container)) {
            throw "Cannot dereference broken directory link '$Source'."
        }
    }

    $resolvedSource = (Resolve-Path -LiteralPath $effectiveSource -ErrorAction Stop).Path
    $visitKey = (Get-ImportFullPath -Path $resolvedSource).ToLowerInvariant()
    if ($Visited.ContainsKey($visitKey)) {
        throw "Cannot copy '$Source': directory Junction cycle detected."
    }

    $Visited[$visitKey] = $true
    try {
        if (-not (Test-Path -LiteralPath $Destination)) {
            New-Item -ItemType Directory -Path $Destination | Out-Null
        }

        foreach ($child in @(Get-ChildItem -LiteralPath $resolvedSource -Force -ErrorAction Stop)) {
            $destinationChild = Join-Path -Path $Destination -ChildPath $child.Name
            if ($child.PSIsContainer) {
                Copy-ImportDirectoryDereferenced -Source $child.FullName -Destination $destinationChild -Visited $Visited
            }
            else {
                Copy-Item -LiteralPath $child.FullName -Destination $destinationChild -Force
            }
        }
    }
    finally {
        $Visited.Remove($visitKey)
    }
}

function Copy-ImportSkillDereferenced {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [Parameter(Mandatory = $true)]
        [string]$CanonicalRoot
    )

    Assert-ImportPathWithinRoot -Path $Destination -Root $CanonicalRoot
    if (Test-Path -LiteralPath $Destination) {
        throw "Refusing to overwrite existing canonical skill '$Destination'."
    }

    if (-not (Test-Path -LiteralPath $CanonicalRoot)) {
        New-Item -ItemType Directory -Path $CanonicalRoot | Out-Null
    }

    $stagingPath = Join-Path -Path $CanonicalRoot -ChildPath ('.import-' + [System.Guid]::NewGuid().ToString('N'))
    Assert-ImportPathWithinRoot -Path $stagingPath -Root $CanonicalRoot
    try {
        Copy-ImportDirectoryDereferenced -Source $Source -Destination $stagingPath -Visited @{}
        if (Test-Path -LiteralPath $Destination) {
            throw "Refusing to overwrite canonical skill '$Destination' because it appeared during import."
        }

        Move-Item -LiteralPath $stagingPath -Destination $Destination
    }
    finally {
        if (Test-Path -LiteralPath $stagingPath) {
            Assert-ImportPathWithinRoot -Path $stagingPath -Root $CanonicalRoot
            Remove-Item -LiteralPath $stagingPath -Recurse -Force
        }
    }
}

function Add-ImportListItem {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.ArrayList]$List,

        [Parameter(Mandatory = $true)]
        [object]$Item
    )

    [void]$List.Add($Item)
}

function Set-ManifestSkillEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [object]$Value
    )

    $skills = Get-ImportObjectProperty -Object $Manifest -Name 'skills'
    if ($null -eq $skills) {
        $skills = [ordered]@{}
        Set-ImportObjectProperty -Object $Manifest -Name 'skills' -Value $skills
    }

    Set-ImportObjectProperty -Object $skills -Name $Name -Value $Value
}

function Get-ExistingManifestSkillEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $skills = Get-ImportObjectProperty -Object $Manifest -Name 'skills'
    return Get-ImportObjectProperty -Object $skills -Name $Name
}

function Get-SourceRootKind {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$LegacyActiveRoot,

        [Parameter(Mandatory = $true)]
        [string]$LegacyDisabledRoot
    )

    if ($Root.Equals($LegacyActiveRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return 'legacy-active'
    }

    if ($Root.Equals($LegacyDisabledRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return 'legacy-disabled'
    }

    return 'agent'
}

function Get-ImportMode {
    param(
        [object[]]$Sources,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.ArrayList]$Conflicts,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [hashtable]$LegacyActiveNames,

        [Parameter(Mandatory = $true)]
        [hashtable]$LegacyDisabledNames
    )

    $hasLegacyActive = $LegacyActiveNames.ContainsKey($Name)
    $hasLegacyDisabled = $LegacyDisabledNames.ContainsKey($Name)

    if ($hasLegacyActive -and $hasLegacyDisabled) {
        Add-ImportListItem -List $Conflicts -Item ([ordered]@{
            type = 'legacy-classification'
            skill = $Name
            message = 'Skill exists in both legacy active and legacy disabled roots; importing as disabled.'
        })

        return 'manual'
    }

    if ($hasLegacyActive) {
        return 'auto'
    }

    return 'manual'
}

function Get-LegacySkillNameSet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $names = @{}
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return $names
    }

    foreach ($directory in @(Get-ChildItem -LiteralPath $Root -Force -Directory -ErrorAction SilentlyContinue)) {
        $normalizedName = Get-NormalizedSkillName -Name $directory.Name
        if (-not [string]::IsNullOrWhiteSpace($normalizedName)) {
            $names[$normalizedName] = $true
        }
    }

    return $names
}

$packageRoot = Get-ImportFullPath -Path ([string](Get-AgentSkillsPackageRoot))
$canonicalActiveRoot = Join-Path -Path $packageRoot -ChildPath 'skills'
$canonicalDisabledRoot = Join-Path -Path $packageRoot -ChildPath 'skills-disabled'
$legacyActiveRoot = Get-ImportFullPath -Path (Join-Path -Path $packageRoot -ChildPath 'claude-skills')
$legacyDisabledRoot = Get-ImportFullPath -Path (Join-Path -Path $packageRoot -ChildPath 'claude-skills-disabled')
$legacyActiveNames = Get-LegacySkillNameSet -Root $legacyActiveRoot
$legacyDisabledNames = Get-LegacySkillNameSet -Root $legacyDisabledRoot
$manifest = Read-ImportManifest -PackageRoot $packageRoot
$startedAt = [DateTime]::UtcNow.ToString('o')
$importedAt = $startedAt

if ($null -eq $SourceRoots -or $SourceRoots.Count -eq 0) {
    $SourceRoots = @(
        (Join-Path -Path $HOME -ChildPath '.agents\skills'),
        (Join-Path -Path $HOME -ChildPath '.claude\skills'),
        (Join-Path -Path $HOME -ChildPath '.cursor\skills'),
        (Join-Path -Path $HOME -ChildPath '.gemini\skills'),
        $legacyActiveRoot,
        $legacyDisabledRoot
    )
}

$normalizedSourceRoots = New-Object System.Collections.ArrayList
$seenSourceRoots = @{}
foreach ($sourceRoot in $SourceRoots) {
    if ([string]::IsNullOrWhiteSpace($sourceRoot)) {
        continue
    }

    $normalizedRoot = Get-ImportFullPath -Path $sourceRoot -BasePath $packageRoot
    $sourceRootKey = $normalizedRoot.ToLowerInvariant()
    if (-not $seenSourceRoots.ContainsKey($sourceRootKey)) {
        $seenSourceRoots[$sourceRootKey] = $true
        Add-ImportListItem -List $normalizedSourceRoots -Item $normalizedRoot
    }
}

$actions = New-Object System.Collections.ArrayList
$placeholders = New-Object System.Collections.ArrayList
$brokenJunctions = New-Object System.Collections.ArrayList
$invalidSkills = New-Object System.Collections.ArrayList
$duplicates = New-Object System.Collections.ArrayList
$conflicts = New-Object System.Collections.ArrayList
$missingSourceRoots = New-Object System.Collections.ArrayList
$sourcesBySkill = @{}

for ($sourceIndex = 0; $sourceIndex -lt $normalizedSourceRoots.Count; $sourceIndex++) {
    $sourceRoot = [string]$normalizedSourceRoots[$sourceIndex]
    $sourceRootKind = Get-SourceRootKind -Root $sourceRoot -LegacyActiveRoot $legacyActiveRoot -LegacyDisabledRoot $legacyDisabledRoot

    try {
        $sourceRootItem = Get-Item -LiteralPath $sourceRoot -Force -ErrorAction Stop
        if (($sourceRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -and
            (Test-ImportReparsePointBroken -Item $sourceRootItem)) {
            Add-ImportListItem -List $brokenJunctions -Item ([ordered]@{
                type = 'source-root'
                path = $sourceRoot
                target = Get-ImportReparsePointTarget -Path $sourceRoot
            })
            continue
        }
    }
    catch {
    }

    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
        try {
            $missingRootItem = Get-Item -LiteralPath $sourceRoot -Force -ErrorAction Stop
            if (($missingRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Add-ImportListItem -List $brokenJunctions -Item ([ordered]@{
                    type = 'source-root'
                    path = $sourceRoot
                    target = Get-ImportReparsePointTarget -Path $sourceRoot
                })
                continue
            }
        }
        catch {
        }

        Add-ImportListItem -List $missingSourceRoots -Item $sourceRoot
        continue
    }

    try {
        $sourceChildren = @(Get-ChildItem -LiteralPath $sourceRoot -Force -ErrorAction Stop)
    }
    catch {
        Add-ImportListItem -List $brokenJunctions -Item ([ordered]@{
            type = 'source-root-unreadable'
            path = $sourceRoot
            target = $(try { Get-ImportReparsePointTarget -Path $sourceRoot } catch { $null })
            reason = $_.Exception.Message
        })
        continue
    }

    foreach ($child in $sourceChildren) {
        if (Test-ImportReparsePointBroken -Item $child) {
            $target = $null
            try {
                $target = Get-ImportReparsePointTarget -Path $child.FullName
            }
            catch {
            }

            Add-ImportListItem -List $brokenJunctions -Item ([ordered]@{
                type = 'skill'
                path = $child.FullName
                target = $target
            })
            continue
        }

        if (-not $child.PSIsContainer) {
            continue
        }

        $skillDocument = Join-Path -Path $child.FullName -ChildPath 'SKILL.md'
        if (-not (Test-Path -LiteralPath $skillDocument -PathType Leaf)) {
            $hasChildren = @(Get-ChildItem -LiteralPath $child.FullName -Force -ErrorAction SilentlyContinue).Count -gt 0
            Add-ImportListItem -List $placeholders -Item ([ordered]@{
                path = $child.FullName
                empty = -not $hasChildren
                reason = 'missing SKILL.md'
            })
            continue
        }

        try {
            $metadata = Get-ImportSkillMetadata -Path $child.FullName
            $metadataName = [string](Get-ImportObjectProperty -Object $metadata -Name 'name')
            if ([string]::IsNullOrWhiteSpace($metadataName)) {
                $metadataName = [string](Get-ImportObjectProperty -Object $metadata -Name 'Name')
            }

            $normalizedMetadataName = Get-NormalizedSkillName -Name $metadataName
            $normalizedDirectoryName = Get-NormalizedSkillName -Name $child.Name
            if ([string]::IsNullOrWhiteSpace($normalizedMetadataName) -or $normalizedDirectoryName -ne $normalizedMetadataName) {
                throw "Directory name '$($child.Name)' does not match frontmatter name '$metadataName' after normalization."
            }

            $fingerprint = Get-ImportDirectoryFingerprint -Path $child.FullName
            $source = [pscustomobject][ordered]@{
                name = $normalizedMetadataName
                sourcePath = $child.FullName
                sourceRoot = $sourceRoot
                sourceKind = $sourceRootKind
                sourceIndex = $sourceIndex
                fingerprint = $fingerprint
            }

            if (-not $sourcesBySkill.ContainsKey($normalizedMetadataName)) {
                $sourcesBySkill[$normalizedMetadataName] = New-Object System.Collections.ArrayList
            }

            Add-ImportListItem -List $sourcesBySkill[$normalizedMetadataName] -Item $source
        }
        catch {
            Add-ImportListItem -List $invalidSkills -Item ([ordered]@{
                path = $child.FullName
                reason = $_.Exception.Message
            })
        }
    }
}

foreach ($skillName in @($sourcesBySkill.Keys | Sort-Object)) {
    $sources = @($sourcesBySkill[$skillName] | Sort-Object sourceIndex, sourcePath)
    $activeCanonicalPath = Join-Path -Path $canonicalActiveRoot -ChildPath $skillName
    $disabledCanonicalPath = Join-Path -Path $canonicalDisabledRoot -ChildPath $skillName
    $hasActiveCanonical = Test-Path -LiteralPath $activeCanonicalPath -PathType Container
    $hasDisabledCanonical = Test-Path -LiteralPath $disabledCanonicalPath -PathType Container

    if ($hasActiveCanonical -and $hasDisabledCanonical) {
        Add-ImportListItem -List $conflicts -Item ([ordered]@{
            type = 'canonical-classification'
            skill = $skillName
            paths = @($activeCanonicalPath, $disabledCanonicalPath)
            message = 'Skill exists in both canonical roots; no canonical copy was changed.'
        })
        Add-ImportListItem -List $actions -Item ([ordered]@{
            action = 'skip'
            skill = $skillName
            reason = 'ambiguous canonical classification'
        })
        continue
    }

    $selectedSource = $sources[0]
    $canonicalPath = $null
    $mode = $null
    $selectedFingerprint = $null
    $newImport = $false

    if ($hasActiveCanonical -or $hasDisabledCanonical) {
        if ($hasActiveCanonical) {
            $canonicalPath = $activeCanonicalPath
            $mode = 'auto'
        }
        else {
            $canonicalPath = $disabledCanonicalPath
            $mode = 'manual'
        }

        try {
            $selectedFingerprint = Get-ImportDirectoryFingerprint -Path $canonicalPath
        }
        catch {
            Add-ImportListItem -List $conflicts -Item ([ordered]@{
                type = 'canonical-invalid'
                skill = $skillName
                path = $canonicalPath
                message = $_.Exception.Message
            })
            Add-ImportListItem -List $actions -Item ([ordered]@{
                action = 'skip'
                skill = $skillName
                reason = 'canonical fingerprint failed'
            })
            continue
        }

        Add-ImportListItem -List $actions -Item ([ordered]@{
            action = 'preserve'
            skill = $skillName
            destination = $canonicalPath
            mode = $mode
        })
    }
    else {
        $mode = Get-ImportMode `
            -Sources $sources `
            -Conflicts $conflicts `
            -Name $skillName `
            -LegacyActiveNames $legacyActiveNames `
            -LegacyDisabledNames $legacyDisabledNames
        if ($mode -eq 'auto') {
            $canonicalPath = $activeCanonicalPath
        }
        else {
            $canonicalPath = $disabledCanonicalPath
        }

        $selectedFingerprint = $selectedSource.fingerprint
        $newImport = $true
        if (-not $DryRun) {
            Copy-ImportSkillDereferenced -Source $selectedSource.sourcePath -Destination $canonicalPath -CanonicalRoot (Split-Path -Parent $canonicalPath)
        }

        Add-ImportListItem -List $actions -Item ([ordered]@{
            action = $(if ($DryRun) { 'plan-import' } else { 'import' })
            skill = $skillName
            source = $selectedSource.sourcePath
            destination = $canonicalPath
            mode = $mode
        })
    }

    $aliasPaths = New-Object System.Collections.ArrayList
    $skillConflicts = New-Object System.Collections.ArrayList
    foreach ($source in $sources) {
        if ($newImport -and $source.sourcePath.Equals($selectedSource.sourcePath, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        if ($source.fingerprint -eq $selectedFingerprint) {
            Add-ImportListItem -List $aliasPaths -Item $source.sourcePath
            Add-ImportListItem -List $duplicates -Item ([ordered]@{
                skill = $skillName
                selected = $(if ($newImport) { $selectedSource.sourcePath } else { $canonicalPath })
                alias = $source.sourcePath
                fingerprint = $selectedFingerprint
            })
        }
        else {
            $conflict = [ordered]@{
                type = 'content'
                skill = $skillName
                selected = $(if ($newImport) { $selectedSource.sourcePath } else { $canonicalPath })
                selectedFingerprint = $selectedFingerprint
                conflicting = $source.sourcePath
                conflictingFingerprint = $source.fingerprint
                message = 'Different content detected; selected canonical copy was left unchanged.'
            }
            Add-ImportListItem -List $skillConflicts -Item $conflict
            Add-ImportListItem -List $conflicts -Item $conflict
        }
    }

    if (-not $DryRun) {
        $existingManifestEntry = Get-ExistingManifestSkillEntry -Manifest $manifest -Name $skillName
        $manifestImportedAt = Get-ImportObjectProperty -Object $existingManifestEntry -Name 'importedAt'
        if ($newImport -or [string]::IsNullOrWhiteSpace([string]$manifestImportedAt)) {
            $manifestImportedAt = $importedAt
        }

        $manifestSource = Get-ImportObjectProperty -Object $existingManifestEntry -Name 'source'
        if ($newImport -or [string]::IsNullOrWhiteSpace([string]$manifestSource)) {
            $manifestSource = $selectedSource.sourcePath
        }

        $manifestEntry = [pscustomobject][ordered]@{
            mode = $mode
            source = $manifestSource
            importedAt = $manifestImportedAt
            aliases = @($aliasPaths)
            conflicts = @($skillConflicts)
        }
        Set-ManifestSkillEntry -Manifest $manifest -Name $skillName -Value $manifestEntry
    }
}

if (-not $DryRun) {
    Write-ImportManifest -PackageRoot $packageRoot -Manifest $manifest
}

$report = [pscustomobject][ordered]@{
    operation = 'import'
    dryRun = [bool]$DryRun
    startedAt = $startedAt
    completedAt = [DateTime]::UtcNow.ToString('o')
    packageRoot = $packageRoot
    sourceRoots = @($normalizedSourceRoots)
    missingSourceRoots = @($missingSourceRoots)
    actions = @($actions)
    placeholders = @($placeholders)
    brokenJunctions = @($brokenJunctions)
    invalidSkills = @($invalidSkills)
    duplicates = @($duplicates)
    conflicts = @($conflicts)
    summary = [pscustomobject][ordered]@{
        actions = $actions.Count
        placeholders = $placeholders.Count
        brokenJunctions = $brokenJunctions.Count
        invalidSkills = $invalidSkills.Count
        duplicates = $duplicates.Count
        conflicts = $conflicts.Count
    }
}

$reportPath = Write-ImportReport -PackageRoot $packageRoot -Report $report
Write-Output $reportPath

if ($SyncAfterImport) {
    $syncScript = Join-Path -Path $PSScriptRoot -ChildPath 'Sync-AgentSkills.ps1'
    if (-not (Test-Path -LiteralPath $syncScript -PathType Leaf)) {
        throw "Cannot synchronize after import because '$syncScript' does not exist."
    }

    if ($DryRun) {
        & $syncScript -DryRun
    }
    else {
        & $syncScript
    }
}
