$script:AgentSkillsCommonScriptRoot = $PSScriptRoot

function ConvertTo-AgentSkillsFullPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Path must not be empty.'
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)

    while (
        $fullPath.Length -gt $pathRoot.Length -and
        ($fullPath.EndsWith([System.IO.Path]::DirectorySeparatorChar) -or
            $fullPath.EndsWith([System.IO.Path]::AltDirectorySeparatorChar))
    ) {
        $fullPath = $fullPath.Substring(0, $fullPath.Length - 1)
    }

    return $fullPath
}

function Test-AgentSkillsPathEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Left,

        [Parameter(Mandatory = $true)]
        [string]$Right
    )

    $leftPath = ConvertTo-AgentSkillsFullPath -Path $Left
    $rightPath = ConvertTo-AgentSkillsFullPath -Path $Right

    return [string]::Equals(
        $leftPath,
        $rightPath,
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Get-AgentSkillsPathItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        return Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
    catch {
        if ($_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound) {
            return $null
        }

        throw
    }
}

function Test-AgentSkillsObjectProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $false
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        return $InputObject.Contains($Name)
    }

    return $null -ne $InputObject.PSObject.Properties[$Name]
}

function Get-AgentSkillsObjectProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Test-AgentSkillsObjectProperty -InputObject $InputObject -Name $Name)) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        return $InputObject[$Name]
    }

    return $InputObject.PSObject.Properties[$Name].Value
}

function Set-AgentSkillsObjectProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Value
    )

    if ($InputObject -is [System.Collections.IDictionary]) {
        $InputObject[$Name] = $Value
        return
    }

    $InputObject | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
}

function Remove-AgentSkillsObjectProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($InputObject -is [System.Collections.IDictionary]) {
        $InputObject.Remove($Name)
        return
    }

    $InputObject.PSObject.Properties.Remove($Name)
}

function Get-AgentSkillsPackageRoot {
    [CmdletBinding()]
    param(
        [string]$ScriptRoot = $script:AgentSkillsCommonScriptRoot
    )

    if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
        throw 'Unable to determine the package root because the script root is empty.'
    }

    return ConvertTo-AgentSkillsFullPath -Path (Join-Path $ScriptRoot '..')
}

function Get-AgentSkillRoots {
    [CmdletBinding()]
    param(
        [Alias('Overrides')]
        [hashtable]$AgentRoots
    )

    $homePath = $HOME
    if ([string]::IsNullOrWhiteSpace($homePath)) {
        $homePath = [System.Environment]::GetFolderPath(
            [System.Environment+SpecialFolder]::UserProfile
        )
    }

    if ([string]::IsNullOrWhiteSpace($homePath)) {
        throw 'Unable to determine the current user profile directory.'
    }

    $roots = [ordered]@{
        claude = Join-Path $homePath '.claude\skills'
        codex  = Join-Path $homePath '.agents\skills'
        cursor = Join-Path $homePath '.cursor\skills'
        gemini = Join-Path $homePath '.gemini\skills'
    }

    if ($null -ne $AgentRoots) {
        foreach ($entry in $AgentRoots.GetEnumerator()) {
            $agent = ([string]$entry.Key).Trim().ToLowerInvariant()
            if (-not $roots.Contains($agent)) {
                throw "Unsupported agent root override '$($entry.Key)'."
            }

            if ([string]::IsNullOrWhiteSpace([string]$entry.Value)) {
                throw "Agent root override '$agent' must not be empty."
            }

            $roots[$agent] = [string]$entry.Value
        }
    }

    foreach ($agent in @($roots.Keys)) {
        $roots[$agent] = ConvertTo-AgentSkillsFullPath -Path $roots[$agent]
    }

    return $roots
}

