[CmdletBinding()]
param(
    [string]$CasesPath,
    [string]$OutputDirectory,
    [string]$WorkspacePath = (Get-Location).Path,
    [string]$CatalogPath,
    [string]$FixturePath,
    [string[]]$CaseId,
    [int]$CaseLimit = 0,
    [ValidateRange(1, 20)]
    [int]$Repeats = 3,
    [ValidateRange(0.0, 1.0)]
    [double]$JevThreshold = 0.72,
    [string]$JevModel = 'typesafe/jev-1.13',
    [string]$LlmModel = 'openai/gpt-5.6-sol',
    [ValidateSet('jev', 'llm')]
    [string[]]$Methods = @('jev'),
    [ValidateSet('none', 'low', 'medium', 'high', 'xhigh', 'max')]
    [string]$LlmReasoningEffort = 'none',
    [int]$ApiTimeoutSeconds = 90,
    [string]$ApiKey,
    [switch]$AllowOpenRouterLlmBaseline,
    [switch]$FailOnApiError
)

$ErrorActionPreference = 'Stop'
$script:BenchmarkRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $CasesPath) {
    $CasesPath = Join-Path $script:BenchmarkRoot 'cases.json'
}
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $script:BenchmarkRoot 'results'
}

function Get-PropertyValue {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-OpenRouterApiKey {
    param([string]$ExplicitApiKey)

    if ($ExplicitApiKey) {
        return $ExplicitApiKey
    }

    if ($env:OPENROUTER_API_KEY) {
        return $env:OPENROUTER_API_KEY
    }

    $credentialPaths = @(
        (Join-Path (Split-Path $script:BenchmarkRoot -Parent) 'openrouter-key.clixml'),
        (Join-Path $HOME '.copilot\jev-router\openrouter-key.clixml')
    )
    $credentialPath = @($credentialPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)
    if ($credentialPath.Count -eq 0) {
        return $null
    }

    $credential = Import-Clixml -LiteralPath $credentialPath[0]
    return $credential.GetNetworkCredential().Password
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

    return @($candidates | Sort-Object -Property @{ Expression = 'version'; Descending = $true }, @{ Expression = 'modified'; Descending = $true } | Select-Object -First 1 -ExpandProperty path)
}

function Get-SkillCatalog {
    param(
        [string]$Workspace,
        [int]$Limit = 48
    )

    $roots = @(
        (Join-Path $HOME '.copilot\skills'),
        (Join-Path $HOME '.claude\skills'),
        (Join-Path $HOME '.agents\skills')
    )

    if ($Workspace) {
        $roots += @(
            (Join-Path $Workspace '.github\skills'),
            (Join-Path $Workspace '.claude\skills'),
            (Join-Path $Workspace '.agents\skills')
        )
    }

    $bundledRoot = @(Get-CopilotBundledSkillRoot)
    if ($bundledRoot.Count -gt 0) {
        $roots += $bundledRoot[0]
    }

    $skills = [ordered]@{}
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        foreach ($skillFile in Get-ChildItem -LiteralPath $root -Filter 'SKILL.md' -File -Recurse -ErrorAction SilentlyContinue) {
            if ($skills.Count -ge $Limit) {
                break
            }

            $content = [System.IO.File]::ReadAllText($skillFile.FullName)
            $frontmatter = [regex]::Match($content, '(?s)\A---\s*\r?\n(?<yaml>.*?)\r?\n---(?:\r?\n|\z)')
            if (-not $frontmatter.Success) {
                continue
            }

            $yaml = $frontmatter.Groups['yaml'].Value
            $nameMatch = [regex]::Match($yaml, '(?m)^name:\s*["'']?(?<value>[^\r\n"'']+)["'']?\s*$')
            $descriptionMatch = [regex]::Match($yaml, '(?m)^description:\s*["'']?(?<value>[^\r\n]+?)["'']?\s*$')
            if (-not $nameMatch.Success -or -not $descriptionMatch.Success) {
                continue
            }

            $disableModelInvocation = [regex]::Match($yaml, '(?m)^disable-model-invocation:\s*(?<value>true|false)\s*$')
            if ($disableModelInvocation.Success -and $disableModelInvocation.Groups['value'].Value -eq 'true') {
                continue
            }

            $name = $nameMatch.Groups['value'].Value.Trim()
            if (-not $skills.Contains($name)) {
                $skills[$name] = [pscustomobject]@{
                    name = $name
                    description = $descriptionMatch.Groups['value'].Value.Trim()
                    source = $skillFile.FullName
                }
            }
        }
    }

    return @($skills.Values)
}

