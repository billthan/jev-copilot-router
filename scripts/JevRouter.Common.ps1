$script:JevRouterRoot = Split-Path -Parent $PSScriptRoot
$script:JevEndpoint = 'https://openrouter.ai/api/alpha/decisions'
$script:JevModel = 'typesafe/jev-1.13'

function Test-JevProviderPolicy {
    param(
        [string]$Model,
        [string]$Endpoint
    )

    $isJevModel = $Model -match '\A(?:typesafe/jev-[A-Za-z0-9._-]+|~typesafe/jev-latest)\z'
    return $Endpoint -eq $script:JevEndpoint -and $isJevModel
}

function Get-OpenRouterApiKey {
    param([string]$ExplicitApiKey)

    if ($ExplicitApiKey) {
        return $ExplicitApiKey
    }

    if ($env:OPENROUTER_API_KEY) {
        return $env:OPENROUTER_API_KEY
    }

    $credentialPaths = @()
    if ($env:JEV_ROUTER_CREDENTIAL_PATH) {
        $credentialPaths += $env:JEV_ROUTER_CREDENTIAL_PATH
    }
    $credentialPaths += @(
        (Join-Path $script:JevRouterRoot 'openrouter-key.clixml'),
        (Join-Path $HOME '.copilot\jev-router\openrouter-key.clixml')
    )
    $credentialPath = @($credentialPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)
    if ($credentialPath.Count -eq 0) {
        return $null
    }

    $credential = Import-Clixml -LiteralPath $credentialPath[0]
    if (-not ($credential -is [System.Management.Automation.PSCredential])) {
        return $null
    }

    return $credential.GetNetworkCredential().Password
}

function Invoke-JevDecision {
    param(
        [object]$Body,
        [string]$ApiKey,
        [string]$Model = $script:JevModel,
        [string]$Endpoint = $script:JevEndpoint,
        [int]$TimeoutSeconds = 12
    )

    if (-not (Test-JevProviderPolicy -Model $Model -Endpoint $Endpoint)) {
        throw 'Provider policy rejected a non-Jev model or non-OpenRouter Decisions endpoint.'
    }

    $resolvedApiKey = Get-OpenRouterApiKey -ExplicitApiKey $ApiKey
    if (-not $resolvedApiKey) {
        throw 'OpenRouter credential is unavailable.'
    }

    $Body.model = $Model
    return Invoke-RestMethod -Method Post -Uri $Endpoint -Headers @{
        Authorization = "Bearer $resolvedApiKey"
        'Content-Type' = 'application/json'
        'X-OpenRouter-Title' = 'Jev Copilot Router'
    } -Body ($Body | ConvertTo-Json -Depth 30 -Compress) -TimeoutSec $TimeoutSeconds -DisableKeepAlive
}

function ConvertTo-RedactedValue {
    param(
        [object]$Value,
        [string]$PropertyName,
        [int]$Depth = 0
    )

    if ($Depth -ge 8) {
        return '[MAX_DEPTH]'
    }

    if ($PropertyName -match '(?i)(authorization|password|passwd|secret|token|api[-_]?key|credential|private[-_]?key|cookie|signature|sas)') {
        return '[REDACTED]'
    }

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        $text = [string]$Value
        $text = [regex]::Replace($text, '(?i)\b(?:sk|ghp|gho|github_pat)_[A-Za-z0-9_.-]{8,}', '[REDACTED]')
        $text = [regex]::Replace($text, '\beyJ[A-Za-z0-9_.-]{20,}', '[REDACTED]')
        $text = [regex]::Replace($text, '(?i)([?&](?:sig|se|sp|sv|spr|srt|ss)=)[^&\s]+', '$1[REDACTED]')
        if ($text.Length -gt 4000) {
            $text = $text.Substring(0, 4000) + '[TRUNCATED]'
        }
        return $text
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $result[[string]$key] = ConvertTo-RedactedValue -Value $Value[$key] -PropertyName ([string]$key) -Depth ($Depth + 1)
        }
        return $result
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = @()
        foreach ($item in $Value) {
            $items += ConvertTo-RedactedValue -Value $item -PropertyName $PropertyName -Depth ($Depth + 1)
            if ($items.Count -ge 100) {
                $items += '[TRUNCATED]'
                break
            }
        }
        return $items
    }

    if ($Value -is [psobject] -and $Value.PSObject.Properties.Count -gt 0) {
        $result = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-RedactedValue -Value $property.Value -PropertyName $property.Name -Depth ($Depth + 1)
        }
        return $result
    }

    return $Value
}

