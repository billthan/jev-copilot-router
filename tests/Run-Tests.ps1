[CmdletBinding()]
param(
    [string]$WorkspaceRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [int]$ExpectedSkillCount = 0
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$commonPath = Join-Path $repositoryRoot 'scripts\JevRouter.Common.ps1'
$skillRouterPath = Join-Path $repositoryRoot 'scripts\Invoke-JevSkillRouter.ps1'
$toolEvaluatorPath = Join-Path $repositoryRoot 'scripts\Invoke-JevToolEvaluator.ps1'
$installerPath = Join-Path $repositoryRoot 'scripts\Install-JevRouter.ps1'
$benchmarkSelfTestPath = Join-Path $repositoryRoot 'benchmark\self-test.ps1'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$assertionCount = 0

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
    $script:assertionCount++
}

$scriptFiles = @(Get-ChildItem -LiteralPath $repositoryRoot -Filter '*.ps1' -File -Recurse)
foreach ($scriptFile in $scriptFiles) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    Assert-True ($parseErrors.Count -eq 0) "Parser errors in $($scriptFile.FullName): $($parseErrors.Message -join '; ')"
}

. $commonPath
Assert-True (Test-JevProviderPolicy -Model 'typesafe/jev-1.13' -Endpoint 'https://openrouter.ai/api/alpha/decisions') 'Valid Jev provider route was rejected.'
Assert-True (-not (Test-JevProviderPolicy -Model 'openai/gpt-5.6-sol' -Endpoint 'https://openrouter.ai/api/alpha/decisions')) 'Non-Jev model was accepted.'
Assert-True (-not (Test-JevProviderPolicy -Model 'typesafe/jev-1.13' -Endpoint 'https://example.invalid/decisions')) 'Alternate endpoint was accepted.'

$catalog = @(Get-AllSkillMetadata -WorkspaceRoot $WorkspaceRoot)
Assert-True ($catalog.Count -gt 0) 'No skills were discovered.'
if ($ExpectedSkillCount -gt 0) {
    Assert-True ($catalog.Count -eq $ExpectedSkillCount) "Expected $ExpectedSkillCount skills, found $($catalog.Count)."
}
Assert-True (@($catalog | Where-Object { -not $_.name -or -not $_.description -or -not $_.source }).Count -eq 0) 'Skill metadata is incomplete.'
Assert-True (@($catalog | Where-Object { $_.source -match '(?i)[\\/]\.tmp' }).Count -eq 0) 'Temporary skill copies were included.'
$selectionCatalog = @(ConvertTo-JevSkillCatalog -Catalog $catalog)
Assert-True ($selectionCatalog.Count -eq $catalog.Count) 'Selection catalog dropped skills.'
Assert-True (@($selectionCatalog.id | Sort-Object -Unique).Count -eq $catalog.Count) 'Selection catalog IDs are not unique.'

$redacted = ConvertTo-RedactedValue -Value ([pscustomobject]@{
    apiKey = 'sk-test-secret-value'
    nested = [pscustomobject]@{
        Authorization = 'Bearer hidden-value'
        path = 'C:\safe\file.txt'
    }
}) -PropertyName 'tool_input'
$redactedJson = $redacted | ConvertTo-Json -Depth 8 -Compress
Assert-True (-not $redactedJson.Contains('sk-test-secret-value')) 'API key was not redacted.'
Assert-True (-not $redactedJson.Contains('hidden-value')) 'Authorization value was not redacted.'
Assert-True ($redactedJson.Contains('C:\\safe\\file.txt')) 'Normal tool input was not preserved.'

