[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $HOME '.copilot\jev-router'),
    [string]$HooksDirectory = (Join-Path $HOME '.copilot\hooks'),
    [string]$SkillRoot = (Get-Location).Path,
    [switch]$SkipCredentialPrompt
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$sourceScripts = Join-Path $repositoryRoot 'scripts'
$installScripts = Join-Path $InstallRoot 'scripts'
$hookConfigPath = Join-Path $HooksDirectory 'jev-router.json'
$credentialPath = Join-Path $InstallRoot 'openrouter-key.clixml'
$legacyCredentialPath = Join-Path $HooksDirectory 'openrouter-key.clixml'
$legacyHookPath = Join-Path $HooksDirectory 'jev-skills-router.json'

New-Item -ItemType Directory -Path $installScripts -Force | Out-Null
New-Item -ItemType Directory -Path $HooksDirectory -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $sourceScripts 'JevRouter.Common.ps1') -Destination $installScripts -Force
Copy-Item -LiteralPath (Join-Path $sourceScripts 'Invoke-JevSkillRouter.ps1') -Destination $installScripts -Force
Copy-Item -LiteralPath (Join-Path $sourceScripts 'Invoke-JevToolEvaluator.ps1') -Destination $installScripts -Force

if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) {
    if (Test-Path -LiteralPath $legacyCredentialPath -PathType Leaf) {
        Copy-Item -LiteralPath $legacyCredentialPath -Destination $credentialPath -Force
    }
    elseif ($SkipCredentialPrompt) {
        throw 'No existing OpenRouter credential was found.'
    }
    else {
        $secureKey = Read-Host 'Paste OpenRouter API key for Jev (input is hidden)' -AsSecureString
        $credential = New-Object System.Management.Automation.PSCredential('openrouter', $secureKey)
        $credential | Export-Clixml -LiteralPath $credentialPath
    }
}

$skillRouterPath = Join-Path $installScripts 'Invoke-JevSkillRouter.ps1'
$toolEvaluatorPath = Join-Path $installScripts 'Invoke-JevToolEvaluator.ps1'
$sharedEnvironment = [ordered]@{
    JEV_ROUTER_CREDENTIAL_PATH = $credentialPath
    JEV_ROUTER_SKILL_ROOT = $SkillRoot
}
$hookConfig = [ordered]@{
    hooks = [ordered]@{
        UserPromptSubmit = @(
            [ordered]@{
                type = 'command'
                command = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$skillRouterPath`""
                timeout = 30
                env = $sharedEnvironment
            }
        )
        PreToolUse = @(
            [ordered]@{
                type = 'command'
                command = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$toolEvaluatorPath`""
                timeout = 15
                env = $sharedEnvironment
            }
        )
    }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($hookConfigPath, (($hookConfig | ConvertTo-Json -Depth 12) + [Environment]::NewLine), $utf8NoBom)

if (Test-Path -LiteralPath $legacyHookPath -PathType Leaf) {
    Move-Item -LiteralPath $legacyHookPath -Destination "$legacyHookPath.disabled" -Force
}

$result = [ordered]@{
    installed = $true
    install_root = $InstallRoot
    hook_config = $hookConfigPath
    skill_root = $SkillRoot
    credential_encrypted = $true
    legacy_hook_disabled = -not (Test-Path -LiteralPath $legacyHookPath -PathType Leaf)
}
$result | ConvertTo-Json -Depth 6