function ConvertTo-SkillSet {
    param([object]$Value)

    return @(
        @($Value) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
}

function Join-SkillSet {
    param([object]$Value)

    return ((ConvertTo-SkillSet -Value $Value) -join '|')
}

function Invoke-JsonPost {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [object]$Body,
        [int]$TimeoutSeconds
    )

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-RestMethod -Method Post -Uri $Uri -Headers $Headers -Body ($Body | ConvertTo-Json -Depth 20 -Compress) -TimeoutSec $TimeoutSeconds
        $timer.Stop()
        return [pscustomobject]@{
            response = $response
            duration_ms = [math]::Round($timer.Elapsed.TotalMilliseconds, 2)
            error = $null
        }
    }
    catch {
        $timer.Stop()
        $errorMessage = $_.Exception.Message
        $errorResponse = $_.Exception.Response
        if ($errorResponse) {
            try {
                $reader = New-Object System.IO.StreamReader($errorResponse.GetResponseStream())
                $errorBody = $reader.ReadToEnd()
                $reader.Dispose()
                if (-not [string]::IsNullOrWhiteSpace($errorBody)) {
                    $errorMessage = "$errorMessage Response: $errorBody"
                }
            }
            catch {
            }
        }
        return [pscustomobject]@{
            response = $null
            duration_ms = [math]::Round($timer.Elapsed.TotalMilliseconds, 2)
            error = $errorMessage
        }
    }
}

function Invoke-JevRoute {
    param(
        [string]$Prompt,
        [object[]]$Catalog,
        [string]$ResolvedApiKey,
        [string]$Model,
        [double]$Threshold,
        [int]$TimeoutSeconds
    )

    $questions = [ordered]@{}
    $questionToSkill = [ordered]@{}
    for ($index = 0; $index -lt $Catalog.Count; $index++) {
        $questionName = 'skill_{0:D3}' -f $index
        $skill = $Catalog[$index]
        $questions[$questionName] = [ordered]@{
            type = 'noul'
            instructions = "Should the coding agent load the '$($skill.name)' skill to handle the user's current request?"
            criteria = [ordered]@{
                true = "The request materially matches this skill and its guidance would help: $($skill.description)"
                false = 'The request does not materially match this skill, or generic agent behavior is sufficient.'
            }
        }
        $questionToSkill[$questionName] = $skill.name
    }

    $body = [ordered]@{
        model = $Model
        state = [ordered]@{ user_request = $Prompt }
        questions = $questions
    }

    $call = Invoke-JsonPost -Uri 'https://openrouter.ai/api/alpha/decisions' -Headers @{
        Authorization = "Bearer $ResolvedApiKey"
        'Content-Type' = 'application/json'
        'X-OpenRouter-Title' = 'Jev Skills Router Benchmark'
    } -Body $body -TimeoutSeconds $TimeoutSeconds

    if ($call.error) {
        return [pscustomobject]@{
            selected = @()
            scores = @{}
            duration_ms = $call.duration_ms
            cost = $null
            input_tokens = $null
            output_tokens = $null
            actual_model = $null
            provider = $null
            error = $call.error
        }
    }

    $selected = @()
    $scores = [ordered]@{}
    foreach ($property in $call.response.answers.PSObject.Properties) {
        $probability = [double]$property.Value.noul
        $skillName = [string]$questionToSkill[$property.Name]
        $scores[$skillName] = $probability
        if ($probability -ge $Threshold) {
            $selected += $skillName
        }
    }

    $usage = Get-PropertyValue -Object $call.response -Name 'usage'
    return [pscustomobject]@{
        selected = @(ConvertTo-SkillSet -Value $selected)
        scores = $scores
        duration_ms = $call.duration_ms
        cost = Get-PropertyValue -Object $usage -Name 'cost'
        input_tokens = Get-PropertyValue -Object $usage -Name 'input_tokens'
        output_tokens = Get-PropertyValue -Object $usage -Name 'output_tokens'
        actual_model = Get-PropertyValue -Object $call.response -Name 'model'
        provider = Get-PropertyValue -Object $call.response -Name 'provider'
        error = $null
    }
}