$tempRoot = Join-Path $env:TEMP ("jev-copilot-router-tests-{0}" -f [guid]::NewGuid().ToString('N'))
$previousStateRoot = $env:JEV_ROUTER_STATE_ROOT
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $env:JEV_ROUTER_STATE_ROOT = Join-Path $tempRoot 'state'
    Save-JevSessionState -SessionId 'test-session' -WorkingDirectory $WorkspaceRoot -Prompt 'Test prompt' -SelectedSkills @('one', 'two')
    $state = Get-JevSessionState -SessionId 'test-session' -WorkingDirectory $WorkspaceRoot
    Assert-True ($state.prompt -eq 'Test prompt') 'Session prompt was not preserved.'
    Assert-True (@($state.selected_skills).Count -eq 2) 'Selected skills were not preserved.'

    $hooksDirectory = Join-Path $tempRoot 'hooks'
    $installRoot = Join-Path $tempRoot 'install'
    New-Item -ItemType Directory -Path $hooksDirectory -Force | Out-Null
    $secureValue = ConvertTo-SecureString 'test-openrouter-value' -AsPlainText -Force
    $testCredential = New-Object System.Management.Automation.PSCredential('openrouter', $secureValue)
    $testCredential | Export-Clixml -LiteralPath (Join-Path $hooksDirectory 'openrouter-key.clixml')
    [System.IO.File]::WriteAllText((Join-Path $hooksDirectory 'jev-skills-router.json'), '{}')

    $installOutput = @(& $installerPath -InstallRoot $installRoot -HooksDirectory $hooksDirectory -SkillRoot $WorkspaceRoot -SkipCredentialPrompt)
    $installResult = ($installOutput -join [Environment]::NewLine) | ConvertFrom-Json
    Assert-True ([bool]$installResult.installed) 'Installer did not report success.'
    Assert-True (Test-Path -LiteralPath (Join-Path $hooksDirectory 'jev-router.json') -PathType Leaf) 'Hook configuration was not created.'
    Assert-True (Test-Path -LiteralPath (Join-Path $hooksDirectory 'jev-skills-router.json.disabled') -PathType Leaf) 'Legacy hook was not disabled.'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $installRoot 'scripts') -Filter '*.ps1' -File).Count -eq 3) 'Runtime scripts were not installed.'

    $invalidSkillInput = [ordered]@{
        hook_event_name = 'UserPromptSubmit'
        prompt = 'Create a custom agent.'
        cwd = $WorkspaceRoot
        session_id = 'invalid-provider-test'
    } | ConvertTo-Json -Compress
    $invalidSkillOutput = @($invalidSkillInput | & $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $skillRouterPath -ApiKey 'test-key' -Model 'openai/gpt-5.6-sol')[-1] | ConvertFrom-Json
    Assert-True ([bool]$invalidSkillOutput.continue) 'Skill router did not fail open for a rejected provider.'
    Assert-True ($null -eq $invalidSkillOutput.hookSpecificOutput) 'Rejected provider injected skill context.'

    $invalidToolInput = [ordered]@{
        hook_event_name = 'PreToolUse'
        tool_name = 'read_file'
        tool_input = [ordered]@{ filePath = 'README.md' }
        cwd = $WorkspaceRoot
        session_id = 'invalid-provider-test'
    } | ConvertTo-Json -Compress
    $invalidToolOutput = @($invalidToolInput | & $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $toolEvaluatorPath -ApiKey 'test-key' -Model 'openai/gpt-5.6-sol')[-1] | ConvertFrom-Json
    Assert-True ($invalidToolOutput.hookSpecificOutput.permissionDecision -eq 'ask') 'Tool evaluator did not fail closed to confirmation.'

    $benchmarkOutput = @(& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $benchmarkSelfTestPath)
    Assert-True ($LASTEXITCODE -eq 0) 'Benchmark self-test failed.'
    Assert-True (($benchmarkOutput -join [Environment]::NewLine) -match 'Benchmark self-test passed') 'Benchmark self-test success marker was missing.'
}
finally {
    $env:JEV_ROUTER_STATE_ROOT = $previousStateRoot
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

Write-Output "All tests passed: $assertionCount assertions across $($scriptFiles.Count) PowerShell files and $($catalog.Count) discovered skills."
