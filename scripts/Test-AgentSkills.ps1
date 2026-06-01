[CmdletBinding()]
param(
    [hashtable]$AgentRoots,
    [switch]$SkipGeneratedViews
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$commonModule = Join-Path $PSScriptRoot 'AgentSkills.Common.ps1'
if (-not (Test-Path -LiteralPath $commonModule -PathType Leaf)) {
    throw "Shared module not found: $commonModule"
}
. $commonModule

$script:ValidationErrors = New-Object System.Collections.Generic.List[object]
$script:ValidationWarnings = New-Object System.Collections.Generic.List[object]
$script:ValidatedCanonicalSkills = New-Object System.Collections.Generic.List[object]

function Add-ValidationIssue {
    param(
        [ValidateSet('error', 'warning')]
        [string]$Severity,
        [string]$Code,
        [string]$Message,
        [string]$Path
    )

    $issue = [pscustomobject]@{
        severity = $Severity
        code = $Code
        message = $Message
        path = $Path
    }
    if ($Severity -eq 'error') {
        $script:ValidationErrors.Add($issue)
        Write-Host "ERROR [$Code] $Message"
    }
    else {
        $script:ValidationWarnings.Add($issue)
        Write-Host "WARNING [$Code] $Message"
    }
}

function Get-FullPath {
    param(
        [string]$Path,
        [string]$BasePath
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        if ([string]::IsNullOrWhiteSpace($BasePath)) {
            $BasePath = (Get-Location).Path
        }
        $Path = Join-Path $BasePath $Path
    }
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Test-PathInside {
    param(
        [string]$Path,
        [string]$Root
    )

    $fullPath = Get-FullPath -Path $Path
    $fullRoot = Get-FullPath -Path $Root
    if ($null -eq $fullPath -or $null -eq $fullRoot) {
        return $false
    }
    if ($fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $fullPath.StartsWith(
        $fullRoot + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Get-ObjectPropertyValue {
    param(
        [object]$InputObject,
        [string[]]$Names
    )

    if ($null -eq $InputObject) {
        return $null
    }
    foreach ($name in $Names) {
        if ($InputObject -is [System.Collections.IDictionary]) {
            foreach ($key in $InputObject.Keys) {
                if ([string]$key -ieq $name) {
                    return $InputObject[$key]
                }
            }
        }
        else {
            $property = $InputObject.PSObject.Properties |
                Where-Object { $_.Name -ieq $name } |
                Select-Object -First 1
            if ($null -ne $property) {
                return $property.Value
            }
        }
    }
    return $null
}

function ConvertTo-ValidatorSkillName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }
    $normalizer = Get-Command -Name 'Normalize-SkillName' -ErrorAction SilentlyContinue
    if ($null -ne $normalizer) {
        try {
            return [string](& $normalizer $Name)
        }
        catch {
            # Fall back to the package normalization rule for validation output.
        }
    }
    return (($Name.Trim().ToLowerInvariant() -replace '[^a-z0-9]+', '-') -replace '(^-+|-+$)', '')
}

function Get-LocalSkillMetadata {
    param([string]$SkillRoot)

    $skillFile = Join-Path $SkillRoot 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillFile -PathType Leaf)) {
        throw "SKILL.md is missing."
    }
    $lines = @(Get-Content -LiteralPath $skillFile)
    if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') {
        throw "SKILL.md must begin with YAML frontmatter."
    }

    $closingIndex = -1
    for ($index = 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index].Trim() -eq '---') {
            $closingIndex = $index
            break
        }
    }
    if ($closingIndex -lt 0) {
        throw "SKILL.md YAML frontmatter is not closed."
    }

    $metadata = @{}
    for ($index = 1; $index -lt $closingIndex; $index++) {
        $line = $lines[$index]
        if ($line -notmatch '^\s*([A-Za-z0-9_-]+)\s*:\s*(.*?)\s*$') {
            continue
        }
        $key = $matches[1]
        $value = $matches[2].Trim()
        if ($value -in @('|', '>')) {
            $blockLines = New-Object System.Collections.Generic.List[string]
            for ($blockIndex = $index + 1; $blockIndex -lt $closingIndex; $blockIndex++) {
                if ($lines[$blockIndex] -notmatch '^\s+') {
                    break
                }
                $blockLines.Add($lines[$blockIndex].Trim())
                $index = $blockIndex
            }
            $value = ($blockLines -join ' ').Trim()
        }
        $metadata[$key] = $value.Trim('"', "'")
    }
    return $metadata
}

