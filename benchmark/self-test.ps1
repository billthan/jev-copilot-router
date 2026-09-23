[CmdletBinding()]
param(
    [string]$BenchmarkPath
)

$ErrorActionPreference = 'Stop'
if (-not $BenchmarkPath) {
    $BenchmarkPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'benchmark.ps1'
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

$tempRoot = Join-Path $env:TEMP ("jev-router-benchmark-self-test-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $casesPath = Join-Path $tempRoot 'cases.json'
    $fixturePath = Join-Path $tempRoot 'fixture.json'
    $resultsPath = Join-Path $tempRoot 'results'
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    $cases = @(
        [ordered]@{ id = 'skill-a'; prompt = 'Use skill A'; expected = @('skill-a'); tags = @('positive') },
        [ordered]@{ id = 'skill-b'; prompt = 'Use skill B'; expected = @('skill-b'); tags = @('positive') },
        [ordered]@{ id = 'no-skill'; prompt = 'Use generic behavior'; expected = @(); tags = @('negative') },
        [ordered]@{ id = 'multi'; prompt = 'Use both skills'; expected = @('skill-a', 'skill-b'); tags = @('multi-skill') }
    )

    $fixture = [ordered]@{
        catalog = @(
            [ordered]@{ name = 'skill-a'; description = 'Handles task A.'; source = 'fixture' },
            [ordered]@{ name = 'skill-b'; description = 'Handles task B.'; source = 'fixture' }
        )
        jev = [ordered]@{
            'skill-a' = @(
                [ordered]@{ selected = @('skill-a'); duration_ms = 10; cost = 0.00001; input_tokens = 100; output_tokens = 5; actual_model = 'fixture-jev'; provider = 'fixture' },
                [ordered]@{ selected = @('skill-a'); duration_ms = 12; cost = 0.00001; input_tokens = 100; output_tokens = 5; actual_model = 'fixture-jev'; provider = 'fixture' }
            )
            'skill-b' = @(
                [ordered]@{ selected = @('skill-b'); duration_ms = 11; cost = 0.00001; input_tokens = 100; output_tokens = 5; actual_model = 'fixture-jev'; provider = 'fixture' },
                [ordered]@{ selected = @('skill-b'); duration_ms = 13; cost = 0.00001; input_tokens = 100; output_tokens = 5; actual_model = 'fixture-jev'; provider = 'fixture' }
            )
            'no-skill' = @(
                [ordered]@{ selected = @(); duration_ms = 9; cost = 0.00001; input_tokens = 100; output_tokens = 5; actual_model = 'fixture-jev'; provider = 'fixture' },
                [ordered]@{ selected = @(); duration_ms = 10; cost = 0.00001; input_tokens = 100; output_tokens = 5; actual_model = 'fixture-jev'; provider = 'fixture' }
            )
            'multi' = @(
                [ordered]@{ selected = @('skill-a', 'skill-b'); duration_ms = 14; cost = 0.00001; input_tokens = 100; output_tokens = 5; actual_model = 'fixture-jev'; provider = 'fixture' },
                [ordered]@{ selected = @('skill-a', 'skill-b'); duration_ms = 15; cost = 0.00001; input_tokens = 100; output_tokens = 5; actual_model = 'fixture-jev'; provider = 'fixture' }
            )
        }
        llm = [ordered]@{
            'skill-a' = @(
                [ordered]@{ selected = @('skill-a'); duration_ms = 30; cost = 0.001; input_tokens = 200; output_tokens = 10; actual_model = 'fixture-llm'; provider = 'fixture' },
                [ordered]@{ selected = @('skill-a'); duration_ms = 32; cost = 0.001; input_tokens = 200; output_tokens = 10; actual_model = 'fixture-llm'; provider = 'fixture' }
            )
            'skill-b' = @(
                [ordered]@{ selected = @(); duration_ms = 31; cost = 0.001; input_tokens = 200; output_tokens = 10; actual_model = 'fixture-llm'; provider = 'fixture' },
                [ordered]@{ selected = @('skill-b'); duration_ms = 33; cost = 0.001; input_tokens = 200; output_tokens = 10; actual_model = 'fixture-llm'; provider = 'fixture' }
            )
            'no-skill' = @(
                [ordered]@{ selected = @('skill-a'); duration_ms = 29; cost = 0.001; input_tokens = 200; output_tokens = 10; actual_model = 'fixture-llm'; provider = 'fixture' },
                [ordered]@{ selected = @('skill-a'); duration_ms = 30; cost = 0.001; input_tokens = 200; output_tokens = 10; actual_model = 'fixture-llm'; provider = 'fixture' }
            )
            'multi' = @(
                [ordered]@{ selected = @('skill-a'); duration_ms = 34; cost = 0.001; input_tokens = 200; output_tokens = 10; actual_model = 'fixture-llm'; provider = 'fixture' },
                [ordered]@{ selected = @('skill-a'); duration_ms = 35; cost = 0.001; input_tokens = 200; output_tokens = 10; actual_model = 'fixture-llm'; provider = 'fixture' }
            )
        }
    }

    [System.IO.File]::WriteAllText($casesPath, (($cases | ConvertTo-Json -Depth 10) + [Environment]::NewLine), $utf8NoBom)
    [System.IO.File]::WriteAllText($fixturePath, (($fixture | ConvertTo-Json -Depth 10) + [Environment]::NewLine), $utf8NoBom)

    $executionOutput = @(& $BenchmarkPath -CasesPath $casesPath -FixturePath $fixturePath -OutputDirectory $resultsPath -Methods @('jev', 'llm') -Repeats 2 -FailOnApiError)
    $execution = $executionOutput[-1]
    if (-not (Test-Path -LiteralPath $execution.json_path -PathType Leaf)) {
        throw 'Benchmark JSON report was not created.'
    }
    if (-not (Test-Path -LiteralPath $execution.markdown_path -PathType Leaf)) {
        throw 'Benchmark Markdown report was not created.'
    }

    $artifact = [System.IO.File]::ReadAllText($execution.json_path) | ConvertFrom-Json
    $jev = @($artifact.summaries | Where-Object { $_.method -eq 'jev' })[0]
    $llm = @($artifact.summaries | Where-Object { $_.method -eq 'llm' })[0]

    Assert-Equal $artifact.configuration.case_count 4 'Case count mismatch'
    Assert-Equal $artifact.configuration.repeats 2 'Repeat count mismatch'
    Assert-Equal $artifact.results.Count 16 'Run count mismatch'
    Assert-Equal $jev.exact_match_rate 1 'Jev exact-match calculation failed'
    Assert-Equal $jev.f1 1 'Jev F1 calculation failed'
    Assert-Equal $jev.stability_rate 1 'Jev stability calculation failed'
    Assert-Equal $jev.total_cost_usd 0.00008 'Jev cost aggregation failed'
    Assert-Equal $llm.exact_match_rate 0.375 'LLM exact-match calculation failed'
    Assert-Equal $llm.stability_rate 0.75 'LLM stability calculation failed'
    Assert-Equal $llm.no_skill_exact_rate 0 'LLM negative-control calculation failed'
    Assert-Equal $llm.error_count 0 'Unexpected fixture errors'

    Write-Output 'Benchmark self-test passed: scoring, stability, cost aggregation, and JSON/Markdown reports are correct.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
