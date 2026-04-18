---
name: hugr-solve
description: >
  Adversarial synthesis engine. Two LLM agents debate a problem from opposing
  stances until convergence or deadlock. Optional shared memory via Seedvault.
  Budget-capped, cost-tracked, with retry logic and JSON output mode.
  Use for high-stakes decisions or any problem where a single-pass answer
  is insufficient. NOT for routine tasks or obvious answers.
license: MIT
compatibility: Requires bash, curl, python3. macOS or Linux.
metadata:
  author: Dustin Pollock / cogpros
  version: "1.1.0"
---

# Hugr Solve

Adversarial synthesis engine. Two agents, opposing stances, forced convergence.

Pollock 2026.

## The Protocol

Two LLM agents take opposing cognitive stances on the same problem. Agent A opens (sets the first position). Agent B challenges, extends, or corrects. They alternate until one declares `[RESOLVED]` (convergence), `[DEADLOCKED]` (needs human input), or the round/budget cap is hit.

Disagreement is the mechanism, not a failure mode. Both agents must speak before convergence is allowed. Quick agreement may indicate shallow synthesis.

Either agent can search shared memory (Seedvault) mid-turn by outputting `[SEARCH: query]`. Results are fed back before their next response. This gives both agents access to context beyond the problem statement.

Deadlock is a valid outcome. It means the problem needs human judgment, not more compute.

### Artifact Phase

When `[RESOLVED]` fires, two more turns run (can be disabled with `ARTIFACT_PHASE=false`):

1. **Artifact turn.** The resolving agent produces the final deliverable with its own `ARTIFACT_MAX_TOKENS` budget (default 6000). This separates synthesis from artifact production so large tables, code, or documents don't get truncated by the debate turn's smaller budget.
2. **Drift check turn.** The opposing agent reviews the artifact against the resolved position. It outputs `[ALIGNED]` with a one-sentence confirmation, or `[DRIFT]` with a short paragraph naming the specific drifts. The drift check does not rewrite the artifact — it is a verification pass, not another debate round.

The output markdown gains `## Deliverable` and `## Drift Check` sections when these phases run. JSON output gains `artifact` and `drift_check` top-level fields.

**Phase turns are isolated from the debate protocol.** They use agent `IDENTITY` only (not the full `PROTOCOL_RULES` with `[SEARCH:]`/`[RESOLVED]`/`[DEADLOCKED]` affordances). Phase-specific rules explicitly forbid debate control tokens so agents can't emit them here — that prevents silent corruption of downstream parsing. The drift-check agent may only output `[ALIGNED]` or `[DRIFT]`.

**When `[DRIFT]` fires:** `status` becomes `DRIFT_FLAGGED` and the script exits with code 3. The conversation still reached `[RESOLVED]` and the artifact was produced — the drift check just found the two don't match. No auto-restart (unbounded cost risk and the drift check may itself be wrong). The caller decides: retry, escalate to human, or accept.

## Quick Start

1. Clone:
   ```bash
   git clone https://github.com/cogpros/hugr-solve.git
   cd hugr-solve
   ```

2. Set up your environment:
   ```bash
   cp .env.example .env
   chmod 600 .env
   # Edit .env with your API keys
   ```

3. Configure your agents:
   ```bash
   # Edit config.sh: agent names, models, providers, pricing, protocol rules
   ```

4. Run:
   ```bash
   chmod +x hugr-solve.sh hugr-solve-sync.sh
   ./hugr-solve.sh "Should we use a monorepo or separate repos for the frontend and backend?"
   ```

5. Check `output/` for the transcript. Open `viewer.html` for the dashboard.

## Usage

```bash
hugr-solve.sh [OPTIONS] "problem statement"
```

| Option | Description |
|--------|-------------|
| `--file PATH` | Read problem from file (keeps it out of `ps` output) |
| `--topic SLUG` | Output filename slug (auto-generated if omitted) |
| `--budget N.NN` | Cost cap in USD (default: 5.00) |
| `--max-rounds N` | Max conversation turns (default: 8) |
| `--source NAME` | Trigger source for logging (default: cli) |
| `--no-notify` | Suppress notification |
| `--json-output` | Output structured JSON to stdout |

### JSON Output

When `--json-output` is set, the script prints structured JSON to stdout:

```json
{
  "status": "RESOLVED",
  "turns": 3,
  "max_rounds": 8,
  "cost": {"total": "0.2535", "Alpha": "0.0135", "Beta": "0.2400"},
  "topic": "monorepo-vs-separate",
  "output_file": "./output/2026-03-27-monorepo-vs-separate.md",
  "transcript": [...],
  "resolution": "...",
  "artifact": "...",
  "drift_check": "..."
}
```

`artifact` and `drift_check` are `null` when the artifact phase was disabled, skipped for budget, or failed.

## Configuration

All configuration lives in `config.sh`. API keys live in `.env`.

### Agents