function Get-ValidatorSkillMetadata {
    param([string]$SkillRoot)

    $metadataCommand = Get-Command -Name 'Get-SkillMetadata' -ErrorAction SilentlyContinue
    if ($null -ne $metadataCommand) {
        foreach ($candidate in @($SkillRoot, (Join-Path $SkillRoot 'SKILL.md'))) {
            try {
                $metadata = & $metadataCommand $candidate
                if ($null -ne $metadata) {
                    return $metadata
                }
            }
            catch {
                # The shared helper may reject invalid metadata; parse locally to
                # produce a consistent validation issue without mutating state.
            }
        }
    }
    return Get-LocalSkillMetadata -SkillRoot $SkillRoot
}

function Get-ExistingItem {
    param([string]$Path)

    try {
        return Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
    catch {
        $parent = Split-Path -Parent $Path
        $leaf = Split-Path -Leaf $Path
        if (-not [string]::IsNullOrWhiteSpace($parent) -and (Test-Path -LiteralPath $parent)) {
            return Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ieq $leaf } |
                Select-Object -First 1
        }
        return $null
    }
}

function Test-IsReparsePoint {
    param([object]$Item)

    return ($null -ne $Item -and
        (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0))
}

function Test-IsJunction {
    param([object]$Item)

    if (-not (Test-IsReparsePoint -Item $Item)) {
        return $false
    }
    $linkType = Get-ObjectPropertyValue -InputObject $Item -Names @('LinkType')
    return ([string]$linkType -eq 'Junction')
}

function Get-LinkTargetPath {
    param(
        [string]$Path,
        [object]$Item
    )

    if ($null -eq $Item) {
        $Item = Get-ExistingItem -Path $Path
    }
    if (-not (Test-IsReparsePoint -Item $Item)) {
        return $null
    }

    $target = $null
    $targetHelper = Get-Command -Name 'Get-ReparsePointTarget' -ErrorAction SilentlyContinue
    if ($null -ne $targetHelper) {
        try {
            $target = & $targetHelper $Path
        }
        catch {
            # Use the FileSystem provider target when the helper cannot resolve it.
        }
    }
    if ($null -eq $target) {
        $target = $Item.Target
    }
    if ($target -is [System.Array]) {
        $target = $target | Select-Object -First 1
    }
    if ([string]::IsNullOrWhiteSpace([string]$target)) {
        return $null
    }
    return Get-FullPath -Path ([string]$target) -BasePath (Split-Path -Parent $Path)
}

function Get-ConfiguredAgentRoots {
    param([hashtable]$ProvidedRoots)

    $rootsHelper = Get-Command -Name 'Get-AgentSkillRoots' -ErrorAction SilentlyContinue
    if ($null -ne $rootsHelper) {
        try {
            $roots = & $rootsHelper -AgentRoots $ProvidedRoots
            $converted = @{}
            if ($roots -is [System.Collections.IDictionary]) {
                foreach ($key in $roots.Keys) {
                    $converted[[string]$key] = [string]$roots[$key]
                }
            }
            elseif ($null -ne $roots) {
                foreach ($property in $roots.PSObject.Properties) {
                    $converted[$property.Name] = [string]$property.Value
                }
            }
            if ($converted.Count -gt 0) {
                return $converted
            }
        }
        catch {
            # Use documented defaults when the common helper requires context.
        }
    }

    if ($null -ne $ProvidedRoots) {
        return $ProvidedRoots
    }

    $homeRoot = [Environment]::GetFolderPath('UserProfile')
    return @{
        claude = Join-Path $homeRoot '.claude\skills'
        codex = Join-Path $homeRoot '.agents\skills'
        cursor = Join-Path $homeRoot '.cursor\skills'
        gemini = Join-Path $homeRoot '.gemini\skills'
    }
}

