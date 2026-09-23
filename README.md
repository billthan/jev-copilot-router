# Jev Copilot Router

A user-level VS Code hook package that uses the TypeSafe Jev decision model through OpenRouter for:

1. Exhaustive Agent Skill selection on every user prompt.
2. Permission evaluation on every tool call.

All normal language-model work remains on GitHub Copilot and its credit system. The OpenRouter credential is accepted only for `typesafe/jev-*` models on the OpenRouter Decisions endpoint.

## Behavior

### Skill Selection

The `UserPromptSubmit` hook inventories every `SKILL.md` from:

- The configured workspace or skill root, recursively
- `~/.copilot/skills`
- `~/.claude/skills`
- `~/.agents/skills`
- The installed VS Code Copilot bundle

Temporary, archived, dependency, and build trees are excluded. Manual-only skills remain in Jev's catalog input with `auto_invocable: false`, but they are not automatically selected. No fixed skill-count limit truncates the request.

The current validation inventory contains 65 skill files: 52 workspace and 13 bundled.

### Tool Evaluation

The `PreToolUse` hook sends every requested tool call to Jev as a typed Choice decision:

- `allow`: directly serves the request and is safe, scoped, and reversible or routine
- `ask`: meaningful side effects, publication, deployment, installation, broad writes, sensitive access, cost, or uncertainty
- `deny`: unrelated, destructive, credential-disclosing, safeguard-bypassing, or privilege-escalating

VS Code remains the permission authority. Jev `allow` and `ask` classifications return no permission override, so the user's current mode decides whether the tool runs, prompts, or is auto-approved. This preserves restrictive settings while preventing the hook from prompting in Allow All and Autopilot modes.

A Jev `deny` decision blocks the call only when its probability is `>= 0.90`. Lower-confidence results, missing context, unavailable credentials, invalid provider configuration, timeouts, and API failures also return no permission override instead of forcing a prompt.

The latest user prompt and selected skills are stored locally per session so Jev can judge each tool call against the active goal.

## Security And Privacy

- The API key is stored with Windows DPAPI in `~/.copilot/jev-router/openrouter-key.clixml`.
- The key is never committed or written to hook output.
- Tool input is recursively redacted for passwords, tokens, API keys, authorization headers, credentials, cookies, signatures, SAS parameters, and common secret formats.
- Long values and deep structures are truncated before transmission.
- Jev receives the user prompt, skill catalog metadata, selected skills, tool name, and redacted tool input.
- Every user prompt and tool call incurs an OpenRouter Jev request. Review OpenRouter privacy, retention, and pricing before enabling this globally.

## Provider Policy

Production routing is intentionally split:

| Work | Provider |
|---|---|
| Skill classification | Jev through OpenRouter Decisions API |
| Tool risk classification | Jev through OpenRouter Decisions API |
| Agent response generation | GitHub Copilot |
| Subagents and utility model work | GitHub Copilot |

The hooks reject non-Jev model IDs and alternate endpoints before reading the OpenRouter credential.

## Install

Prerequisites:

- Windows PowerShell 5.1 or later
- VS Code with GitHub Copilot and Agent Hooks support
- An OpenRouter API key with access to Jev

```powershell
git clone https://github.com/billthan/jev-copilot-router.git
Set-Location jev-copilot-router

& .\scripts\Install-JevRouter.ps1 `
  -SkillRoot "C:\path\to\your\workspace-root"
```

The installer:

- Copies runtime scripts to `~/.copilot/jev-router/scripts`
- Reuses the earlier DPAPI credential when present, otherwise prompts securely
- Creates `~/.copilot/hooks/jev-router.json`
- Registers both `UserPromptSubmit` and `PreToolUse`
- Disables the legacy `jev-skills-router.json` registration to prevent duplicate calls

For non-Jev Agent Host work, keep this VS Code setting:

```json
"chat.agentHost.byokModels.enabled": false
```

Start a new agent session after installation.

## Test

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -NoProfile -ExecutionPolicy Bypass `
  -File ".\tests\Run-Tests.ps1" `
  -WorkspaceRoot "C:\path\to\your\workspace-root"
```

The test suite is offline. It validates PowerShell 5.1 parsing, provider restrictions, exhaustive skill discovery, secret redaction, session state, isolated installation, user-permission precedence, rejected-provider behavior, and benchmark scoring.

## Benchmark

See [benchmark/README.md](benchmark/README.md), the sanitized [initial skill-routing benchmark](benchmark/results/2026-09-23-initial.md), and the [full-tool-catalog benchmark](benchmark/results/2026-09-23-full-tool-catalog.md).

The full-tool harness currently inventories 268 unique tools from the installed Copilot registry plus the active agent supplement. It enforces exactly one coverage case per tool, adds five reviewed deny controls, and refuses live execution when catalog coverage or OpenRouter credit preflight fails.

Full-tool result over 273 cases and three repeats:

| Metric | Jev |
|---|---:|
| Catalog coverage | 268/268 |
| Reliability | 100% |
| Policy agreement | 92.4% |
| Stability | 99.3% |
| Mean latency | 404.63 ms |
| P95 latency | 493.52 ms |
| Cost | `$0.56484187` |

All 15 reviewed deny-control runs were correctly denied. The agreement labels are generated by a conservative name-token policy and are not objective safety ground truth.

Initial result over 24 cases and three repeats:

| Metric | Jev | Explicit test-only GPT-5.6 Sol baseline |
|---|---:|---:|
| Exact match | 79.2% | 83.3% |
| F1 | 88.9% | 90.9% |
| Mean latency | 316.05 ms | 1,541.35 ms |
| P95 latency | 490.95 ms | 2,377.77 ms |
| Cost | `$0.00515768` | `$0.03052100` |

Jev was approximately 4.9 times faster and 5.9 times cheaper on the seed corpus. The optional non-Jev OpenRouter baseline is disabled by default and is never used by the installed hooks.

## Files

- `scripts/JevRouter.Common.ps1`: provider policy, inventory, redaction, session state, and API helpers
- `scripts/Invoke-JevSkillRouter.ps1`: exhaustive skill selection hook
- `scripts/Invoke-JevToolEvaluator.ps1`: all-tool risk evaluation hook
- `scripts/Install-JevRouter.ps1`: user-level installer
- `tests/Run-Tests.ps1`: offline validation suite
- `benchmark/`: skill and full-tool corpora, runners, self-tests, and sanitized reports