function Get-AgentSkillsManifestPath {
    [CmdletBinding()]
    param(
        [string]$PackageRoot = (Get-AgentSkillsPackageRoot),

        [string]$ManifestPath
    )

    $packagePath = ConvertTo-AgentSkillsFullPath -Path $PackageRoot
    if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        $ManifestPath = Join-Path $packagePath 'config\skills.json'
    }

    return Assert-PathWithinRoot -Path $ManifestPath -Root $packagePath
}

function Assert-AgentSkillsManifestObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest
    )

    foreach ($propertyName in @('schemaVersion', 'agents', 'skills', 'managedLinks')) {
        if (-not (Test-AgentSkillsObjectProperty -InputObject $Manifest -Name $propertyName)) {
            throw "Skills manifest is missing required property '$propertyName'."
        }
    }

    $schemaVersion = Get-AgentSkillsObjectProperty -InputObject $Manifest -Name 'schemaVersion'
    if ([int]$schemaVersion -ne 1) {
        throw "Unsupported skills manifest schema version '$schemaVersion'."
    }

    $agents = @(Get-AgentSkillsObjectProperty -InputObject $Manifest -Name 'agents')
    if ($agents.Count -eq 0) {
        throw 'Skills manifest agents must not be empty.'
    }

    $seenAgents = @{}
    foreach ($agentValue in $agents) {
        $agent = ([string]$agentValue).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($agent)) {
            throw 'Skills manifest agent names must not be empty.'
        }

        if ($seenAgents.ContainsKey($agent)) {
            throw "Skills manifest contains duplicate agent '$agent'."
        }

        $seenAgents[$agent] = $true
    }

    foreach ($propertyName in @('skills', 'managedLinks')) {
        if ($null -eq (Get-AgentSkillsObjectProperty -InputObject $Manifest -Name $propertyName)) {
            throw "Skills manifest property '$propertyName' must be an object."
        }
    }
}

function Read-AgentSkillsManifest {
    [CmdletBinding()]
    param(
        [string]$PackageRoot = (Get-AgentSkillsPackageRoot),

        [string]$ManifestPath
    )

    $path = Get-AgentSkillsManifestPath -PackageRoot $PackageRoot -ManifestPath $ManifestPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Skills manifest does not exist: $path"
    }

    try {
        $manifest = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Unable to read skills manifest '$path': $($_.Exception.Message)"
    }

    Assert-AgentSkillsManifestObject -Manifest $manifest
    return $manifest
}

function Write-AgentSkillsManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest,

        [string]$PackageRoot = (Get-AgentSkillsPackageRoot),

        [string]$ManifestPath
    )

    Assert-AgentSkillsManifestObject -Manifest $Manifest

    $packagePath = ConvertTo-AgentSkillsFullPath -Path $PackageRoot
    $path = Get-AgentSkillsManifestPath -PackageRoot $packagePath -ManifestPath $ManifestPath
    $configRoot = Assert-PathWithinRoot -Path (Split-Path -Parent $path) -Root $packagePath

    if (-not (Test-Path -LiteralPath $configRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $configRoot -Force -ErrorAction Stop | Out-Null
    }

    $temporaryPath = Join-Path $configRoot ('.skills.{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    $json = $Manifest | ConvertTo-Json -Depth 100
    $encoding = New-Object System.Text.UTF8Encoding($false)

    try {
        [System.IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, $encoding)
        Move-Item -LiteralPath $temporaryPath -Destination $path -Force -ErrorAction Stop
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }

    return $path
}

function Normalize-SkillName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$Name
    )

    process {
        if ([string]::IsNullOrWhiteSpace($Name)) {
            throw 'Skill name must not be empty.'
        }

        $normalized = [regex]::Replace(
            $Name.Trim().ToLowerInvariant(),
            '[^a-z0-9]+',
            '-'
        ).Trim('-')

        if ([string]::IsNullOrWhiteSpace($normalized)) {
            throw "Skill name '$Name' does not contain any ASCII letters or digits."
        }

        return $normalized
    }
}

