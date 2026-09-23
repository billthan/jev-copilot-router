[CmdletBinding()]
param(
    [string]$RegistryPath = (Join-Path $env:APPDATA 'Code\User\globalStorage\github.copilot-chat\toolEmbeddings.json'),
    [string]$SupplementPath,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $SupplementPath) {
    $SupplementPath = Join-Path $scriptRoot 'tool-catalog-supplement.json'
}
if (-not $OutputPath) {
    $OutputPath = Join-Path $scriptRoot 'tool-catalog.json'
}

if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) {
    throw "Copilot tool registry not found: $RegistryPath"
}
if (-not (Test-Path -LiteralPath $SupplementPath -PathType Leaf)) {
    throw "Supplemental tool catalog not found: $SupplementPath"
}

$parsedRegistry = [System.IO.File]::ReadAllText($RegistryPath) | ConvertFrom-Json
$registryItems = @()
foreach ($item in $parsedRegistry) {
    $registryItems += $item
}
$registryNames = @($registryItems | ForEach-Object { [string]$_.key } | Where-Object { $_ } | Sort-Object -Unique)

$supplement = [System.IO.File]::ReadAllText($SupplementPath) | ConvertFrom-Json
$supplementNames = @($supplement.tools | ForEach-Object { [string]$_ } | Where-Object { $_ } | Sort-Object -Unique)

$allNames = @($registryNames + $supplementNames | Sort-Object -Unique)
$tools = @()
for ($index = 0; $index -lt $allNames.Count; $index++) {
    $name = $allNames[$index]
    $sources = @()
    if ($name -in $registryNames) {
        $sources += 'vscode-tool-embeddings'
    }
    if ($name -in $supplementNames) {
        $sources += [string]$supplement.source
    }

    $hint = [regex]::Replace($name, '[_-]+', ' ')
    $hint = [regex]::Replace($hint, '(?<=[a-z])(?=[A-Z])', ' ')
    $tools += [ordered]@{
        id = 'tool_{0:D3}' -f $index
        name = $name
        hint = $hint
        sources = $sources
    }
}

$sha256 = [System.Security.Cryptography.SHA256]::Create()
try {
    $registryHash = ([System.BitConverter]::ToString($sha256.ComputeHash([System.IO.File]::ReadAllBytes($RegistryPath)))).Replace('-', '').ToLowerInvariant()
}
finally {
    $sha256.Dispose()
}

$catalog = [ordered]@{
    schema_version = 1
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    source = [ordered]@{
        registry = 'VS Code Copilot toolEmbeddings.json'
        registry_sha256 = $registryHash
        registry_count = $registryNames.Count
        supplement = [System.IO.Path]::GetFileName($SupplementPath)
        supplement_count = $supplementNames.Count
    }
    total_count = $tools.Count
    tools = $tools
}

$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutputPath, (($catalog | ConvertTo-Json -Depth 10) + [Environment]::NewLine), $utf8NoBom)

[pscustomobject]@{
    output_path = $OutputPath
    registry_count = $registryNames.Count
    supplement_count = $supplementNames.Count
    total_count = $tools.Count
    registry_sha256 = $registryHash
}