function Get-ManagedLinkRecords {
    param(
        [object]$ManagedLinks,
        [hashtable]$ResolvedAgentRoots
    )

    $records = New-Object System.Collections.Generic.List[object]

    function Visit-ManagedLinks {
        param(
            [object]$Node,
            [string[]]$Trail
        )

        if ($null -eq $Node) {
            return
        }

        if ($Node -is [string]) {
            $path = $null
            $target = $null
            if ($Trail.Count -gt 0 -and [System.IO.Path]::IsPathRooted($Trail[-1])) {
                $path = $Trail[-1]
                $target = $Node
            }
            elseif ($Trail.Count -ge 2 -and $ResolvedAgentRoots.ContainsKey($Trail[-2])) {
                $path = Join-Path $ResolvedAgentRoots[$Trail[-2]] $Trail[-1]
                $target = $Node
            }
            $records.Add([pscustomobject]@{ path = $path; target = $target; trail = $Trail })
            return
        }

        if ($Node -is [System.Collections.IDictionary]) {
            $keys = @($Node.Keys)
            $path = Get-ObjectPropertyValue -InputObject $Node -Names @('path', 'linkPath')
            $target = Get-ObjectPropertyValue -InputObject $Node -Names @('target', 'targetPath')
            if ($null -ne $path -or $null -ne $target) {
                $records.Add([pscustomobject]@{
                    path = [string]$path
                    target = [string]$target
                    trail = $Trail
                })
                return
            }
            foreach ($key in $keys) {
                Visit-ManagedLinks -Node $Node[$key] -Trail ($Trail + @([string]$key))
            }
            return
        }

        if ($Node -is [System.Collections.IEnumerable] -and -not ($Node -is [string])) {
            foreach ($child in $Node) {
                Visit-ManagedLinks -Node $child -Trail $Trail
            }
            return
        }

        $properties = @($Node.PSObject.Properties)
        $path = Get-ObjectPropertyValue -InputObject $Node -Names @('path', 'linkPath')
        $target = Get-ObjectPropertyValue -InputObject $Node -Names @('target', 'targetPath')
        if ($null -ne $path -or $null -ne $target) {
            $records.Add([pscustomobject]@{
                path = [string]$path
                target = [string]$target
                trail = $Trail
            })
            return
        }
        foreach ($property in $properties) {
            Visit-ManagedLinks -Node $property.Value -Trail ($Trail + @($property.Name))
        }
    }

    Visit-ManagedLinks -Node $ManagedLinks -Trail @()
    return $records.ToArray()
}

function Test-ManagedView {
    param(
        [string]$Path,
        [string]$Target,
        [object[]]$ManagedLinkRecords,
        [string]$PackageRoot
    )

    foreach ($record in $ManagedLinkRecords) {
        if (-not [string]::IsNullOrWhiteSpace([string]$record.path)) {
            $recordPath = Get-FullPath -Path ([string]$record.path)
            if ($recordPath -ieq (Get-FullPath -Path $Path)) {
                return $true
            }
        }
    }

    $managedLinkHelper = Get-Command -Name 'Test-PackageManagedLink' -ErrorAction SilentlyContinue
    if ($null -ne $managedLinkHelper) {
        try {
            return [bool](& $managedLinkHelper $Path)
        }
        catch {
            # Fall through to target containment for stale managed Junctions.
        }
    }
    return (-not [string]::IsNullOrWhiteSpace($Target) -and
        (Test-PathInside -Path $Target -Root $PackageRoot))
}

