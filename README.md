# Hugr Solve

Adversarial synthesis engine. Two LLM agents debate a problem from opposing stances until convergence or deadlock. The friction is the mechanism.

Pollock 2026.

## What it does

- **Two agents, forced adversarial conversation.** Agent A opens with a position. Agent B challenges, extends, or corrects. They alternate turns.
- **Three outcomes.** `[RESOLVED]` (convergence), `[DEADLOCKED]` (needs human input), or max rounds hit. Deadlock is valid. It means the problem needs you, not more compute.
- **Shared memory via Seedvault.** Either agent can search mid-turn with `[SEARCH: query]`. Results feed back before their next response. Optional but recommended.
- **Budget-capped and cost-tracked.** Per-turn cost estimates with a hard cap. Stops before burning money on circular conversations.
- **Retry logic.** Transient API failures get 3 retries with backoff.
- **JSON output.** Structured output for programmatic consumption. Pipe into other tools.
- **Lock file.** Only one solve runs at a time. No parallel conflicts.
- **Dashboard viewer.** Newspaper-style HTML viewer for browsing all solve sessions.
- **Any two LLMs.** Anthropic + xAI. OpenAI + Ollama. Any combination with an API.

## Install

```bash
git clone https://github.com/cogpros/hugr-solve.git
cd hugr-solve
```

## Setup

1. **Create your environment file:**
   ```bash
   cp .env.example .env
   chmod 600 .env
   ```

2. **Add your API keys to `.env`:**
   ```
   AGENT_A_API_KEY=your-key-here
   AGENT_B_API_KEY=your-key-here
   SEEDVAULT_TOKEN=optional-but-recommended
   ```

3. **Edit `config.sh`:**
   - Name your agents
   - Set providers, models, endpoints
   - Set per-million-token pricing for cost tracking
   - Configure Seedvault URL if using shared memory
   - Edit protocol rules if needed (defaults are tested)

4. **Make scripts executable:**
   ```bash
   chmod +x hugr-solve.sh hugr-solve-sync.sh
   ```

5. **Run:**
   ```bash
   ./hugr-solve.sh "Should we rewrite the auth layer or patch the existing one?"
   ```

## Usage

```bash
# Simple
./hugr-solve.sh "problem statement here"

# From file (keeps problem out of ps output)
./hugr-solve.sh --file problem.md --topic auth-rewrite

# With budget and round limits
./hugr-solve.sh --budget 1.00 --max-rounds 4 "quick question"

# JSON output for piping
./hugr-solve.sh --json-output --no-notify "design question" | jq '.status'
```

## Seedvault

Seedvault gives both agents access to shared memory. Without it, they work from the problem statement alone. With it, they can pull context mid-conversation.

Set `SEEDVAULT_URL` in `config.sh` and `SEEDVAULT_TOKEN` in `.env`. Any search API that accepts `?q=` and returns JSON works.

The script extracts keywords from the problem statement, runs initial searches, and provides results as context. During the conversation, agents can request additional searches with `[SEARCH: query]`.

## Supported Providers

| Provider | `config.sh` value | Endpoint example |
|----------|-------------------|-----------------|
| Anthropic (Claude) | `anthropic` | `https://api.anthropic.com/v1/messages` |
| OpenAI | `openai` | `https://api.openai.com/v1/chat/completions` |
| xAI (Grok) | `openai` | `https://api.x.ai/v1/chat/completions` |
| Groq | `openai` | `https://api.groq.com/openai/v1/chat/completions` |
| Ollama (local) | `ollama` | `http://localhost:11434/v1/chat/completions` |

## Cost Tracking

Set `AGENT_A_PRICING` and `AGENT_B_PRICING` in config.sh as `input:output` per million tokens. The script tracks cost per turn and per agent.

Typical costs (varies by model):
- 3-round solve: $0.05-0.20
- Full 8-round deep debate: up to $2.50
- Budget cap (default $5.00) prevents runaway conversations

## The Viewer

`viewer.html` is a self-contained dashboard. No server needed. Open it in a browser.

- Index page lists all solve sessions with topic, status, and cost
- Session pages render the full transcript with status badges
- Auto-syncs after each run via `hugr-solve-sync.sh`
- Customize branding via the `VIEWER_CONFIG` object

## Why Two Models

A single model analyzing a problem gives you one perspective. Two different models with different training create natural friction. Agent A proposes. Agent B stress-tests. The resolution that survives adversarial pressure is stronger than either agent's first answer.

The protocol enforces this: no first-turn resolutions, both must speak, searches are shared. The conversation is the product.

## Security

- API keys live in `.env`, which is in `.gitignore`
- `umask 077` on all output files
- `--file` mode keeps problem statements out of `ps` output
- No telemetry. No analytics. No network calls except to the APIs you configure
- Lock file prevents parallel runs

## File Structure

```
hugr-solve/
├── SKILL.md              # Agent Skills spec
├── README.md             # This file
├── LICENSE.txt            # MIT
├── .gitignore             # Ignores .env, output/, logs/
├── .env.example           # API key template
├── config.sh              # Agent config, protocol rules, pricing
├── hugr-solve.sh          # Main script
├── hugr-solve-sync.sh     # Syncs output into the HTML viewer
├── viewer.html            # Dashboard viewer
├── output/                # Generated transcripts (gitignored)
└── logs/                  # Logs and lock file (gitignored)
```

## Origin

Built by Dustin Pollock as part of the [cogpros](https://github.com/cogpros) research program. The adversarial synthesis pattern emerged from running two cognitive prosthetic agents (EOM and Odin) against hard problems daily. The protocol turned out to be useful beyond its original context.

See also: [Two Birds Talking](https://github.com/cogpros/two-birds-talking) (lightweight daily debrief version) and [prism-orchestrator](https://github.com/cogpros/prism-orchestrator) (the same adversarial instinct pointed at code review, multiple reviewer roles instead of two debaters).

## License

MIT. See [LICENSE.txt](LICENSE.txt).