function Invoke-LlmRoute {
    param(
        [string]$Prompt,
        [object[]]$Catalog,
        [string]$ResolvedApiKey,
        [string]$Model,
        [string]$ReasoningEffort,
        [int]$TimeoutSeconds
    )

    $skillNames = @($Catalog | ForEach-Object { $_.name })
    $catalogJson = @($Catalog | Select-Object name, description) | ConvertTo-Json -Depth 5 -Compress
    $systemPrompt = @"
You are a routing classifier for VS Code Agent Skills. Select every skill whose description materially matches the user's current request and whose specialized workflow would help. Select no skill when generic coding-agent behavior is sufficient. Do not select skills merely because the prompt mentions a related technology. Return only the JSON object required by the response schema.

Available auto-invocable skills:
$catalogJson
"@

    $body = [ordered]@{
        model = $Model
        messages = @(
            [ordered]@{ role = 'system'; content = $systemPrompt.Trim() },
            [ordered]@{ role = 'user'; content = $Prompt }
        )
        max_tokens = 256
        reasoning_effort = $ReasoningEffort
        response_format = [ordered]@{
            type = 'json_schema'
            json_schema = [ordered]@{
                name = 'skill_routing'
                strict = $true
                schema = [ordered]@{
                    type = 'object'
                    properties = [ordered]@{
                        selected = [ordered]@{
                            type = 'array'
                            items = [ordered]@{
                                type = 'string'
                                enum = $skillNames
                            }
                        }
                    }
                    required = @('selected')
                    additionalProperties = $false
                }
            }
        }
    }

    $call = Invoke-JsonPost -Uri 'https://openrouter.ai/api/v1/chat/completions' -Headers @{
        Authorization = "Bearer $ResolvedApiKey"
        'Content-Type' = 'application/json'
        'X-OpenRouter-Title' = 'Jev Skills Router Benchmark'
    } -Body $body -TimeoutSeconds $TimeoutSeconds

    if ($call.error) {
        return [pscustomobject]@{
            selected = @()
            scores = $null
            duration_ms = $call.duration_ms
            cost = $null
            input_tokens = $null
            output_tokens = $null
            actual_model = $null
            provider = $null
            error = $call.error
        }
    }

    try {
        $choice = @($call.response.choices)[0]
        $message = Get-PropertyValue -Object $choice -Name 'message'
        $content = [string](Get-PropertyValue -Object $message -Name 'content')
        $content = [regex]::Replace($content.Trim(), '(?s)^```(?:json)?\s*|\s*```$', '')
        $parsed = $content | ConvertFrom-Json
        $selected = @(ConvertTo-SkillSet -Value (Get-PropertyValue -Object $parsed -Name 'selected'))
        $unknown = @($selected | Where-Object { $_ -notin $skillNames })
        if ($unknown.Count -gt 0) {
            throw "LLM returned unknown skills: $($unknown -join ', ')"
        }
    }
    catch {
        return [pscustomobject]@{
            selected = @()
            scores = $null
            duration_ms = $call.duration_ms
            cost = Get-PropertyValue -Object (Get-PropertyValue -Object $call.response -Name 'usage') -Name 'cost'
            input_tokens = Get-PropertyValue -Object (Get-PropertyValue -Object $call.response -Name 'usage') -Name 'prompt_tokens'
            output_tokens = Get-PropertyValue -Object (Get-PropertyValue -Object $call.response -Name 'usage') -Name 'completion_tokens'
            actual_model = Get-PropertyValue -Object $call.response -Name 'model'
            provider = Get-PropertyValue -Object $call.response -Name 'provider'
            error = "Response parsing failed: $($_.Exception.Message)"
        }
    }

    $usage = Get-PropertyValue -Object $call.response -Name 'usage'
    return [pscustomobject]@{
        selected = $selected
        scores = $null
        duration_ms = $call.duration_ms
        cost = Get-PropertyValue -Object $usage -Name 'cost'
        input_tokens = Get-PropertyValue -Object $usage -Name 'prompt_tokens'
        output_tokens = Get-PropertyValue -Object $usage -Name 'completion_tokens'
        actual_model = Get-PropertyValue -Object $call.response -Name 'model'
        provider = Get-PropertyValue -Object $call.response -Name 'provider'
        error = $null
    }
}