function Get-CanonicalSkills {
    param(
        [string]$Root,
        [string]$State,
        [string]$PackageRoot
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        Add-ValidationIssue -Severity error -Code 'canonical-root-missing' `
            -Message "Canonical $State root is missing: $Root" -Path $Root
        return @()
    }

    $skills = New-Object System.Collections.Generic.List[object]
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue)) {
        if (-not $item.PSIsContainer -and -not (Test-IsReparsePoint -Item $item)) {
            Add-ValidationIssue -Severity error -Code 'canonical-entry-not-directory' `
                -Message "Canonical $State entry is not a skill directory: $($item.FullName)" `
                -Path $item.FullName
            continue
        }

        $normalizedDirectoryName = ConvertTo-ValidatorSkillName -Name $item.Name
        $skill = [pscustomobject]@{
            name = $normalizedDirectoryName
            directoryName = $item.Name
            path = $item.FullName
            state = $State
            metadata = $null
        }
        $skills.Add($skill)
        $script:ValidatedCanonicalSkills.Add($skill)

        if ($item.Name -cne $normalizedDirectoryName) {
            Add-ValidationIssue -Severity error -Code 'canonical-name-not-normalized' `
                -Message "Canonical skill directory name must be normalized as '$normalizedDirectoryName': $($item.FullName)" `
                -Path $item.FullName
        }

        if (Test-IsReparsePoint -Item $item) {
            $target = Get-LinkTargetPath -Path $item.FullName -Item $item
            if ([string]::IsNullOrWhiteSpace($target)) {
                Add-ValidationIssue -Severity error -Code 'canonical-broken-link' `
                    -Message "Canonical skill link has no resolvable target: $($item.FullName)" `
                    -Path $item.FullName
            }
            elseif (-not (Test-Path -LiteralPath $target)) {
                Add-ValidationIssue -Severity error -Code 'canonical-broken-link' `
                    -Message "Canonical skill link target is missing: $($item.FullName) -> $target" `
                    -Path $item.FullName
            }
            elseif (-not (Test-PathInside -Path $target -Root $PackageRoot)) {
                Add-ValidationIssue -Severity error -Code 'canonical-external-junction' `
                    -Message "Canonical skill must not be an external Junction: $($item.FullName) -> $target" `
                    -Path $item.FullName
            }
            else {
                Add-ValidationIssue -Severity error -Code 'canonical-junction' `
                    -Message "Canonical skill must be a copied directory, not a Junction: $($item.FullName)" `
                    -Path $item.FullName
            }
        }

        try {
            $metadata = Get-ValidatorSkillMetadata -SkillRoot $item.FullName
            $skill.metadata = $metadata
            $metadataName = [string](Get-ObjectPropertyValue -InputObject $metadata -Names @('name'))
            $metadataDescription = [string](Get-ObjectPropertyValue -InputObject $metadata -Names @('description'))
            if ([string]::IsNullOrWhiteSpace($metadataName)) {
                Add-ValidationIssue -Severity error -Code 'metadata-name-missing' `
                    -Message "Skill metadata name is missing: $($item.FullName)" -Path $item.FullName
            }
            elseif ((ConvertTo-ValidatorSkillName -Name $metadataName) -ne $normalizedDirectoryName) {
                Add-ValidationIssue -Severity error -Code 'metadata-name-mismatch' `
                    -Message "Skill directory '$($item.Name)' does not match metadata name '$metadataName'." `
                    -Path $item.FullName
            }
            if ([string]::IsNullOrWhiteSpace($metadataDescription)) {
                Add-ValidationIssue -Severity error -Code 'metadata-description-missing' `
                    -Message "Skill metadata description is missing: $($item.FullName)" -Path $item.FullName
            }
        }
        catch {
            Add-ValidationIssue -Severity error -Code 'metadata-invalid' `
                -Message "Invalid skill metadata in $($item.FullName): $($_.Exception.Message)" `
                -Path $item.FullName
        }
    }
    return $skills.ToArray()
}

function Test-GeneratedRoot {
    param(
        [string]$Agent,
        [string]$Root,
        [object[]]$EnabledSkills,
        [object[]]$DisabledSkills,
        [object[]]$ManagedLinkRecords,
        [string]$PackageRoot
    )

    $rootItem = Get-ExistingItem -Path $Root
    if ($null -eq $rootItem) {
        if ($EnabledSkills.Count -gt 0) {
            Add-ValidationIssue -Severity error -Code 'agent-root-missing' `
                -Message "Generated root for $Agent is missing: $Root" -Path $Root
        }
        return
    }

    if (Test-IsReparsePoint -Item $rootItem) {
        $rootTarget = Get-LinkTargetPath -Path $Root -Item $rootItem
        if ([string]::IsNullOrWhiteSpace($rootTarget) -or -not (Test-Path -LiteralPath $rootTarget)) {
            Add-ValidationIssue -Severity error -Code 'agent-root-broken-link' `
                -Message "Generated root for $Agent is a broken Junction: $Root -> $rootTarget" -Path $Root
            return
        }
        Add-ValidationIssue -Severity warning -Code 'agent-root-junction' `
            -Message "Generated root for $Agent is itself a Junction; per-skill Junctions are expected: $Root" `
            -Path $Root
    }

    foreach ($child in @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue)) {
        if (Test-IsReparsePoint -Item $child) {
            $childTarget = Get-LinkTargetPath -Path $child.FullName -Item $child
            if ([string]::IsNullOrWhiteSpace($childTarget) -or -not (Test-Path -LiteralPath $childTarget)) {
                Add-ValidationIssue -Severity error -Code 'broken-link' `
                    -Message "Broken Junction in generated root for ${Agent}: $($child.FullName) -> $childTarget" `
                    -Path $child.FullName
            }
        }
    }

    foreach ($skill in $EnabledSkills) {
        $viewPath = Join-Path $Root $skill.directoryName
        $viewItem = Get-ExistingItem -Path $viewPath
        if ($null -eq $viewItem) {
            Add-ValidationIssue -Severity error -Code 'enabled-view-missing' `
                -Message "Enabled skill '$($skill.name)' has no $Agent Junction view: $viewPath" -Path $viewPath
            continue
        }
        if (-not (Test-IsReparsePoint -Item $viewItem)) {
            Add-ValidationIssue -Severity error -Code 'unrelated-path-conflict' `
                -Message "Enabled skill '$($skill.name)' is blocked by an unrelated $Agent path: $viewPath" `
                -Path $viewPath
            continue
        }
        if (-not (Test-IsJunction -Item $viewItem)) {
            Add-ValidationIssue -Severity error -Code 'enabled-view-not-junction' `
                -Message "Enabled skill '$($skill.name)' must use a $Agent Junction view: $viewPath" `
                -Path $viewPath
            continue
        }
        $target = Get-LinkTargetPath -Path $viewPath -Item $viewItem
        if ([string]::IsNullOrWhiteSpace($target) -or -not (Test-Path -LiteralPath $target)) {
            Add-ValidationIssue -Severity error -Code 'enabled-view-broken-link' `
                -Message "Enabled skill '$($skill.name)' has a broken $Agent Junction: $viewPath -> $target" `
                -Path $viewPath
            continue
        }
        if ((Get-FullPath -Path $target) -ine (Get-FullPath -Path $skill.path)) {
            Add-ValidationIssue -Severity error -Code 'unrelated-junction-conflict' `
                -Message "Enabled skill '$($skill.name)' has an unrelated $Agent Junction target: $viewPath -> $target" `
                -Path $viewPath
        }
    }

    foreach ($skill in $DisabledSkills) {
        $viewPath = Join-Path $Root $skill.directoryName
        $viewItem = Get-ExistingItem -Path $viewPath
        if ($null -eq $viewItem -or -not (Test-IsReparsePoint -Item $viewItem)) {
            continue
        }
        $target = Get-LinkTargetPath -Path $viewPath -Item $viewItem
        if (Test-ManagedView -Path $viewPath -Target $target -ManagedLinkRecords $ManagedLinkRecords `
                -PackageRoot $PackageRoot) {
            Add-ValidationIssue -Severity error -Code 'disabled-managed-view' `
                -Message "Disabled skill '$($skill.name)' still has a package-managed $Agent Junction: $viewPath" `
                -Path $viewPath
        }
    }
}

$packageRoot = Get-FullPath -Path (Get-AgentSkillsPackageRoot -ScriptRoot $PSScriptRoot)
$enabledRoot = Join-Path $packageRoot 'skills'
$disabledRoot = Join-Path $packageRoot 'skills-disabled'
$manifestPath = Join-Path $packageRoot 'config\skills.json'
$reportsRoot = Join-Path $packageRoot 'reports'

$resolvedAgentRoots = Get-ConfiguredAgentRoots -ProvidedRoots $AgentRoots
foreach ($requiredAgent in @('claude', 'codex', 'cursor', 'gemini')) {
    if (-not $resolvedAgentRoots.ContainsKey($requiredAgent) -or
        [string]::IsNullOrWhiteSpace([string]$resolvedAgentRoots[$requiredAgent])) {
        Add-ValidationIssue -Severity error -Code 'agent-root-not-configured' `
            -Message "Agent root is not configured for '$requiredAgent'." -Path $null
    }
    else {
        $resolvedAgentRoots[$requiredAgent] = Get-FullPath -Path ([string]$resolvedAgentRoots[$requiredAgent])
    }
}