| Setting | Description |
|---------|-------------|
| `AGENT_A_NAME` | Display name for Agent A (opens the conversation) |
| `AGENT_A_PROVIDER` | `anthropic`, `openai`, or `ollama` |
| `AGENT_A_MODEL` | Model string your provider expects |
| `AGENT_A_ENDPOINT` | API URL |
| `AGENT_A_KEY_VAR` | Name of the `.env` variable holding the API key |
| `AGENT_A_MAX_TOKENS` | Max tokens per turn |
| `AGENT_A_PRICING` | `input:output` per million tokens for cost tracking |

Same for Agent B.

**Tip:** Use a cheaper/faster model for Agent A (opens, sets position). Use a stronger model for Agent B (challenges, catches what A missed).

### Protocol Rules

The `PROTOCOL_RULES` string in config.sh defines how the adversarial conversation works. The defaults encode tested behavior:

- State positions clearly
- `[SEARCH: query]` for shared memory access
- `[RESOLVED]` or `[DEADLOCKED]` to end
- No first-turn resolutions
- Build on what the other said, don't repeat
- Keep `[RESOLVED]` turns concise — the artifact phase handles the deliverable

Edit if needed, but test after changing.

### Artifact Phase

| Setting | Description |
|---------|-------------|
| `ARTIFACT_PHASE` | `true` (default) or `false`. When `false`, the script stops at `[RESOLVED]` like pre-1.1 behavior. |
| `ARTIFACT_MAX_TOKENS` | Token budget for the artifact turn (default: 6000). Raise if deliverables still truncate. |
| `DRIFT_CHECK_MAX_TOKENS` | Token budget for the drift-check turn (default: 1500). Keep small — drift checks should be brief. |

The artifact and drift-check turns inherit each agent's base system prompt and add phase-specific rules. They do not participate in the search loop.

### Providers

| Provider value | Works with |
|---------------|------------|
| `anthropic` | Anthropic (Claude) |
| `openai` | OpenAI, xAI, Groq, Together, any OpenAI-compatible |
| `ollama` | Local Ollama |

### Seedvault (Shared Memory)

Set `SEEDVAULT_URL` in config.sh and `SEEDVAULT_TOKEN` in `.env`. Both agents can search shared memory mid-conversation. Without Seedvault, agents work from the problem statement alone. The conversation still runs, just without external context.

Recommended: [vault-ai](https://github.com/pashpashpash/vault-ai) or any search API that accepts `?q=` query params and returns JSON results.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Completed (RESOLVED, DEADLOCKED, or MAX_ROUNDS) |
| 1 | Runtime error (API failure, lock contention) |
| 2 | Config error (missing .env, missing keys) |
| 3 | DRIFT_FLAGGED — conversation resolved, but the drift check found the artifact does not faithfully represent the resolved position. Caller decides whether to retry, escalate, or accept. |

## When to Use

- Decisions where getting it wrong is expensive
- Design questions with multiple valid approaches
- Prioritization under ambiguity
- Stress-testing claims before committing to them
- System architecture decisions
- Any problem where a single-pass answer feels insufficient

## When NOT to Use

- Routine tasks (file moves, config changes)
- Problems with obvious answers
- Time-sensitive work (conversations take minutes)
- Low-stakes decisions (if being wrong costs nothing, just decide)
- Simple research (one agent is enough)

## Gotchas

1. **Cost is real.** Each run makes multiple LLM API calls. Typical: $0.05-0.20 for 3 rounds, up to $2.50 for a full 8-round deep debate. The budget cap stops runaway conversations.

2. **Lock contention.** Only one solve runs at a time. Lock file at `./logs/hugr-solve.lock` with 600s stale timeout.

3. **Quick convergence.** If both agents resolve in 2 turns, they may have agreed too easily. The transcript will tell you whether the friction was real.

4. **CLI args in process list.** Problem statements passed as arguments appear in `ps` output. Use `--file` for sensitive problems.

5. **Transcripts are permanent.** Every run writes a full transcript. If a solve contains sensitive deliberation, be aware it persists in `./output/`.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Exit code 2 | Missing config. Check `.env` and `config.sh` exist with correct values |
| "Another hugr-solve is running" | Wait for it, or check if the lock is stale (>600s) |
| Agents agree immediately | The problem may be simple, or increase `MIN_TURNS_BEFORE_RESOLVE` |
| "[API HTTP 429]" | Rate limited. The retry logic handles this (3 retries, 25s backoff) |
| Seedvault searches return nothing | Check `SEEDVAULT_URL` and `SEEDVAULT_TOKEN`. Verify Seedvault is running |
| Cost tracking shows $0.00 | Update `AGENT_A_PRICING` and `AGENT_B_PRICING` to match your provider |

## Credits

Built by Dustin Pollock as part of the cogpros (cognitive prosthetics) research program.
Hugr Solve is the heavyweight adversarial engine. Two Birds Talking is the lightweight daily version.

MIT License.