function Get-FixtureRoute {
    param(
        [object]$Fixture,
        [string]$Method,
        [string]$CurrentCaseId,
        [int]$RepeatIndex
    )

    $methodFixtures = Get-PropertyValue -Object $Fixture -Name $Method
    $caseRuns = Get-PropertyValue -Object $methodFixtures -Name $CurrentCaseId
    if ($null -eq $caseRuns) {
        throw "Fixture is missing $Method/$CurrentCaseId"
    }

    $runs = @($caseRuns)
    if ($RepeatIndex -ge $runs.Count) {
        throw "Fixture has $($runs.Count) $Method runs for $CurrentCaseId, but repeat $($RepeatIndex + 1) was requested"
    }

    $run = $runs[$RepeatIndex]
    return [pscustomobject]@{
        selected = @(ConvertTo-SkillSet -Value (Get-PropertyValue -Object $run -Name 'selected'))
        scores = Get-PropertyValue -Object $run -Name 'scores'
        duration_ms = Get-PropertyValue -Object $run -Name 'duration_ms'
        cost = Get-PropertyValue -Object $run -Name 'cost'
        input_tokens = Get-PropertyValue -Object $run -Name 'input_tokens'
        output_tokens = Get-PropertyValue -Object $run -Name 'output_tokens'
        actual_model = Get-PropertyValue -Object $run -Name 'actual_model'
        provider = Get-PropertyValue -Object $run -Name 'provider'
        error = Get-PropertyValue -Object $run -Name 'error'
    }
}

function New-ScoredResult {
    param(
        [string]$Method,
        [object]$Case,
        [int]$RepeatNumber,
        [int]$Sequence,
        [object]$Route
    )

    $expected = @(ConvertTo-SkillSet -Value $Case.expected)
    $selected = @(ConvertTo-SkillSet -Value $Route.selected)
    $truePositive = @($selected | Where-Object { $_ -in $expected }).Count
    $falsePositive = @($selected | Where-Object { $_ -notin $expected }).Count
    $falseNegative = @($expected | Where-Object { $_ -notin $selected }).Count
    $exactMatch = (-not $Route.error) -and ((Join-SkillSet -Value $expected) -eq (Join-SkillSet -Value $selected))

    return [pscustomobject]@{
        method = $Method
        case_id = [string]$Case.id
        repeat = $RepeatNumber
        sequence = $Sequence
        expected = $expected
        selected = $selected
        exact_match = $exactMatch
        true_positive = $truePositive
        false_positive = $falsePositive
        false_negative = $falseNegative
        duration_ms = $Route.duration_ms
        cost = $Route.cost
        input_tokens = $Route.input_tokens
        output_tokens = $Route.output_tokens
        actual_model = $Route.actual_model
        provider = $Route.provider
        scores = $Route.scores
        error = $Route.error
    }
}