$manifest = $null
$managedLinks = $null
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Add-ValidationIssue -Severity error -Code 'manifest-missing' `
        -Message "Manifest is missing: $manifestPath" -Path $manifestPath
}
else {
    try {
        $manifest = Read-AgentSkillsManifest -PackageRoot $packageRoot
        $managedLinks = Get-ObjectPropertyValue -InputObject $manifest -Names @('managedLinks')
    }
    catch {
        Add-ValidationIssue -Severity error -Code 'manifest-invalid' `
            -Message "Manifest is not valid JSON: $manifestPath. $($_.Exception.Message)" -Path $manifestPath
    }
}

$enabledSkills = @(Get-CanonicalSkills -Root $enabledRoot -State 'enabled' -PackageRoot $packageRoot)
$disabledSkills = @(Get-CanonicalSkills -Root $disabledRoot -State 'disabled' -PackageRoot $packageRoot)

$canonicalNames = @{}
foreach ($skill in @($enabledSkills) + @($disabledSkills)) {
    if ($canonicalNames.ContainsKey($skill.name)) {
        Add-ValidationIssue -Severity error -Code 'duplicate-canonical-skill' `
            -Message "Duplicate canonical skill identifier '$($skill.name)' exists in multiple canonical directories." `
            -Path $skill.path
    }
    else {
        $canonicalNames[$skill.name] = $skill
    }
}

