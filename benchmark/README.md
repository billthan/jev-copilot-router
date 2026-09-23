# Benchmark

The benchmark measures skill-routing exact match, precision, recall, F1, negative-control accuracy, multi-skill accuracy, stability, latency, token use, and OpenRouter-reported cost.

## Provider Policy

The default method is Jev only. Normal Copilot model work is not routed through OpenRouter.

VS Code does not expose GitHub Copilot's internal skill-routing call as a benchmark endpoint. The optional `llm` method is therefore a controlled OpenRouter emulation and is blocked unless the caller explicitly supplies `-AllowOpenRouterLlmBaseline`.

## Offline Self-Test

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -NoProfile -ExecutionPolicy Bypass `
  -File ".\benchmark\self-test.ps1"
```

## Jev-Only Run

```powershell
& ".\benchmark\benchmark.ps1" `
  -WorkspacePath "C:\path\to\workspace" `
  -Methods jev `
  -Repeats 3 `
  -FailOnApiError
```

## Explicit Historical A/B Reproduction

```powershell
& ".\benchmark\benchmark.ps1" `
  -WorkspacePath "C:\path\to\workspace" `
  -Methods jev,llm `
  -LlmModel "openai/gpt-5.6-sol" `
  -LlmReasoningEffort none `
  -AllowOpenRouterLlmBaseline `
  -Repeats 3 `
  -FailOnApiError
```

This explicit A/B mode is for benchmark reproduction only. It is not used by either installed hook.

Add representative prompts to `cases.json`. Use an empty `expected` array when no skill should load and multiple names for multi-skill cases.