function Get-Percentile {
    param(
        [double[]]$Values,
        [double]$Percentile
    )

    if ($Values.Count -eq 0) {
        return $null
    }

    $sorted = @($Values | Sort-Object)
    $index = [math]::Ceiling($Percentile * $sorted.Count) - 1
    $index = [math]::Max(0, [math]::Min($index, $sorted.Count - 1))
    return [math]::Round([double]$sorted[$index], 2)
}

function Get-Rate {
    param(
        [int]$Numerator,
        [int]$Denominator
    )

    if ($Denominator -eq 0) {
        return $null
    }

    return [math]::Round($Numerator / [double]$Denominator, 6)
}

function Get-MethodSummary {
    param(
        [string]$Method,
        [object[]]$Results,
        [object[]]$Cases,
        [int]$RepeatCount
    )

    $methodResults = @($Results | Where-Object { $_.method -eq $Method })
    $total = $methodResults.Count
    $truePositive = [int](($methodResults | Measure-Object -Property true_positive -Sum).Sum)
    $falsePositive = [int](($methodResults | Measure-Object -Property false_positive -Sum).Sum)
    $falseNegative = [int](($methodResults | Measure-Object -Property false_negative -Sum).Sum)
    $precision = Get-Rate -Numerator $truePositive -Denominator ($truePositive + $falsePositive)
    $recall = Get-Rate -Numerator $truePositive -Denominator ($truePositive + $falseNegative)
    $f1 = if ($null -eq $precision -or $null -eq $recall -or ($precision + $recall) -eq 0) {
        0.0
    }
    else {
        [math]::Round((2 * $precision * $recall) / ($precision + $recall), 6)
    }

    $negativeIds = @($Cases | Where-Object { @($_.expected).Count -eq 0 } | ForEach-Object { $_.id })
    $multiIds = @($Cases | Where-Object { @($_.expected).Count -gt 1 } | ForEach-Object { $_.id })
    $negativeResults = @($methodResults | Where-Object { $_.case_id -in $negativeIds })
    $multiResults = @($methodResults | Where-Object { $_.case_id -in $multiIds })
    $latencies = @($methodResults | Where-Object { $null -ne $_.duration_ms } | ForEach-Object { [double]$_.duration_ms })
    $costResults = @($methodResults | Where-Object { $null -ne $_.cost })
    $inputTokenResults = @($methodResults | Where-Object { $null -ne $_.input_tokens })
    $outputTokenResults = @($methodResults | Where-Object { $null -ne $_.output_tokens })

    $stabilityRate = $null
    if ($RepeatCount -gt 1) {
        $stableCases = 0
        foreach ($caseGroup in $methodResults | Group-Object case_id) {
            $sets = @($caseGroup.Group | ForEach-Object { Join-SkillSet -Value $_.selected } | Sort-Object -Unique)
            $errors = @($caseGroup.Group | Where-Object { $_.error }).Count
            if ($errors -eq 0 -and $sets.Count -eq 1) {
                $stableCases++
            }
        }
        $stabilityRate = Get-Rate -Numerator $stableCases -Denominator $Cases.Count
    }

    return [pscustomobject]@{
        method = $Method
        runs = $total
        successful_runs = @($methodResults | Where-Object { -not $_.error }).Count
        error_count = @($methodResults | Where-Object { $_.error }).Count
        reliability = Get-Rate -Numerator @($methodResults | Where-Object { -not $_.error }).Count -Denominator $total
        exact_match_rate = Get-Rate -Numerator @($methodResults | Where-Object { $_.exact_match }).Count -Denominator $total
        precision = $precision
        recall = $recall
        f1 = $f1
        no_skill_exact_rate = Get-Rate -Numerator @($negativeResults | Where-Object { $_.exact_match }).Count -Denominator $negativeResults.Count
        multi_skill_exact_rate = Get-Rate -Numerator @($multiResults | Where-Object { $_.exact_match }).Count -Denominator $multiResults.Count
        stability_rate = $stabilityRate
        mean_duration_ms = if ($latencies.Count -gt 0) { [math]::Round(($latencies | Measure-Object -Average).Average, 2) } else { $null }
        p50_duration_ms = Get-Percentile -Values $latencies -Percentile 0.50
        p95_duration_ms = Get-Percentile -Values $latencies -Percentile 0.95
        total_cost_usd = if ($costResults.Count -gt 0) { [math]::Round([double](($costResults | Measure-Object -Property cost -Sum).Sum), 8) } else { $null }
        cost_coverage = Get-Rate -Numerator $costResults.Count -Denominator $total
        input_tokens = if ($inputTokenResults.Count -gt 0) { [int64](($inputTokenResults | Measure-Object -Property input_tokens -Sum).Sum) } else { $null }
        output_tokens = if ($outputTokenResults.Count -gt 0) { [int64](($outputTokenResults | Measure-Object -Property output_tokens -Sum).Sum) } else { $null }
    }
}