$managedLinkRecords = @(Get-ManagedLinkRecords -ManagedLinks $managedLinks `
    -ResolvedAgentRoots $resolvedAgentRoots)
foreach ($record in $managedLinkRecords) {
    if ([string]::IsNullOrWhiteSpace([string]$record.target)) {
        continue
    }
    $target = Get-FullPath -Path ([string]$record.target) -BasePath $packageRoot
    if (-not (Test-PathInside -Path $target -Root $packageRoot)) {
        Add-ValidationIssue -Severity error -Code 'managed-target-outside-package' `
            -Message "Managed Junction target is outside this package: $target" -Path ([string]$record.path)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$record.path)) {
        $item = Get-ExistingItem -Path ([string]$record.path)
        if ($null -ne $item -and (Test-IsReparsePoint -Item $item)) {
            $actualTarget = Get-LinkTargetPath -Path ([string]$record.path) -Item $item
            if ([string]::IsNullOrWhiteSpace($actualTarget) -or -not (Test-Path -LiteralPath $actualTarget)) {
                Add-ValidationIssue -Severity error -Code 'managed-broken-link' `
                    -Message "Managed Junction is broken: $($record.path) -> $actualTarget" `
                    -Path ([string]$record.path)
            }
        }
    }
}

if (-not $SkipGeneratedViews) {
    foreach ($agent in @('claude', 'codex', 'cursor', 'gemini')) {
        if ($resolvedAgentRoots.ContainsKey($agent) -and
            -not [string]::IsNullOrWhiteSpace([string]$resolvedAgentRoots[$agent])) {
            Test-GeneratedRoot -Agent $agent -Root $resolvedAgentRoots[$agent] `
                -EnabledSkills $enabledSkills -DisabledSkills $disabledSkills `
                -ManagedLinkRecords $managedLinkRecords -PackageRoot $packageRoot
        }
    }
}

$report = [ordered]@{
    type = 'validation'
    generatedAt = [DateTime]::UtcNow.ToString('o')
    packageRoot = $packageRoot
    skipGeneratedViews = [bool]$SkipGeneratedViews
    summary = [ordered]@{
        canonicalSkills = $script:ValidatedCanonicalSkills.Count
        enabledSkills = $enabledSkills.Count
        disabledSkills = $disabledSkills.Count
        managedLinks = $managedLinkRecords.Count
        errors = $script:ValidationErrors.Count
        warnings = $script:ValidationWarnings.Count
    }
    errors = $script:ValidationErrors.ToArray()
    warnings = $script:ValidationWarnings.ToArray()
}

$reportPath = Write-AgentSkillsReport -ReportType 'validation' -Data $report -PackageRoot $packageRoot

Write-Host (
    'Validation summary: {0} canonical skill(s), {1} enabled, {2} disabled, {3} managed link record(s), {4} error(s), {5} warning(s).' -f
    $script:ValidatedCanonicalSkills.Count,
    $enabledSkills.Count,
    $disabledSkills.Count,
    $managedLinkRecords.Count,
    $script:ValidationErrors.Count,
    $script:ValidationWarnings.Count
)
Write-Host "Validation report: $reportPath"

if ($script:ValidationErrors.Count -gt 0) {
    exit 1
}
exit 0
