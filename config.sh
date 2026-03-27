#!/usr/bin/env bash
# config.sh -- hugr-solve configuration
# Edit this file to set up your agents, models, and preferences.

# ============================================================
# AGENT A -- Opens the conversation. Sets the first position.
# Tip: use a cheaper/faster model here since it goes first.
# ============================================================
AGENT_A_NAME="Alpha"
AGENT_A_PROVIDER="openai"             # anthropic | openai | ollama
AGENT_A_MODEL="gpt-4o"
AGENT_A_ENDPOINT="https://api.openai.com/v1/chat/completions"
AGENT_A_KEY_VAR="AGENT_A_API_KEY"     # Name of the env var in .env holding the key
AGENT_A_MAX_TOKENS=1500               # Max tokens per turn for Agent A

# ============================================================
# AGENT B -- Challenges, extends, or corrects Agent A.
# Tip: use a stronger model here for deeper analysis.
# ============================================================
AGENT_B_NAME="Beta"
AGENT_B_PROVIDER="anthropic"          # anthropic | openai | ollama
AGENT_B_MODEL="claude-sonnet-4-6"
AGENT_B_ENDPOINT="https://api.anthropic.com/v1/messages"
AGENT_B_KEY_VAR="AGENT_B_API_KEY"
AGENT_B_MAX_TOKENS=2500               # Max tokens per turn for Agent B

# ============================================================
# CONVERSATION
# ============================================================
MAX_ROUNDS=8                          # Max conversation turns (1-20). Default: 8.
BUDGET_CAP="5.00"                     # Cost cap in USD. Script stops when exceeded.
MIN_TURNS_BEFORE_RESOLVE=2            # Both agents must speak before convergence.
MAX_SEARCH_LOOPS=2                    # Max Seedvault searches per turn before forcing advance.
TEMPERATURE=0.5                       # Temperature for all API calls.

# ============================================================
# AGENT SYSTEM PROMPTS
# ============================================================
# These define how each agent approaches the problem.
# The adversarial protocol rules are appended automatically.

AGENT_A_IDENTITY="You are ${AGENT_A_NAME}, one half of a problem-solving pair. You are in a conversation with ${AGENT_B_NAME}. Your goal is to reach a concrete, actionable resolution."

AGENT_B_IDENTITY="You are ${AGENT_B_NAME}, one half of a problem-solving pair. You are in a conversation with ${AGENT_A_NAME}. Your goal is to reach a concrete, actionable resolution."

# ============================================================
# ADVERSARIAL PROTOCOL RULES
# ============================================================
# These rules are appended to both agent system prompts.
# They define how the adversarial conversation works.
# Edit if needed, but the defaults encode tested behavior.

PROTOCOL_RULES="Rules:
- State your position clearly. If you disagree with the other agent, say why.
- If you need information from shared memory, output [SEARCH: your query] on its own line. Results will be provided before your next response. Only search when truly blocked. Reasoning is free.
- If you have enough information to solve the problem AND you are past the opening phase, output [RESOLVED] on its own line followed by the solution.
- If the problem cannot be resolved without human input, output [DEADLOCKED] on its own line and state what is missing.
- Be direct. No preamble. No filler. Work the problem.
- Build on what the other agent said. Don't repeat. Advance.
- IMPORTANT: Do NOT output [RESOLVED] or [DEADLOCKED] on your first turn. Both agents must speak before convergence."

# ============================================================
# SEEDVAULT (optional shared memory)
# ============================================================
# URL to your Seedvault search endpoint. Leave empty to skip.
# Seedvault gives both agents access to shared memory mid-conversation.
# Without it, agents work from the problem statement alone.
# Get Seedvault: https://github.com/pashpashpash/vault-ai
SEEDVAULT_URL=""

# ============================================================
# COST TRACKING
# ============================================================
# Per-million-token pricing for each provider.
# Used to estimate cost per turn. Update if your pricing differs.
# Format: input_per_million:output_per_million

AGENT_A_PRICING="5:15"                # e.g., GPT-4o: $5 input, $15 output per 1M tokens
AGENT_B_PRICING="3:15"                # e.g., Claude Sonnet: $3 input, $15 output per 1M tokens

# ============================================================
# PATHS
# ============================================================
OUTPUT_DIR="./output"                 # Where solve transcripts are saved.
LOG_DIR="./logs"                      # Where logs go.
VIEWER_FILE="./viewer.html"           # Path to the HTML dashboard viewer.

# ============================================================
# NOTIFICATIONS
# ============================================================
NOTIFY_METHOD="none"                  # telegram | discord | none

# ============================================================
# VIEWER BRANDING
# ============================================================
# Customize the viewer by editing the VIEWER_CONFIG object
# at the top of the <script> section in viewer.html.
