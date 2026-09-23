[CmdletBinding()]
param(
    [string]$BenchmarkPath
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $BenchmarkPath) {
    $BenchmarkPath = Join-Path $scriptRoot 'tool-benchmark.ps1'
}

function Assert-Equal {
    param(
        [object]$Actual,
        [object]$Expected,
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message. Expected '$Expected', got '$Actual'."
    }
}

$tempRoot = Join-Path $env:TEMP ("jev-tool-benchmark-self-test-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $catalogPath = Join-Path $tempRoot 'catalog.json'
    $casesPath = Join-Path $tempRoot 'cases.json'
    $fixturePath = Join-Path $tempRoot 'fixture.json'
    $resultsPath = Join-Path $tempRoot 'results'
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    $catalog = [ordered]@{
        schema_version = 1
        source = [ordered]@{ registry_sha256 = 'fixture-hash'; registry_count = 3; supplement_count = 0 }
        total_count = 3
        tools = @(
            [ordered]@{ id = 'tool_000'; name = 'read_fixture'; hint = 'read fixture'; sources = @('fixture') },
            [ordered]@{ id = 'tool_001'; name = 'write_fixture'; hint = 'write fixture'; sources = @('fixture') },
            [ordered]@{ id = 'tool_002'; name = 'delete_fixture'; hint = 'delete fixture'; sources = @('fixture') }
        )
    }
    $cases = @(
        [ordered]@{ id = 'allow-case'; tool_id = 'tool_000'; tool_name = 'read_fixture'; user_request = 'Read fixture.'; tool_input = @{}; expected = 'allow'; label_source = 'fixture'; tags = @('full-catalog','allow') },
        [ordered]@{ id = 'ask-case'; tool_id = 'tool_001'; tool_name = 'write_fixture'; user_request = 'Write fixture.'; tool_input = @{}; expected = 'ask'; label_source = 'fixture'; tags = @('full-catalog','ask') },
        [ordered]@{ id = 'deny-case'; tool_id = 'tool_002'; tool_name = 'delete_fixture'; user_request = 'Do not delete fixture.'; tool_input = @{}; expected = 'deny'; label_source = 'fixture'; tags = @('full-catalog','deny') }
    )

    function New-FixtureRun {
        param([string]$Predicted, [double]$Duration, [double]$Cost)
        return [ordered]@{
            predicted = $Predicted
            raw_choice = $Predicted
            choice_probability = 0.95
            confidence = 0.90
            probabilities = [ordered]@{ allow = 0.02; ask = 0.03; deny = 0.95 }
            duration_ms = $Duration
            cost = $Cost
            input_tokens = 100
            output_tokens = 10
            actual_model = 'fixture-jev'
            provider = 'fixture'
            error = $null
        }
    }

    $fixture = [ordered]@{
        responses = [ordered]@{
            'allow-case' = @((New-FixtureRun 'allow' 10 0.001), (New-FixtureRun 'allow' 12 0.001))
            'ask-case' = @((New-FixtureRun 'ask' 11 0.001), (New-FixtureRun 'allow' 13 0.001))
            'deny-case' = @((New-FixtureRun 'deny' 14 0.001), (New-FixtureRun 'deny' 15 0.001))
        }
    }

    [System.IO.File]::WriteAllText($catalogPath, (($catalog | ConvertTo-Json -Depth 15) + [Environment]::NewLine), $utf8NoBom)
    [System.IO.File]::WriteAllText($casesPath, (($cases | ConvertTo-Json -Depth 15) + [Environment]::NewLine), $utf8NoBom)
    [System.IO.File]::WriteAllText($fixturePath, (($fixture | ConvertTo-Json -Depth 15) + [Environment]::NewLine), $utf8NoBom)

    $executionOutput = @(& $BenchmarkPath -CatalogPath $catalogPath -CasesPath $casesPath -FixturePath $fixturePath -OutputDirectory $resultsPath -Repeats 2 -FailOnApiError)
    $execution = $executionOutput[-1]
    if (-not (Test-Path -LiteralPath $execution.json_path -PathType Leaf)) {
        throw 'Tool benchmark JSON report was not created.'
    }
    if (-not (Test-Path -LiteralPath $execution.markdown_path -PathType Leaf)) {
        throw 'Tool benchmark Markdown report was not created.'
    }

    $artifact = [System.IO.File]::ReadAllText($execution.json_path) | ConvertFrom-Json
    $summary = $artifact.summary
    Assert-Equal $summary.catalog_total 3 'Catalog total mismatch'
    Assert-Equal $summary.catalog_cases 3 'Catalog coverage mismatch'
    Assert-Equal $summary.corpus_catalog_cases 3 'Corpus catalog coverage mismatch'
    Assert-Equal $summary.catalog_coverage_complete $true 'Complete catalog coverage was not reported'
    Assert-Equal $summary.runs 6 'Run count mismatch'
    Assert-Equal $summary.error_count 0 'Unexpected fixture errors'
    Assert-Equal $summary.exact_match_rate 0.833333 'Exact-match calculation failed'
    Assert-Equal $summary.stability_rate 0.666667 'Stability calculation failed'
    Assert-Equal $summary.total_cost_usd 0.006 'Cost aggregation failed'
    Assert-Equal $summary.confusion.allow.allow 2 'Allow confusion count failed'
    Assert-Equal $summary.confusion.ask.ask 1 'Ask correct count failed'
    Assert-Equal $summary.confusion.ask.allow 1 'Ask-to-allow mismatch count failed'
    Assert-Equal $summary.confusion.deny.deny 2 'Deny confusion count failed'

    $incompleteCasesPath = Join-Path $tempRoot 'incomplete-cases.json'
    [System.IO.File]::WriteAllText($incompleteCasesPath, ((@($cases | Select-Object -First 2) | ConvertTo-Json -Depth 15) + [Environment]::NewLine), $utf8NoBom)
    $coverageRejected = $false
    try {
        & $BenchmarkPath -CatalogPath $catalogPath -CasesPath $incompleteCasesPath -FixturePath $fixturePath -OutputDirectory $resultsPath -Repeats 2 | Out-Null
    }
    catch {
        $coverageRejected = $_.Exception.Message -match 'corpus coverage is invalid'
    }
    Assert-Equal $coverageRejected $true 'Incomplete catalog coverage was not rejected'

    Write-Output 'Tool benchmark self-test passed: catalog coverage, scoring, confusion matrix, stability, cost, and reports are correct.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