function Get-StableIdentifier {
    param([string]$Seed)

    if ([string]::IsNullOrWhiteSpace($Seed)) {
        $Seed = 'default'
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Seed)
        $hash = $sha256.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash)).Replace('-', '').Substring(0, 32).ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-SessionStatePath {
    param(
        [string]$SessionId,
        [string]$WorkingDirectory
    )

    $stateRoot = if ($env:JEV_ROUTER_STATE_ROOT) {
        $env:JEV_ROUTER_STATE_ROOT
    }
    else {
        Join-Path $env:LOCALAPPDATA 'JevCopilotRouter\sessions'
    }

    if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    }

    $seed = if ($SessionId) { $SessionId } else { $WorkingDirectory }
    $identifier = Get-StableIdentifier -Seed $seed
    return Join-Path $stateRoot "$identifier.json"
}

function Save-JevSessionState {
    param(
        [string]$SessionId,
        [string]$WorkingDirectory,
        [string]$Prompt,
        [string[]]$SelectedSkills
    )

    $path = Get-SessionStatePath -SessionId $SessionId -WorkingDirectory $WorkingDirectory
    $state = [ordered]@{
        updated_at = (Get-Date).ToUniversalTime().ToString('o')
        prompt = $Prompt
        selected_skills = @($SelectedSkills | Sort-Object -Unique)
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, (($state | ConvertTo-Json -Depth 8) + [Environment]::NewLine), $utf8NoBom)
}