function Format-Percent {
    param([object]$Value)

    if ($null -eq $Value) {
        return 'n/a'
    }
    return ('{0:P1}' -f [double]$Value)
}

function Format-Number {
    param([object]$Value)

    if ($null -eq $Value) {
        return 'n/a'
    }
    return ('{0:N2}' -f [double]$Value)
}

function Format-Cost {
    param([object]$Value)

    if ($null -eq $Value) {
        return 'n/a'
    }
    return ('$' + ('{0:F6}' -f [double]$Value))
}

function Escape-MarkdownCell {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return '(none)'
    }
    return ([string]$Value).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
}

if (-not (Test-Path -LiteralPath $CasesPath -PathType Leaf)) {
    throw "Cases file not found: $CasesPath"
}

$fixture = $null
if ($FixturePath) {
    if (-not (Test-Path -LiteralPath $FixturePath -PathType Leaf)) {
        throw "Fixture file not found: $FixturePath"
    }
    $fixture = [System.IO.File]::ReadAllText($FixturePath) | ConvertFrom-Json
}

if ($CatalogPath) {
    if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) {
        throw "Catalog file not found: $CatalogPath"
    }
    $parsedCatalog = [System.IO.File]::ReadAllText($CatalogPath) | ConvertFrom-Json
    $catalog = @()
    foreach ($catalogItem in $parsedCatalog) {
        $catalog += $catalogItem
    }
}
elseif ($fixture -and (Get-PropertyValue -Object $fixture -Name 'catalog')) {
    $parsedCatalog = Get-PropertyValue -Object $fixture -Name 'catalog'
    $catalog = @()
    foreach ($catalogItem in $parsedCatalog) {
        $catalog += $catalogItem
    }
}
else {
    $catalog = @(Get-SkillCatalog -Workspace $WorkspacePath)
}

if ($catalog.Count -eq 0) {
    throw 'No auto-invocable skills were discovered.'
}

$catalogNames = @($catalog | ForEach-Object { [string]$_.name } | Sort-Object -Unique)
if ($catalogNames.Count -ne $catalog.Count) {
    throw 'Skill catalog contains duplicate names.'
}

$parsedCases = [System.IO.File]::ReadAllText($CasesPath) | ConvertFrom-Json
$cases = @()
foreach ($parsedCase in $parsedCases) {
    $cases += $parsedCase
}
if ($CaseId -and $CaseId.Count -gt 0) {
    $cases = @($cases | Where-Object { $_.id -in $CaseId })
}
if ($CaseLimit -gt 0) {
    $cases = @($cases | Select-Object -First $CaseLimit)
}
if ($cases.Count -eq 0) {
    throw 'No benchmark cases were selected.'
}

$duplicateCaseIds = @($cases | Group-Object id | Where-Object { $_.Count -gt 1 })
if ($duplicateCaseIds.Count -gt 0) {
    throw "Duplicate case IDs: $($duplicateCaseIds.Name -join ', ')"
}

$unknownLabels = @($cases.expected | ForEach-Object { $_ } | Where-Object { $_ -notin $catalogNames } | Sort-Object -Unique)
if ($unknownLabels.Count -gt 0) {
    throw "Cases reference skills outside the current catalog: $($unknownLabels -join ', ')"
}