function ConvertFrom-AgentSkillsYamlScalar {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    $scalar = $Value.Trim()
    if ($scalar.Length -ge 2 -and $scalar[0] -eq "'" -and $scalar[$scalar.Length - 1] -eq "'") {
        return $scalar.Substring(1, $scalar.Length - 2).Replace("''", "'")
    }

    if ($scalar.Length -ge 2 -and $scalar[0] -eq '"' -and $scalar[$scalar.Length - 1] -eq '"') {
        $inner = $scalar.Substring(1, $scalar.Length - 2)
        return [regex]::Unescape($inner)
    }

    return [regex]::Replace($scalar, '\s+#.*$', '').Trim()
}

function Get-AgentSkillsYamlScalar {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$Lines,

        [Parameter(Mandatory = $true)]
        [int]$Index,

        [AllowNull()]
        [string]$RawValue
    )

    $value = ''
    if ($null -ne $RawValue) {
        $value = $RawValue.Trim()
    }

    $isFolded = $value -match '^>[+-]?$'
    $isLiteral = $value -match '^\|[+-]?$'
    if (-not $isFolded -and -not $isLiteral -and $value.Length -gt 0) {
        return ConvertFrom-AgentSkillsYamlScalar -Value $value
    }

    $continuationLines = New-Object 'System.Collections.Generic.List[string]'
    for ($lineIndex = $Index + 1; $lineIndex -lt $Lines.Count; $lineIndex++) {
        $line = $Lines[$lineIndex]
        if ($line.Length -gt 0 -and -not [char]::IsWhiteSpace($line[0])) {
            break
        }

        if ($line.Length -eq 0) {
            $continuationLines.Add('')
        }
        else {
            $continuationLines.Add($line.Trim())
        }
    }

    if ($isLiteral) {
        return ($continuationLines -join [Environment]::NewLine).Trim()
    }

    return ($continuationLines -join ' ').Trim()
}

