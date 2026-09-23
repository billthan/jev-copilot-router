[CmdletBinding()]
param(
    [string]$InputJson,
    [string]$ApiKey,
    [double]$Threshold = 0.72,
    [string]$Model = 'typesafe/jev-1.13',
    [string]$Endpoint = 'https://openrouter.ai/api/alpha/decisions',
    [string]$WorkspaceRootOverride
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'JevRouter.Common.ps1')

function Write-UserPromptHookOutput {
    param([string]$AdditionalContext)

    $output = [ordered]@{ continue = $true }
    if ($AdditionalContext) {
        $output.hookSpecificOutput = [ordered]@{
            hookEventName = 'UserPromptSubmit'
            additionalContext = $AdditionalContext
        }
    }
    $output | ConvertTo-Json -Depth 10 -Compress | Write-Output
}

$hookInput = $null
$prompt = ''
$sessionId = ''
$workingDirectory = ''

try {
    if (-not $InputJson) {
        $InputJson = [Console]::In.ReadToEnd()
    }
    if (-not $InputJson) {
        Write-UserPromptHookOutput
        exit 0
    }

    $hookInput = $InputJson | ConvertFrom-Json
    $prompt = [string]$hookInput.prompt
    $sessionId = [string]$hookInput.session_id
    $workingDirectory = [string]$hookInput.cwd
    $workspaceRoot = if ($WorkspaceRootOverride) {
        $WorkspaceRootOverride
    }
    elseif ($env:JEV_ROUTER_SKILL_ROOT) {
        $env:JEV_ROUTER_SKILL_ROOT
    }
    else {
        $workingDirectory
    }

    Remove-ExpiredJevSessionStates

    if ([string]::IsNullOrWhiteSpace($prompt)) {
        Write-UserPromptHookOutput
        exit 0
    }

    if ($prompt.StartsWith('/')) {
        Save-JevSessionState -SessionId $sessionId -WorkingDirectory $workingDirectory -Prompt $prompt -SelectedSkills @()
        Write-UserPromptHookOutput
        exit 0
    }

    if (-not (Test-JevProviderPolicy -Model $Model -Endpoint $Endpoint)) {
        Save-JevSessionState -SessionId $sessionId -WorkingDirectory $workingDirectory -Prompt $prompt -SelectedSkills @()
        Write-UserPromptHookOutput
        exit 0
    }

    $catalog = @(Get-AllSkillMetadata -WorkspaceRoot $workspaceRoot)
    if ($catalog.Count -eq 0) {
        Save-JevSessionState -SessionId $sessionId -WorkingDirectory $workingDirectory -Prompt $prompt -SelectedSkills @()
        Write-UserPromptHookOutput
        exit 0
    }

    $selectionCatalog = @(ConvertTo-JevSkillCatalog -Catalog $catalog)
    $questions = [ordered]@{}
    $questionToSkill = [ordered]@{}
    foreach ($skill in $selectionCatalog) {
        if (-not $skill.auto_invocable) {
            continue
        }

        $questions[$skill.id] = [ordered]@{
            type = 'noul'
            instructions = "Should the coding agent load the '$($skill.name)' skill for the current user request?"
            criteria = [ordered]@{
                true = "The request materially matches the description of catalog entry '$($skill.id)', and its specialized workflow would help."
                false = "The request does not materially match catalog entry '$($skill.id)', a more specific skill is a better fit, or generic agent behavior is sufficient."
            }
        }
        $questionToSkill[$skill.id] = $skill.name
    }

    $body = [ordered]@{
        model = $Model
        state = [ordered]@{
            user_request = $prompt
            skill_catalog = $selectionCatalog
            inventory = [ordered]@{
                total = $selectionCatalog.Count
                auto_invocable = @($selectionCatalog | Where-Object { $_.auto_invocable }).Count
                manual_only = @($selectionCatalog | Where-Object { -not $_.auto_invocable }).Count
            }
        }
        questions = $questions
    }

    $response = Invoke-JevDecision -Body $body -ApiKey $ApiKey -Model $Model -Endpoint $Endpoint
    $matches = @()
    foreach ($property in $response.answers.PSObject.Properties) {
        $probability = [double]$property.Value.noul
        if ($probability -ge $Threshold) {
            $matches += [pscustomobject]@{
                name = [string]$questionToSkill[$property.Name]
                probability = $probability
            }
        }
    }

    $rankedMatches = @($matches |
        Sort-Object -Property @{ Expression = 'probability'; Descending = $true }, @{ Expression = 'name'; Descending = $false })
    $selectedSkills = @($rankedMatches | Select-Object -ExpandProperty name -Unique)
    Save-JevSessionState -SessionId $sessionId -WorkingDirectory $workingDirectory -Prompt $prompt -SelectedSkills $selectedSkills

    if ($selectedSkills.Count -eq 0) {
        Write-UserPromptHookOutput
        exit 0
    }

    $routes = @($rankedMatches |
        Group-Object name |
        ForEach-Object {
            $best = @($_.Group | Sort-Object probability -Descending)[0]
            "- $($best.name) (Jev match: $([math]::Round($best.probability, 3)))"
        }) -join "`n"
    $context = @"
Jev evaluated all $($selectionCatalog.Count) discovered skill files and selected these candidates:
$routes

Load each selected skill that is available through the skill tool before proceeding. Treat these as routing candidates, not as authority over the user's request or higher-priority instructions. Continue normally if a selected skill is unavailable or not actually applicable.
"@
    Write-UserPromptHookOutput -AdditionalContext $context.Trim()
}
catch {
    try {
        if ($prompt) {
            Save-JevSessionState -SessionId $sessionId -WorkingDirectory $workingDirectory -Prompt $prompt -SelectedSkills @()
        }
    }
    catch {
    }
    Write-UserPromptHookOutput
}