$Methods = @($Methods | Sort-Object -Unique)
if (-not $fixture -and 'llm' -in $Methods -and -not $AllowOpenRouterLlmBaseline) {
    throw 'The non-Jev OpenRouter baseline is disabled by default. Pass -AllowOpenRouterLlmBaseline only for an explicit benchmark run.'
}

$resolvedApiKey = $null
if (-not $fixture) {
    $resolvedApiKey = Get-OpenRouterApiKey -ExplicitApiKey $ApiKey
    if (-not $resolvedApiKey) {
        throw 'No OpenRouter API key is available. Configure the DPAPI credential used by the Jev router or set OPENROUTER_API_KEY.'
    }
}

$totalCalls = $cases.Count * $Repeats * $Methods.Count
$completedCalls = 0
$results = @()
for ($repeatIndex = 0; $repeatIndex -lt $Repeats; $repeatIndex++) {
    for ($caseIndex = 0; $caseIndex -lt $cases.Count; $caseIndex++) {
        $case = $cases[$caseIndex]
        $methodsForCase = @($Methods)
        if ($methodsForCase.Count -gt 1 -and (($caseIndex + $repeatIndex) % 2) -ne 0) {
            [array]::Reverse($methodsForCase)
        }
        for ($sequenceIndex = 0; $sequenceIndex -lt $methodsForCase.Count; $sequenceIndex++) {
            $method = $methodsForCase[$sequenceIndex]
            $completedCalls++
            Write-Host ("[{0}/{1}] {2} | {3} | repeat {4}" -f $completedCalls, $totalCalls, $method.ToUpperInvariant(), $case.id, ($repeatIndex + 1))

            if ($fixture) {
                $route = Get-FixtureRoute -Fixture $fixture -Method $method -CurrentCaseId ([string]$case.id) -RepeatIndex $repeatIndex
            }
            elseif ($method -eq 'jev') {
                $route = Invoke-JevRoute -Prompt ([string]$case.prompt) -Catalog $catalog -ResolvedApiKey $resolvedApiKey -Model $JevModel -Threshold $JevThreshold -TimeoutSeconds $ApiTimeoutSeconds
            }
            else {
                $route = Invoke-LlmRoute -Prompt ([string]$case.prompt) -Catalog $catalog -ResolvedApiKey $resolvedApiKey -Model $LlmModel -ReasoningEffort $LlmReasoningEffort -TimeoutSeconds $ApiTimeoutSeconds
            }

            $results += New-ScoredResult -Method $method -Case $case -RepeatNumber ($repeatIndex + 1) -Sequence ($sequenceIndex + 1) -Route $route
        }
    }
}

$summaries = @($Methods | ForEach-Object {
    Get-MethodSummary -Method $_ -Results $results -Cases $cases -RepeatCount $Repeats
})