function Get-SkillMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SkillPath
    )

    $fullPath = ConvertTo-AgentSkillsFullPath -Path $SkillPath
    $item = Get-AgentSkillsPathItem -Path $fullPath
    if ($null -eq $item) {
        throw "Skill path does not exist: $fullPath"
    }

    if ($item.PSIsContainer) {
        $skillRoot = $item.FullName
        $metadataPath = Join-Path $skillRoot 'SKILL.md'
    }
    else {
        if ($item.Name -ne 'SKILL.md') {
            throw "Skill metadata file must be named SKILL.md: $fullPath"
        }

        $metadataPath = $item.FullName
        $skillRoot = Split-Path -Parent $metadataPath
    }

    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw "Skill metadata file does not exist: $metadataPath"
    }

    $frontmatter = New-Object 'System.Collections.Generic.List[string]'
    $reader = New-Object System.IO.StreamReader($metadataPath, [System.Text.Encoding]::UTF8, $true)

    try {
        $firstLine = $reader.ReadLine()
        if ($null -eq $firstLine -or $firstLine.Trim() -ne '---') {
            throw "Skill metadata must begin with YAML frontmatter: $metadataPath"
        }

        $foundClosingDelimiter = $false
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line.Trim() -eq '---') {
                $foundClosingDelimiter = $true
                break
            }

            $frontmatter.Add($line)
        }

        if (-not $foundClosingDelimiter) {
            throw "Skill metadata frontmatter is not closed: $metadataPath"
        }
    }
    finally {
        $reader.Dispose()
    }

    $metadata = @{}
    for ($lineIndex = 0; $lineIndex -lt $frontmatter.Count; $lineIndex++) {
        $line = $frontmatter[$lineIndex]
        if ($line -notmatch '^(?<key>[A-Za-z][A-Za-z0-9_-]*)\s*:\s*(?<value>.*)$') {
            continue
        }

        $key = $matches['key'].ToLowerInvariant()
        if ($key -notin @('name', 'description')) {
            continue
        }

        if ($metadata.ContainsKey($key)) {
            throw "Skill metadata contains duplicate '$key' fields: $metadataPath"
        }

        $metadata[$key] = Get-AgentSkillsYamlScalar `
            -Lines $frontmatter `
            -Index $lineIndex `
            -RawValue $matches['value']
    }

    foreach ($requiredField in @('name', 'description')) {
        if (-not $metadata.ContainsKey($requiredField) -or
            [string]::IsNullOrWhiteSpace([string]$metadata[$requiredField])) {
            throw "Skill metadata requires a non-empty '$requiredField': $metadataPath"
        }
    }

    return [pscustomobject]@{
        Name           = [string]$metadata['name']
        Description    = [string]$metadata['description']
        NormalizedName = Normalize-SkillName -Name ([string]$metadata['name'])
        SkillPath      = ConvertTo-AgentSkillsFullPath -Path $skillRoot
        MetadataPath   = ConvertTo-AgentSkillsFullPath -Path $metadataPath
    }
}

function Test-PathWithinRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    try {
        $fullPath = ConvertTo-AgentSkillsFullPath -Path $Path
        $fullRoot = ConvertTo-AgentSkillsFullPath -Path $Root
    }
    catch {
        return $false
    }

    if ([string]::Equals($fullPath, $fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $rootWithSeparator = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    return $fullPath.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-PathWithinRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    if (-not (Test-PathWithinRoot -Path $Path -Root $Root)) {
        throw "Path '$Path' is outside allowed root '$Root'."
    }

    return ConvertTo-AgentSkillsFullPath -Path $Path
}

function Get-AgentSkillsRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $fullPath = Assert-PathWithinRoot -Path $Path -Root $Root
    $fullRoot = ConvertTo-AgentSkillsFullPath -Path $Root
    if (Test-AgentSkillsPathEqual -Left $fullPath -Right $fullRoot) {
        return ''
    }

    return $fullPath.Substring($fullRoot.Length).TrimStart('\', '/').Replace('\', '/')
}

function Get-DirectoryFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $rootPath = ConvertTo-AgentSkillsFullPath -Path $Path
    if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
        throw "Fingerprint directory does not exist: $rootPath"
    }

    $entries = New-Object 'System.Collections.Generic.List[string]'
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($rootPath)

    while ($pending.Count -gt 0) {
        $currentPath = $pending.Pop()
        $children = @(Get-ChildItem -LiteralPath $currentPath -Force -ErrorAction Stop |
                Sort-Object -Property FullName)

        foreach ($child in $children) {
            $relativePath = Get-AgentSkillsRelativePath -Path $child.FullName -Root $rootPath
            if ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                $target = Get-ReparsePointTarget -Path $child.FullName
                $entries.Add(('L|{0}|{1}' -f $relativePath, $target))
                continue
            }

            if ($child.PSIsContainer) {
                $entries.Add(('D|{0}' -f $relativePath))
                $pending.Push($child.FullName)
                continue
            }

            $hash = (Get-FileHash -LiteralPath $child.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
            $entries.Add(('F|{0}|{1}' -f $relativePath, $hash.ToLowerInvariant()))
        }
    }

    $payload = (@($entries | Sort-Object) -join "`n")
    $sha256 = [System.Security.Cryptography.SHA256]::Create()

    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
        $digest = $sha256.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($digest)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Write-AgentSkillsReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Alias('Name', 'Type')]
        [string]$ReportType,

        [Parameter(Mandatory = $true)]
        [Alias('Report')]
        [object]$Data,

        [string]$PackageRoot = (Get-AgentSkillsPackageRoot)
    )

    $packagePath = ConvertTo-AgentSkillsFullPath -Path $PackageRoot
    $reportRoot = Assert-PathWithinRoot -Path (Join-Path $packagePath 'reports') -Root $packagePath
    if (-not (Test-Path -LiteralPath $reportRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $reportRoot -Force -ErrorAction Stop | Out-Null
    }

    $normalizedType = Normalize-SkillName -Name $ReportType
    $timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $reportPath = Join-Path $reportRoot ('{0}-{1}.json' -f $timestamp, $normalizedType)

    if (Test-Path -LiteralPath $reportPath) {
        $reportPath = Join-Path $reportRoot (
            '{0}-{1}-{2}.json' -f $timestamp, $normalizedType, [guid]::NewGuid().ToString('N').Substring(0, 8)
        )
    }

    $json = $Data | ConvertTo-Json -Depth 100
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($reportPath, $json + [Environment]::NewLine, $encoding)

    return ConvertTo-AgentSkillsFullPath -Path $reportPath
}

