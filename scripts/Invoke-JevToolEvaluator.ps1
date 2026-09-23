[CmdletBinding()]
param(
    [string]$InputJson,
    [string]$ApiKey,
    [string]$Model = 'typesafe/jev-1.13',
    [string]$Endpoint = 'https://openrouter.ai/api/alpha/decisions',
    [double]$AllowThreshold = 0.78,
    [double]$DenyThreshold = 0.90
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'JevRouter.Common.ps1')

function Write-PreToolHookOutput {
    param(
        [ValidateSet('allow', 'ask', 'deny')]
        [string]$Decision,
        [string]$Reason,
        [string]$AdditionalContext
    )

    $hookOutput = [ordered]@{
        hookEventName = 'PreToolUse'
        permissionDecision = $Decision
        permissionDecisionReason = $Reason
    }
    if ($AdditionalContext) {
        $hookOutput.additionalContext = $AdditionalContext
    }

    [ordered]@{
        continue = $true
        hookSpecificOutput = $hookOutput
    } | ConvertTo-Json -Depth 10 -Compress | Write-Output
}

try {
    if (-not $InputJson) {
        $InputJson = [Console]::In.ReadToEnd()
    }
    if (-not $InputJson) {
        Write-PreToolHookOutput -Decision 'ask' -Reason 'Jev received no tool-call event.'
        exit 0
    }

    $hookInput = $InputJson | ConvertFrom-Json
    $toolName = [string]$hookInput.tool_name
    $sessionId = [string]$hookInput.session_id
    $workingDirectory = [string]$hookInput.cwd
    if ([string]::IsNullOrWhiteSpace($toolName)) {
        Write-PreToolHookOutput -Decision 'ask' -Reason 'Jev could not identify the requested tool.'
        exit 0
    }

    if (-not (Test-JevProviderPolicy -Model $Model -Endpoint $Endpoint)) {
        Write-PreToolHookOutput -Decision 'ask' -Reason 'Provider policy rejected the Jev evaluation route.'
        exit 0
    }

    $sessionState = Get-JevSessionState -SessionId $sessionId -WorkingDirectory $workingDirectory
    $userRequest = if ($sessionState -and $sessionState.prompt) {
        [string]$sessionState.prompt
    }
    else {
        'No current user request was available.'
    }
    $selectedSkills = if ($sessionState) { @($sessionState.selected_skills) } else { @() }
    $redactedToolInput = ConvertTo-RedactedValue -Value $hookInput.tool_input -PropertyName 'tool_input'

    $body = [ordered]@{
        model = $Model
        state = [ordered]@{
            user_request = $userRequest
            selected_skills = $selectedSkills
            tool_call = [ordered]@{
                name = $toolName
                input = $redactedToolInput
            }
        }
        questions = [ordered]@{
            permission = [ordered]@{
                type = 'choice'
                instructions = 'Choose the permission decision for this coding-agent tool call.'
                criteria = [ordered]@{
                    allow = 'The call directly serves the user request, is scoped to what is necessary, and is read-only, reversible, or a routine safe edit or validation.'
                    ask = 'The call may be valid but has meaningful side effects, external publication or deployment, package installation, broad writes, sensitive access, cost, ambiguity, or insufficient context, so the user should confirm.'
                    deny = 'The call is clearly unrelated, attempts credential disclosure or safeguard bypass, performs unjustified destructive or irreversible action, escalates privilege, or conflicts with the user request.'
                }
            }
        }
    }

    $response = Invoke-JevDecision -Body $body -ApiKey $ApiKey -Model $Model -Endpoint $Endpoint -TimeoutSeconds 10
    $answer = $response.answers.permission
    $choice = [string]$answer.choice
    $confidence = [double]$answer.confidence
    $choiceProbability = 0.0
    if ($answer.probabilities -and $answer.probabilities.PSObject.Properties[$choice]) {
        $choiceProbability = [double]$answer.probabilities.PSObject.Properties[$choice].Value
    }

    $decision = 'ask'
    if ($choice -eq 'allow' -and $choiceProbability -ge $AllowThreshold) {
        $decision = 'allow'
    }
    elseif ($choice -eq 'deny' -and $choiceProbability -ge $DenyThreshold) {
        $decision = 'deny'
    }

    $reason = 'Jev chose {0} with probability {1:N3} and confidence {2:N3}.' -f $choice, $choiceProbability, $confidence
    $context = if ($decision -eq 'allow') {
        $null
    }
    else {
        "Jev tool evaluation resolved to '$decision'. Do not bypass this decision with a different tool or command."
    }
    Write-PreToolHookOutput -Decision $decision -Reason $reason -AdditionalContext $context
}
catch {
    Write-PreToolHookOutput -Decision 'ask' -Reason 'Jev evaluation was unavailable, so explicit confirmation is required.' -AdditionalContext 'The tool evaluator failed closed to user confirmation.'
}