function Get-JevSessionState {
    param(
        [string]$SessionId,
        [string]$WorkingDirectory
    )

    $path = Get-SessionStatePath -SessionId $SessionId -WorkingDirectory $WorkingDirectory
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    try {
        return [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Remove-ExpiredJevSessionStates {
    param([int]$MaximumAgeDays = 7)

    $stateRoot = if ($env:JEV_ROUTER_STATE_ROOT) {
        $env:JEV_ROUTER_STATE_ROOT
    }
    else {
        Join-Path $env:LOCALAPPDATA 'JevCopilotRouter\sessions'
    }

    if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
        return
    }

    $cutoff = (Get-Date).ToUniversalTime().AddDays(-$MaximumAgeDays)
    Get-ChildItem -LiteralPath $stateRoot -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Get-CopilotBundledSkillRoot {
    $candidateRoots = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\*\resources\app\extensions\copilot'),
        (Join-Path $HOME '.vscode\extensions\github.copilot-chat-*')
    )

    $candidates = @()
    foreach ($candidateRoot in $candidateRoots) {
        foreach ($copilotRoot in Get-Item -Path $candidateRoot -ErrorAction SilentlyContinue) {
            $skillsRoot = Join-Path $copilotRoot.FullName 'assets\prompts\skills'
            $packagePath = Join-Path $copilotRoot.FullName 'package.json'
            if (-not (Test-Path -LiteralPath $skillsRoot -PathType Container) -or
                -not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
                continue
            }

            try {
                $package = [System.IO.File]::ReadAllText($packagePath) | ConvertFrom-Json
                $version = [version]$package.version
            }
            catch {
                $version = [version]'0.0.0'
            }

            $candidates += [pscustomobject]@{
                path = $skillsRoot
                version = $version
                modified = $copilotRoot.LastWriteTimeUtc
            }
        }
    }

    return @($candidates |
        Sort-Object -Property @{ Expression = 'version'; Descending = $true }, @{ Expression = 'modified'; Descending = $true } |
        Select-Object -First 1 -ExpandProperty path)
}

function Get-SkillFrontmatterValue {
    param(
        [string]$Yaml,
        [string]$Name
    )

    $escapedName = [regex]::Escape($Name)
    $pattern = '(?m)^{0}\s*:\s*["'']?(?<value>[^\r\n"'']+?)["'']?\s*(?:#.*)?$' -f $escapedName
    $match = [regex]::Match($Yaml, $pattern)
    if (-not $match.Success) {
        return $null
    }
    return $match.Groups['value'].Value.Trim()
}

function Get-SkillMetadataFromFile {
    param(
        [System.IO.FileInfo]$SkillFile,
        [string]$WorkspaceRoot,
        [string]$Scope
    )

    $content = [System.IO.File]::ReadAllText($SkillFile.FullName)
    $frontmatter = [regex]::Match($content, '(?s)\A---\s*\r?\n(?<yaml>.*?)\r?\n---(?:\r?\n|\z)')
    $yaml = if ($frontmatter.Success) { $frontmatter.Groups['yaml'].Value } else { '' }
    $name = Get-SkillFrontmatterValue -Yaml $yaml -Name 'name'
    if (-not $name) {
        $name = $SkillFile.Directory.Name
    }

    $description = Get-SkillFrontmatterValue -Yaml $yaml -Name 'description'
    if (-not $description) {
        $body = if ($frontmatter.Success) { $content.Substring($frontmatter.Length) } else { $content }
        $descriptionLine = @($body -split '\r?\n' | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') } | Select-Object -First 1)
        $description = if ($descriptionLine.Count -gt 0) { $descriptionLine[0].Trim() } else { "Instructions from $($SkillFile.Directory.Name)." }
    }

    $disableModelInvocation = Get-SkillFrontmatterValue -Yaml $yaml -Name 'disable-model-invocation'
    $relativeSource = if ($WorkspaceRoot -and $SkillFile.FullName.StartsWith($WorkspaceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $SkillFile.FullName.Substring($WorkspaceRoot.Length).TrimStart('\')
    }
    else {
        "$Scope/$($SkillFile.Directory.Name)/SKILL.md"
    }

    return [pscustomobject]@{
        name = $name
        description = $description
        auto_invocable = $disableModelInvocation -ne 'true'
        scope = $Scope
        source = $SkillFile.FullName
        selection_source = $relativeSource.Replace('\', '/')
    }
}

function Get-AllSkillMetadata {
    param([string]$WorkspaceRoot)

    $excludedPathPattern = '(?i)[\\/](?:\.git|\.tmp[^\\/]*|node_modules|\.venv|venv|dist|build|_site|99_ARCHIVE)[\\/]'
    $candidates = @()
    $roots = @(
        [pscustomobject]@{ path = (Join-Path $HOME '.copilot\skills'); scope = 'user'; recursive = $true },
        [pscustomobject]@{ path = (Join-Path $HOME '.claude\skills'); scope = 'user'; recursive = $true },
        [pscustomobject]@{ path = (Join-Path $HOME '.agents\skills'); scope = 'user'; recursive = $true }
    )

    if ($WorkspaceRoot) {
        $roots += [pscustomobject]@{ path = $WorkspaceRoot; scope = 'workspace'; recursive = $true }
    }

    $bundledRoot = @(Get-CopilotBundledSkillRoot)
    if ($bundledRoot.Count -gt 0) {
        $roots += [pscustomobject]@{ path = $bundledRoot[0]; scope = 'bundled'; recursive = $true }
    }

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root.path -PathType Container)) {
            continue
        }

        $files = if ($root.recursive) {
            Get-ChildItem -LiteralPath $root.path -Filter 'SKILL.md' -File -Recurse -ErrorAction SilentlyContinue
        }
        else {
            Get-ChildItem -LiteralPath $root.path -Filter 'SKILL.md' -File -ErrorAction SilentlyContinue
        }

        foreach ($skillFile in $files) {
            if ($skillFile.FullName -match $excludedPathPattern) {
                continue
            }
            $candidates += [pscustomobject]@{ file = $skillFile; scope = $root.scope }
        }
    }

    $seen = @{}
    $catalog = @()
    foreach ($candidate in $candidates | Sort-Object { $_.file.FullName }) {
        $key = $candidate.file.FullName.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            continue
        }
        $seen[$key] = $true
        $catalog += Get-SkillMetadataFromFile -SkillFile $candidate.file -WorkspaceRoot $WorkspaceRoot -Scope $candidate.scope
    }

    return $catalog
}

function ConvertTo-JevSkillCatalog {
    param([object[]]$Catalog)

    $selectionCatalog = @()
    for ($index = 0; $index -lt $Catalog.Count; $index++) {
        $skill = $Catalog[$index]
        $selectionCatalog += [ordered]@{
            id = 'skill_{0:D3}' -f $index
            name = $skill.name
            description = $skill.description
            auto_invocable = [bool]$skill.auto_invocable
            scope = $skill.scope
            source = $skill.selection_source
        }
    }
    return $selectionCatalog
}