function Get-ReparsePointTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = ConvertTo-AgentSkillsFullPath -Path $Path
    $item = Get-AgentSkillsPathItem -Path $fullPath
    if ($null -eq $item) {
        return $null
    }

    if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        return $null
    }

    $targets = @($item.Target | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($targets.Count -ne 1) {
        throw "Expected exactly one reparse point target for '$fullPath'."
    }

    $target = [string]$targets[0]
    if (-not [System.IO.Path]::IsPathRooted($target)) {
        $target = Join-Path (Split-Path -Parent $fullPath) $target
    }

    return ConvertTo-AgentSkillsFullPath -Path $target
}

function Get-AgentSkillsManagedLinkKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Agent,

        [Parameter(Mandatory = $true)]
        [string]$SkillName
    )

    $agentName = $Agent.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($agentName) -or $agentName -notmatch '^[a-z0-9-]+$') {
        throw "Invalid agent name '$Agent'."
    }

    return '{0}/{1}' -f $agentName, (Normalize-SkillName -Name $SkillName)
}

function Get-AgentSkillsManagedLinkRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest,

        [Parameter(Mandatory = $true)]
        [string]$Agent,

        [Parameter(Mandatory = $true)]
        [string]$SkillName
    )

    $managedLinks = Get-AgentSkillsObjectProperty -InputObject $Manifest -Name 'managedLinks'
    if ($null -eq $managedLinks) {
        throw 'Skills manifest is missing required property managedLinks.'
    }

    $agentName = $Agent.Trim().ToLowerInvariant()
    $normalizedSkillName = Normalize-SkillName -Name $SkillName
    $key = Get-AgentSkillsManagedLinkKey -Agent $agentName -SkillName $normalizedSkillName
    $record = Get-AgentSkillsObjectProperty -InputObject $managedLinks -Name $key
    if ($null -ne $record) {
        return $record
    }

    # Accept the nested representation so early manifests remain readable.
    $agentLinks = Get-AgentSkillsObjectProperty -InputObject $managedLinks -Name $agentName
    if ($null -eq $agentLinks) {
        return $null
    }

    return Get-AgentSkillsObjectProperty -InputObject $agentLinks -Name $normalizedSkillName
}

function Test-AgentSkillsManagedLinkRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Record,

        [Parameter(Mandatory = $true)]
        [string]$Agent,

        [Parameter(Mandatory = $true)]
        [string]$SkillName,

        [Parameter(Mandatory = $true)]
        [string]$LinkPath,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    if ($null -eq $Record) {
        return $false
    }

    $recordedLinkPath = Get-AgentSkillsObjectProperty -InputObject $Record -Name 'path'
    if ([string]::IsNullOrWhiteSpace([string]$recordedLinkPath)) {
        $recordedLinkPath = Get-AgentSkillsObjectProperty -InputObject $Record -Name 'linkPath'
    }

    $recordedTargetPath = Get-AgentSkillsObjectProperty -InputObject $Record -Name 'target'
    if ([string]::IsNullOrWhiteSpace([string]$recordedTargetPath)) {
        $recordedTargetPath = Get-AgentSkillsObjectProperty -InputObject $Record -Name 'targetPath'
    }

    if ([string]::IsNullOrWhiteSpace([string]$recordedLinkPath) -or
        [string]::IsNullOrWhiteSpace([string]$recordedTargetPath)) {
        return $false
    }

    $recordedAgent = Get-AgentSkillsObjectProperty -InputObject $Record -Name 'agent'
    if (-not [string]::IsNullOrWhiteSpace([string]$recordedAgent) -and
        -not [string]::Equals(
            ([string]$recordedAgent).Trim(),
            $Agent.Trim(),
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        return $false
    }

    $recordedSkill = Get-AgentSkillsObjectProperty -InputObject $Record -Name 'skill'
    if (-not [string]::IsNullOrWhiteSpace([string]$recordedSkill) -and
        -not [string]::Equals(
            (Normalize-SkillName -Name ([string]$recordedSkill)),
            (Normalize-SkillName -Name $SkillName),
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        return $false
    }

    if (-not (Test-AgentSkillsPathEqual -Left ([string]$recordedLinkPath) -Right $LinkPath)) {
        return $false
    }

    return Test-AgentSkillsPathEqual -Left ([string]$recordedTargetPath) -Right $TargetPath
}

function Set-AgentSkillsManagedLinkRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest,

        [Parameter(Mandatory = $true)]
        [string]$Agent,

        [Parameter(Mandatory = $true)]
        [string]$SkillName,

        [Parameter(Mandatory = $true)]
        [string]$LinkPath,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    $managedLinks = Get-AgentSkillsObjectProperty -InputObject $Manifest -Name 'managedLinks'
    if ($null -eq $managedLinks) {
        throw 'Skills manifest is missing required property managedLinks.'
    }

    $agentName = $Agent.Trim().ToLowerInvariant()
    $normalizedSkillName = Normalize-SkillName -Name $SkillName
    $key = Get-AgentSkillsManagedLinkKey -Agent $agentName -SkillName $normalizedSkillName
    $record = [pscustomobject]@{
        agent      = $agentName
        skill      = $normalizedSkillName
        linkPath   = ConvertTo-AgentSkillsFullPath -Path $LinkPath
        targetPath = ConvertTo-AgentSkillsFullPath -Path $TargetPath
    }

    Set-AgentSkillsObjectProperty -InputObject $managedLinks -Name $key -Value $record
}

function Remove-AgentSkillsManagedLinkRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest,

        [Parameter(Mandatory = $true)]
        [string]$Agent,

        [Parameter(Mandatory = $true)]
        [string]$SkillName
    )

    $managedLinks = Get-AgentSkillsObjectProperty -InputObject $Manifest -Name 'managedLinks'
    if ($null -eq $managedLinks) {
        throw 'Skills manifest is missing required property managedLinks.'
    }

    $agentName = $Agent.Trim().ToLowerInvariant()
    $normalizedSkillName = Normalize-SkillName -Name $SkillName
    $key = Get-AgentSkillsManagedLinkKey -Agent $agentName -SkillName $normalizedSkillName
    Remove-AgentSkillsObjectProperty -InputObject $managedLinks -Name $key

    $agentLinks = Get-AgentSkillsObjectProperty -InputObject $managedLinks -Name $agentName
    if ($null -ne $agentLinks) {
        Remove-AgentSkillsObjectProperty -InputObject $agentLinks -Name $normalizedSkillName
    }
}