$generatedAt = (Get-Date).ToUniversalTime().ToString('o')
$artifact = [ordered]@{
    schema_version = 1
    generated_at = $generatedAt
    fixture_mode = [bool]$fixture
    configuration = [ordered]@{
        cases_path = $CasesPath
        workspace_path = $WorkspacePath
        case_count = $cases.Count
        repeats = $Repeats
        methods = $Methods
        jev_model = $JevModel
        jev_threshold = $JevThreshold
        llm_model = $LlmModel
        llm_reasoning_effort = $LlmReasoningEffort
        call_order = if ($Methods.Count -gt 1) { 'Alternated by case and repeat' } else { 'Single method' }
    }
    catalog = @($catalog | Select-Object name, description, source)
    cases = @($cases | Select-Object id, prompt, expected, tags)
    summaries = $summaries
    results = $results
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$jsonPath = Join-Path $OutputDirectory "benchmark-$stamp.json"
$markdownPath = Join-Path $OutputDirectory "benchmark-$stamp.md"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($jsonPath, (($artifact | ConvertTo-Json -Depth 20) + [Environment]::NewLine), $utf8NoBom)

$markdown = @()
$markdown += '# Jev Skills Router Benchmark'
$markdown += ''
$markdown += "Generated: $generatedAt"
$markdown += ''
$markdown += '## Configuration'
$markdown += ''
$markdown += "- Cases: $($cases.Count)"
$markdown += "- Repeats: $Repeats"
$markdown += "- Eligible skills: $($catalog.Count)"
$markdown += "- Jev: $JevModel at threshold $JevThreshold"
if ('llm' -in $Methods) {
    $markdown += "- LLM baseline: $LlmModel with reasoning effort $LlmReasoningEffort"
}
$markdown += "- Methods: $($Methods -join ', ')"
$markdown += "- Call order: $($artifact.configuration.call_order)"
$markdown += "- Fixture mode: $([bool]$fixture)"
$markdown += ''
$markdown += '## Summary'
$markdown += ''
$markdown += '| Router | Exact match | Precision | Recall | F1 | No-skill exact | Multi-skill exact | Reliability | Stability | Mean ms | P95 ms | Cost |'
$markdown += '|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|'
foreach ($summary in $summaries) {
    $markdown += ('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} | {10} | {11} |' -f
        $summary.method.ToUpperInvariant(),
        (Format-Percent $summary.exact_match_rate),
        (Format-Percent $summary.precision),
        (Format-Percent $summary.recall),
        (Format-Percent $summary.f1),
        (Format-Percent $summary.no_skill_exact_rate),
        (Format-Percent $summary.multi_skill_exact_rate),
        (Format-Percent $summary.reliability),
        (Format-Percent $summary.stability_rate),
        (Format-Number $summary.mean_duration_ms),
        (Format-Number $summary.p95_duration_ms),
        (Format-Cost $summary.total_cost_usd))
}
$markdown += ''
$markdown += '## Interpretation'
$markdown += ''
$markdown += '- Exact match is the primary routing-quality metric; it requires the complete selected skill set to match the reviewed label.'
$markdown += '- Precision measures over-routing, while recall measures missed applicable skills.'
$markdown += '- Stability is only meaningful with two or more repeats and requires identical selections with no API errors.'
if ('llm' -in $Methods) {
    $markdown += '- The LLM baseline uses an explicitly enabled OpenRouter model with the same skill metadata. VS Code does not expose Copilot''s private internal skill-routing request as a callable benchmark endpoint, so this is a controlled emulation rather than a direct invocation of that service.'
}
$markdown += '- The corpus is a seed benchmark, not a statistical proof. Add representative prompts from real work before making a production decision.'
$markdown += ''
$markdown += '## Mismatches And Errors'
$markdown += ''
$mismatches = @($results | Where-Object { -not $_.exact_match } | Sort-Object case_id, method, repeat)
if ($mismatches.Count -eq 0) {
    $markdown += 'None.'
}
else {
    $markdown += '| Case | Router | Repeat | Expected | Selected | Error |'
    $markdown += '|---|---|---:|---|---|---|'
    foreach ($result in $mismatches) {
        $markdown += ('| {0} | {1} | {2} | {3} | {4} | {5} |' -f
            (Escape-MarkdownCell $result.case_id),
            $result.method.ToUpperInvariant(),
            $result.repeat,
            (Escape-MarkdownCell ((ConvertTo-SkillSet $result.expected) -join ', ')),
            (Escape-MarkdownCell ((ConvertTo-SkillSet $result.selected) -join ', ')),
            (Escape-MarkdownCell $result.error))
    }
}
$markdown += ''
$markdown += "Raw evidence: $([System.IO.Path]::GetFileName($jsonPath))"
[System.IO.File]::WriteAllText($markdownPath, (($markdown -join [Environment]::NewLine) + [Environment]::NewLine), $utf8NoBom)

$output = [pscustomobject]@{
    json_path = $jsonPath
    markdown_path = $markdownPath
    summaries = $summaries
}
$output

$errorCount = @($results | Where-Object { $_.error }).Count
if ($FailOnApiError -and $errorCount -gt 0) {
    throw "$errorCount API or parsing errors occurred. Reports were written to $OutputDirectory."
}