function Test-PackageManagedLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Alias('Path', 'JunctionPath')]
        [string]$LinkPath,

        [Alias('TargetPath', 'Target')]
        [string]$ExpectedTarget,

        [Alias('ManagedLink', 'ManifestRecord')]
        [object]$Record,

        [object]$Manifest,

        [string]$Agent,

        [Alias('Name')]
        [string]$SkillName,

        [string]$PackageRoot = (Get-AgentSkillsPackageRoot)
    )

    $packagePath = ConvertTo-AgentSkillsFullPath -Path $PackageRoot
    $item = Get-AgentSkillsPathItem -Path $LinkPath
    if ($null -eq $item -or
        -not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or
        $item.LinkType -ne 'Junction') {
        return $false
    }

    $actualTarget = Get-ReparsePointTarget -Path $LinkPath
    if ([string]::IsNullOrWhiteSpace($actualTarget)) {
        return $false
    }

    if (-not (Test-PathWithinRoot -Path $actualTarget -Root $packagePath)) {
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedTarget) -and
        -not (Test-AgentSkillsPathEqual -Left $actualTarget -Right $ExpectedTarget)) {
        return $false
    }

    $hasOwnershipArguments = $null -ne $Record -or
        $null -ne $Manifest -or
        -not [string]::IsNullOrWhiteSpace($Agent) -or
        -not [string]::IsNullOrWhiteSpace($SkillName)
    if (-not $hasOwnershipArguments) {
        return $true
    }

    if ([string]::IsNullOrWhiteSpace($ExpectedTarget)) {
        $ExpectedTarget = $actualTarget
    }

    if ($null -eq $Record -and
        $null -ne $Manifest -and
        -not [string]::IsNullOrWhiteSpace($Agent) -and
        -not [string]::IsNullOrWhiteSpace($SkillName)) {
        $Record = Get-AgentSkillsManagedLinkRecord `
            -Manifest $Manifest `
            -Agent $Agent `
            -SkillName $SkillName
    }

    if (-not (Test-AgentSkillsManagedLinkRecord `
            -Record $Record `
            -Agent $Agent `
            -SkillName $SkillName `
            -LinkPath $LinkPath `
            -TargetPath $ExpectedTarget)) {
        return $false
    }

    if ($null -ne $Manifest) {
        if ([string]::IsNullOrWhiteSpace($Agent) -or [string]::IsNullOrWhiteSpace($SkillName)) {
            return $false
        }

        $manifestRecord = Get-AgentSkillsManagedLinkRecord `
            -Manifest $Manifest `
            -Agent $Agent `
            -SkillName $SkillName
        if (-not (Test-AgentSkillsManagedLinkRecord `
                -Record $manifestRecord `
                -Agent $Agent `
                -SkillName $SkillName `
                -LinkPath $LinkPath `
                -TargetPath $ExpectedTarget)) {
            return $false
        }
    }

    return $true
}

function Ensure-AgentSkillRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Alias('AgentSkillRoot')]
        [string]$Path,

        [switch]$DryRun
    )

    $fullPath = ConvertTo-AgentSkillsFullPath -Path $Path
    $item = Get-AgentSkillsPathItem -Path $fullPath
    if ($null -eq $item) {
        if (-not $DryRun) {
            New-Item -ItemType Directory -Path $fullPath -Force -ErrorAction Stop | Out-Null
        }

        return $fullPath
    }

    if (-not $item.PSIsContainer) {
        throw "Agent skill root is occupied by a non-directory entry: $fullPath"
    }

    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Agent skill root must not be a reparse point: $fullPath"
    }

    return $fullPath
}

function New-PackageSkillJunction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest,

        [Parameter(Mandatory = $true)]
        [string]$Agent,

        [Parameter(Mandatory = $true)]
        [string]$SkillName,

        [Parameter(Mandatory = $true)]
        [string]$AgentSkillRoot,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath,

        [string]$PackageRoot = (Get-AgentSkillsPackageRoot),

        [switch]$DryRun
    )

    $packagePath = ConvertTo-AgentSkillsFullPath -Path $PackageRoot
    $enabledRoot = Join-Path $packagePath 'skills'
    $target = Assert-PathWithinRoot -Path $TargetPath -Root $enabledRoot
    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        throw "Package skill target does not exist: $target"
    }

    $root = Ensure-AgentSkillRoot -Path $AgentSkillRoot -DryRun:$DryRun
    $normalizedSkillName = Normalize-SkillName -Name $SkillName
    $link = Assert-PathWithinRoot -Path (Join-Path $root $normalizedSkillName) -Root $root
    $item = Get-AgentSkillsPathItem -Path $link

    if ($null -ne $item) {
        if (Test-PackageManagedLink `
                -Manifest $Manifest `
                -Agent $Agent `
                -SkillName $normalizedSkillName `
                -LinkPath $link `
                -TargetPath $target `
                -PackageRoot $packagePath) {
            return [pscustomobject]@{
                action     = 'unchanged'
                agent      = $Agent.Trim().ToLowerInvariant()
                skill      = $normalizedSkillName
                linkPath   = $link
                targetPath = $target
            }
        }

        throw "Cannot create package Junction because the path is occupied or not package-managed: $link"
    }

    if (-not $DryRun) {
        New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop | Out-Null
        Set-AgentSkillsManagedLinkRecord `
            -Manifest $Manifest `
            -Agent $Agent `
            -SkillName $normalizedSkillName `
            -LinkPath $link `
            -TargetPath $target
    }

    return [pscustomobject]@{
        action     = $(if ($DryRun) { 'planned-create' } else { 'created' })
        agent      = $Agent.Trim().ToLowerInvariant()
        skill      = $normalizedSkillName
        linkPath   = $link
        targetPath = $target
    }
}

function Remove-PackageSkillJunction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest,

        [Parameter(Mandatory = $true)]
        [string]$Agent,

        [Parameter(Mandatory = $true)]
        [string]$SkillName,

        [Parameter(Mandatory = $true)]
        [string]$AgentSkillRoot,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath,

        [string]$PackageRoot = (Get-AgentSkillsPackageRoot),

        [switch]$DryRun
    )

    $packagePath = ConvertTo-AgentSkillsFullPath -Path $PackageRoot
    $target = Assert-PathWithinRoot -Path $TargetPath -Root $packagePath
    $root = ConvertTo-AgentSkillsFullPath -Path $AgentSkillRoot
    $normalizedSkillName = Normalize-SkillName -Name $SkillName
    $link = Assert-PathWithinRoot -Path (Join-Path $root $normalizedSkillName) -Root $root
    $manifestRecord = Get-AgentSkillsManagedLinkRecord `
        -Manifest $Manifest `
        -Agent $Agent `
        -SkillName $normalizedSkillName

    if (-not (Test-AgentSkillsManagedLinkRecord `
            -Record $manifestRecord `
            -Agent $Agent `
            -SkillName $normalizedSkillName `
            -LinkPath $link `
            -TargetPath $target `
        )) {
        throw "Refusing to remove Junction because the manifest does not own it: $link"
    }

    $item = Get-AgentSkillsPathItem -Path $link
    if ($null -eq $item) {
        if (-not $DryRun) {
            Remove-AgentSkillsManagedLinkRecord `
                -Manifest $Manifest `
                -Agent $Agent `
                -SkillName $normalizedSkillName
        }

        return [pscustomobject]@{
            action     = $(if ($DryRun) { 'planned-forget-missing' } else { 'forgot-missing' })
            agent      = $Agent.Trim().ToLowerInvariant()
            skill      = $normalizedSkillName
            linkPath   = $link
            targetPath = $target
        }
    }

    if (-not (Test-PackageManagedLink `
            -LinkPath $link `
            -ExpectedTarget $target `
            -Manifest $Manifest `
            -Agent $Agent `
            -SkillName $normalizedSkillName `
            -PackageRoot $packagePath)) {
        throw "Refusing to remove Junction because its current target is not package-managed: $link"
    }

    if (-not $DryRun) {
        [System.IO.Directory]::Delete($link)
        Remove-AgentSkillsManagedLinkRecord `
            -Manifest $Manifest `
            -Agent $Agent `
            -SkillName $normalizedSkillName
    }

    return [pscustomobject]@{
        action     = $(if ($DryRun) { 'planned-remove' } else { 'removed' })
        agent      = $Agent.Trim().ToLowerInvariant()
        skill      = $normalizedSkillName
        linkPath   = $link
        targetPath = $target
    }
}
