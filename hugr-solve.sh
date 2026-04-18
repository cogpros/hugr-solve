#!/usr/bin/env bash
# hugr-solve.sh -- Adversarial synthesis between two LLM agents
# Agent A opens. Agent B challenges. They alternate until convergence or deadlock.
# Either agent can search shared memory (Seedvault) mid-turn.
# Hard cap at max rounds and budget. Cost tracked per turn.
# Pollock 2026. cogpros.
umask 077

export PATH="/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
CONFIG_FILE="$SCRIPT_DIR/config.sh"

TODAY=$(date '+%Y-%m-%d')

# Defaults (overridden by config.sh)
MAX_ROUNDS=8
BUDGET_CAP="5.00"
TOPIC=""
PROBLEM=""
PROBLEM_FILE=""
TRIGGER_SOURCE="cli"
NO_NOTIFY=false
JSON_OUTPUT=false
ARTIFACT_PHASE=true
ARTIFACT_MAX_TOKENS=6000
DRIFT_CHECK_MAX_TOKENS=1500
ARTIFACT_PHASE_RULES="You are now in ARTIFACT PHASE. The adversarial discussion has already resolved. Your only job in this turn is to produce the final deliverable cleanly, using the full token budget available to you. Do not reopen closed questions. Do not restart the debate. Build the thing."
ARTIFACT_PHASE_PROMPT="The discussion has reached [RESOLVED]. Now produce the final deliverable based on what was just resolved. Use the full token budget. No preamble. No reopening of debate. Build the artifact the problem asked for."
DRIFT_CHECK_RULES="You are now in DRIFT CHECK PHASE. An artifact was just produced by the other agent after [RESOLVED]. Your job is to verify the artifact faithfully represents what was agreed. Do not rewrite the artifact. Do not restart the debate. Be brief."
DRIFT_CHECK_PROMPT="The other agent produced an artifact after [RESOLVED]. Review it against the resolved position.
- If it faithfully represents what was agreed, output [ALIGNED] on its own line followed by one sentence confirming alignment.
- If it drifts from what was agreed, output [DRIFT] on its own line followed by a short paragraph naming the specific drifts.
Do not rewrite the artifact. Max one paragraph."

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) PROBLEM_FILE="$2"; shift 2;;
    --topic) TOPIC="$2"; shift 2;;
    --budget) BUDGET_CAP="$2"; shift 2;;
    --max-rounds) MAX_ROUNDS="$2"; shift 2;;
    --source) TRIGGER_SOURCE="$2"; shift 2;;
    --no-notify) NO_NOTIFY=true; shift;;
    --json-output) JSON_OUTPUT=true; shift;;
    --help|-h)
      echo "Usage: hugr-solve.sh [OPTIONS] \"problem statement\""
      echo ""
      echo "Options:"
      echo "  --file PATH        Read problem from file"
      echo "  --topic SLUG       Output filename slug (auto-generated if omitted)"
      echo "  --budget N.NN      Cost cap in USD (default: 5.00)"
      echo "  --max-rounds N     Max conversation turns (default: 8)"
      echo "  --source NAME      Trigger source for logging (default: cli)"
      echo "  --no-notify        Suppress notification"
      echo "  --json-output      Output structured JSON instead of markdown"
      exit 0;;
    -*) echo "Unknown option: $1"; exit 1;;
    *) PROBLEM="$1"; shift;;
  esac
done

# --- Load config ---
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "FATAL: config.sh not found at $CONFIG_FILE" >&2
  echo "Copy config.sh from the repo and edit it." >&2
  exit 2
fi
source "$CONFIG_FILE"

# --- Setup paths ---
OUTPUT_DIR="${OUTPUT_DIR:-./output}"
LOG_DIR="${LOG_DIR:-./logs}"
LOG="$LOG_DIR/hugr-solve.log"
LOCK="$LOG_DIR/hugr-solve.lock"

mkdir -p "$OUTPUT_DIR" "$LOG_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; echo "[$(date '+%H:%M:%S')] $*" >&2; }

# --- Load env ---
if [[ ! -f "$ENV_FILE" ]]; then
  echo "FATAL: .env not found at $ENV_FILE" >&2
  echo "Copy .env.example to .env and add your API keys." >&2
  exit 2
fi
set -a; source "$ENV_FILE"; set +a

# --- Load problem ---
if [[ -n "$PROBLEM_FILE" ]]; then
  if [[ ! -f "$PROBLEM_FILE" ]]; then
    log "FATAL: Problem file not found: $PROBLEM_FILE"
    exit 1
  fi
  PROBLEM=$(cat "$PROBLEM_FILE")
fi

if [[ -z "$PROBLEM" ]]; then
  echo "Error: No problem statement provided." >&2
  echo "Usage: hugr-solve.sh \"problem statement\" or --file path/to/problem.md" >&2
  exit 1
fi

# --- Validate keys ---
AGENT_A_KEY="${!AGENT_A_KEY_VAR}"
AGENT_B_KEY="${!AGENT_B_KEY_VAR}"

if [[ -z "$AGENT_A_KEY" ]]; then
  log "FATAL: $AGENT_A_KEY_VAR not set in .env"
  exit 2
fi
if [[ -z "$AGENT_B_KEY" ]]; then
  log "FATAL: $AGENT_B_KEY_VAR not set in .env"
  exit 2
fi

# --- Auto-generate topic if not provided ---
if [[ -z "$TOPIC" ]]; then
  TOPIC=$(echo "$PROBLEM" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 ]//g' | awk '{for(i=1;i<=4&&i<=NF;i++) printf "%s-",$i; print ""}' | sed 's/-$//' | head -c 40)
fi

# --- Lock (only one solve at a time) ---
if [[ -f "$LOCK" ]]; then
  lock_pid=$(cat "$LOCK" 2>/dev/null | tr -d '[:space:]')
  if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
    log "Another hugr-solve is running (PID $lock_pid). Exiting."
    exit 0
  fi
  # Check stale lock (macOS vs Linux)
  if [[ "$(uname)" == "Darwin" ]]; then
    lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK") ))
  else
    lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCK") ))
  fi
  if [[ "$lock_age" -lt 600 ]]; then
    log "Recent lock (${lock_age}s old). Skipping."
    exit 0
  fi
  log "Stale lock removed."
  rm -f "$LOCK"
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

log "=== Hugr Solve: $TOPIC ==="
log "Problem: ${PROBLEM:0:120}..."
log "Budget: \$$BUDGET_CAP | Max rounds: $MAX_ROUNDS | Source: $TRIGGER_SOURCE"

# --- Cost tracking ---
TOTAL_COST="0.00"
AGENT_A_COST="0.00"
AGENT_B_COST="0.00"

add_cost() {
  local agent="$1" input_tokens="$2" output_tokens="$3"
  local cost

  if [[ "$agent" == "$AGENT_A_NAME" ]]; then
    local a_input a_output
    a_input=$(echo "$AGENT_A_PRICING" | cut -d: -f1)
    a_output=$(echo "$AGENT_A_PRICING" | cut -d: -f2)
    cost=$(python3 -c "print(f'{($input_tokens * $a_input + $output_tokens * $a_output) / 1000000:.4f}')")
    AGENT_A_COST=$(python3 -c "print(f'{$AGENT_A_COST + $cost:.4f}')")
  else
    local b_input b_output
    b_input=$(echo "$AGENT_B_PRICING" | cut -d: -f1)
    b_output=$(echo "$AGENT_B_PRICING" | cut -d: -f2)
    cost=$(python3 -c "print(f'{($input_tokens * $b_input + $output_tokens * $b_output) / 1000000:.4f}')")
    AGENT_B_COST=$(python3 -c "print(f'{$AGENT_B_COST + $cost:.4f}')")
  fi
  TOTAL_COST=$(python3 -c "print(f'{$AGENT_A_COST + $AGENT_B_COST:.4f}')")
  log "Cost update: +\$$cost ($agent) | Total: \$$TOTAL_COST"
}

budget_exceeded() {
  python3 -c "import sys; sys.exit(0 if $TOTAL_COST >= $BUDGET_CAP else 1)"
}

# --- Seedvault search ---
seedvault_search() {
  local query="$1"
  if [[ -z "$SEEDVAULT_URL" ]] || [[ -z "$SEEDVAULT_TOKEN" ]]; then
    echo "(Seedvault not configured)"
    return
  fi

  local encoded
  encoded=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$query" 2>/dev/null)
  local result
  result=$(curl -s --max-time 10 \
    -H "Authorization: Bearer ${SEEDVAULT_TOKEN}" \
    "${SEEDVAULT_URL}?q=${encoded}" 2>/dev/null)

  if [[ -z "$result" ]] || [[ "$result" == *"error"* ]]; then
    echo "(Seedvault search returned no results)"
    return
  fi

  echo "$result" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    results = data.get("results", data) if isinstance(data, dict) else data
    if not results:
        print("(No results)")
    else:
        for r in results[:8]:
            if isinstance(r, dict):
                title = r.get("title", r.get("path", ""))
                snippet = r.get("content", r.get("snippet", ""))[:200]
                print(f"- {title}: {snippet}")
            else:
                print(f"- {str(r)[:200]}")
except Exception as e:
    print(f"(Seedvault parse error: {e})")
' 2>&1
}

# --- Initial Seedvault context ---
SEEDVAULT_CONTEXT=""
if [[ -n "$SEEDVAULT_URL" ]] && [[ -n "$SEEDVAULT_TOKEN" ]]; then
  log "Searching Seedvault for initial context..."
  SV_KEYWORDS=$(echo "$PROBLEM" | python3 -c '
import sys, re
stopwords = {"the","a","an","is","are","was","were","be","been","being","have","has","had","do","does","did","will","would","shall","should","may","might","can","could","of","in","to","for","with","on","at","by","from","as","into","through","during","before","after","above","below","between","but","and","or","not","no","so","if","then","than","too","very","just","about","how","what","when","where","which","who","whom","this","that","these","those","it","its","we","they","i","you","he","she","my","your","our","their","both","now","each","other","also","all","any","every","some","many","much","more","most","only","own","same","such","like","new","first","last","one","two","three","make","get","set","use","way","back","over","well","still","already","even","real","live","existing","really","actually","currently","specific","using","based","need","want","know","think","work","help","take","give","come","see","find","look","say","go","keep","let","begin","show","try","ask","seem","feel","become","leave","call","put","run","turn","hand","sure","tell","right","next"}
text = sys.stdin.read().lower()
words = re.findall(r"[a-z][a-z0-9-]+", text)
keywords = [w for w in words if w not in stopwords and len(w) > 2]
seen = set()
unique = []
for w in keywords:
    if w not in seen:
        seen.add(w)
        unique.append(w)
print(" ".join(unique[:6]))
' 2>/dev/null)

  if [[ -n "$SV_KEYWORDS" ]]; then
    for kw in $SV_KEYWORDS; do
      result=$(seedvault_search "$kw")
      if [[ "$result" != *"No results"* ]] && [[ "$result" != *"no results"* ]] && [[ "$result" != *"not configured"* ]]; then
        SEEDVAULT_CONTEXT+="$result
"
      fi
    done
    SEEDVAULT_CONTEXT=$(echo "$SEEDVAULT_CONTEXT" | awk '!seen[$0]++')
    log "Seedvault returned ${#SEEDVAULT_CONTEXT} chars from keyword searches"
  fi
else
  log "Seedvault not configured. Running without shared memory."
fi

# --- API helpers ---
is_api_error() {
  local result="$1"
  [[ -z "$result" ]] || [[ "$result" == *"[API call failed:"* ]] || [[ "$result" == *"[API error:"* ]] || [[ "$result" == *"[API HTTP"* ]] || [[ "$result" == *"[Unknown provider:"* ]]
}

# Call API with multi-turn messages
# Args: agent_name, provider, endpoint, api_key, model, messages_json_file, system_prompt_file, max_tokens, temperature
call_api() {
  local agent_name="$1"
  local provider="$2"
  local endpoint="$3"
  local api_key="$4"
  local model="$5"
  local messages_file="$6"
  local system_file="$7"
  local max_tok="${8:-800}"
  local temp="${9:-0.5}"

  local response_file=$(mktemp /tmp/hs-response-$$.XXXXXX)
  local payload_file=$(mktemp /tmp/hs-payload-$$.XXXXXX)

  case "$provider" in
    anthropic)
      python3 - "$system_file" "$messages_file" "$payload_file" "$model" "$max_tok" "$temp" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f: system = f.read()
with open(sys.argv[2]) as f: messages = json.load(f)
payload = {
    "model": sys.argv[4],
    "max_tokens": int(sys.argv[5]),
    "temperature": float(sys.argv[6]),
    "system": system,
    "messages": messages
}
with open(sys.argv[3], "w") as f: json.dump(payload, f)
PYEOF

      local http_code
      http_code=$(curl -s -w "%{http_code}" --max-time 180 -X POST "$endpoint" \
        -H "x-api-key: $api_key" \
        -H "anthropic-version: 2023-06-01" \
        -H "Content-Type: application/json" \
        -d @"$payload_file" \
        -o "$response_file" 2>&1)

      if [[ "$http_code" != "200" ]]; then
        log "ERROR: $agent_name API HTTP $http_code"
        rm -f "$response_file" "$payload_file"
        echo "[API HTTP $http_code]"
        return 1
      fi

      python3 - "$response_file" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
if "content" in data:
    text = data["content"][0]["text"]
    usage = data.get("usage", {})
    input_t = usage.get("input_tokens", 0)
    output_t = usage.get("output_tokens", 0)
    print(f"USAGE:{input_t}:{output_t}")
    print(text)
elif "error" in data:
    err = data["error"]
    msg = err.get("message", str(err)) if isinstance(err, dict) else str(err)
    print(f"[API error: {msg}]")
else:
    print("[API call failed: unexpected response]")
PYEOF
      ;;

    openai|ollama)
      python3 - "$system_file" "$messages_file" "$payload_file" "$model" "$max_tok" "$temp" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f: system = f.read()
with open(sys.argv[2]) as f: messages = json.load(f)
payload = {
    "model": sys.argv[4],
    "messages": [{"role": "system", "content": system}] + messages,
    "temperature": float(sys.argv[6]),
    "max_tokens": int(sys.argv[5])
}
with open(sys.argv[3], "w") as f: json.dump(payload, f)
PYEOF

      local auth_args=()
      if [[ "$provider" != "ollama" ]]; then
        auth_args=(-H "Authorization: Bearer $api_key")
      fi

      local http_code
      http_code=$(curl -s -w "%{http_code}" --max-time 180 -X POST "$endpoint" \
        "${auth_args[@]}" \
        -H "Content-Type: application/json" \
        -d @"$payload_file" \
        -o "$response_file" 2>&1)

      if [[ "$http_code" != "200" ]]; then
        log "ERROR: $agent_name API HTTP $http_code"
        rm -f "$response_file" "$payload_file"
        echo "[API HTTP $http_code]"
        return 1
      fi

      python3 - "$response_file" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
if "choices" in data:
    text = data["choices"][0]["message"]["content"]
    usage = data.get("usage", {})
    input_t = usage.get("prompt_tokens", 0)
    output_t = usage.get("completion_tokens", 0)
    print(f"USAGE:{input_t}:{output_t}")
    print(text)
elif "error" in data:
    msg = data["error"]
    if isinstance(msg, dict):
        msg = msg.get("message", str(msg))
    print(f"[API error: {msg}]")
else:
    print("[API call failed: unexpected response]")
PYEOF
      ;;

    *)
      echo "[Unknown provider: $provider]"
      ;;
  esac

  rm -f "$response_file" "$payload_file"
}

# Retry wrapper
call_agent() {
  local agent_name="$1"
  shift
  local max_retries=3
  local retry_delay=25
  local attempt=1
  local result

  while [[ $attempt -le $max_retries ]]; do
    result=$(call_api "$agent_name" "$@")

    if is_api_error "$result"; then
      if [[ $attempt -lt $max_retries ]]; then
        log "RETRY: $agent_name attempt $attempt failed. Waiting ${retry_delay}s..."
        sleep "$retry_delay"
        attempt=$((attempt + 1))
      else
        log "RETRY: $agent_name failed after $max_retries attempts."
        echo "$result"
        return 1
      fi
    else
      echo "$result"
      return 0
    fi
  done
}

# --- System prompts ---
AGENT_A_SYSTEM="${AGENT_A_IDENTITY}

${PROTOCOL_RULES}"

AGENT_B_SYSTEM="${AGENT_B_IDENTITY}

${PROTOCOL_RULES}"

# --- Transcript management ---
TRANSCRIPT_JSON=$(mktemp /tmp/hs-transcript-$$.XXXXXX)
echo "[]" > "$TRANSCRIPT_JSON"

build_messages() {
  local target_agent="$1"
  local target_name="$2"
  local output_file="$3"
  local sv_context="$4"
  local search_results="${5:-}"

  python3 - "$TRANSCRIPT_JSON" "$target_name" "$output_file" "$PROBLEM" "$sv_context" "$search_results" "$AGENT_A_NAME" << 'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    transcript = json.load(f)

target = sys.argv[2]
output_file = sys.argv[3]
problem = sys.argv[4]
sv_context = sys.argv[5]
search_results = sys.argv[6] if len(sys.argv) > 6 else ""
agent_a_name = sys.argv[7] if len(sys.argv) > 7 else ""

messages = []

first_msg = f"PROBLEM TO SOLVE:\n\n{problem}"
if sv_context:
    first_msg += f"\n\nSHARED MEMORY (Seedvault):\n{sv_context}"
if search_results:
    first_msg += f"\n\nSEARCH RESULTS:\n{search_results}"

if not transcript:
    messages.append({"role": "user", "content": first_msg})
else:
    conv = []
    for entry in transcript:
        role = "assistant" if entry["agent"] == target else "user"
        conv.append({"role": role, "content": entry["text"]})

    # Agent A always goes first
    is_opener = (target == agent_a_name)

    if is_opener:
        messages.append({"role": "user", "content": first_msg})
        for c in conv:
            messages.append(c)
        if messages[-1]["role"] == "assistant":
            next_prompt = "Continue working the problem. Build on what was said. Advance toward resolution."
            if search_results:
                next_prompt = f"Search results:\n{search_results}\n\n{next_prompt}"
            messages.append({"role": "user", "content": next_prompt})
    else:
        messages.append({"role": "user", "content": first_msg + "\n\n" + conv[0]["content"] if conv else first_msg})
        for c in conv[1:]:
            messages.append(c)
        if messages[-1]["role"] == "assistant":
            next_prompt = "Continue working the problem. Build on what was said. Advance toward resolution."
            if search_results:
                next_prompt = f"Search results:\n{search_results}\n\n{next_prompt}"
            messages.append({"role": "user", "content": next_prompt})

    # Ensure strict alternation
    merged = []
    for m in messages:
        if merged and merged[-1]["role"] == m["role"]:
            merged[-1]["content"] += "\n\n" + m["content"]
        else:
            merged.append(m)
    messages = merged

    if messages and messages[0]["role"] != "user":
        messages.insert(0, {"role": "user", "content": first_msg})

with open(output_file, "w") as f:
    json.dump(messages, f)
PYEOF
}

append_transcript() {
  local agent="$1"
  local text_file="$2"

  python3 - "$TRANSCRIPT_JSON" "$agent" "$text_file" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f: transcript = json.load(f)
with open(sys.argv[3]) as f: text = f.read()
transcript.append({"agent": sys.argv[2], "text": text})
with open(sys.argv[1], "w") as f: json.dump(transcript, f)
PYEOF
}

# Build messages for a phase turn (artifact or drift-check): full transcript
# plus a final user instruction. Unlike build_messages, this always appends
# the phase instruction regardless of whose turn it was.
build_phase_messages() {
  local target_agent="$1"
  local output_file="$2"
  local phase_instruction="$3"

  python3 - "$TRANSCRIPT_JSON" "$target_agent" "$output_file" "$PROBLEM" "$SEEDVAULT_CONTEXT" "$phase_instruction" "$AGENT_A_NAME" << 'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    transcript = json.load(f)

target = sys.argv[2]
output_file = sys.argv[3]
problem = sys.argv[4]
sv_context = sys.argv[5]
phase_instruction = sys.argv[6]
agent_a_name = sys.argv[7]

first_msg = f"PROBLEM TO SOLVE:\n\n{problem}"
if sv_context:
    first_msg += f"\n\nSHARED MEMORY (Seedvault):\n{sv_context}"

# Strip phase tags like "[artifact]" so role assignment works against base names.
def base_name(agent):
    return agent.split(" [")[0]

conv = []
for entry in transcript:
    role = "assistant" if base_name(entry["agent"]) == target else "user"
    conv.append({"role": role, "content": entry["text"]})

messages = []
is_opener = (target == agent_a_name)

if is_opener:
    messages.append({"role": "user", "content": first_msg})
    for c in conv:
        messages.append(c)
else:
    if conv:
        messages.append({"role": "user", "content": first_msg + "\n\n" + conv[0]["content"]})
        for c in conv[1:]:
            messages.append(c)
    else:
        messages.append({"role": "user", "content": first_msg})

messages.append({"role": "user", "content": phase_instruction})

merged = []
for m in messages:
    if merged and merged[-1]["role"] == m["role"]:
        merged[-1]["content"] += "\n\n" + m["content"]
    else:
        merged.append(m)

if merged and merged[0]["role"] != "user":
    merged.insert(0, {"role": "user", "content": first_msg})

with open(output_file, "w") as f:
    json.dump(merged, f)
PYEOF
}

# Artifact phase: after [RESOLVED], the resolving agent produces the deliverable
# with an expanded token budget, then the opposing agent checks for drift.
# Sets ARTIFACT_CONTENT and DRIFT_CHECK_CONTENT as side effects.
run_artifact_phase() {
  local resolver_name="$1"
  local resolver_provider resolver_model resolver_endpoint resolver_key resolver_system
  local other_name other_provider other_model other_endpoint other_key other_system

  if [[ "$resolver_name" == "$AGENT_A_NAME" ]]; then
    resolver_provider="$AGENT_A_PROVIDER"
    resolver_model="$AGENT_A_MODEL"
    resolver_endpoint="$AGENT_A_ENDPOINT"
    resolver_key="$AGENT_A_KEY"
    resolver_system="$AGENT_A_SYSTEM"
    other_name="$AGENT_B_NAME"
    other_provider="$AGENT_B_PROVIDER"
    other_model="$AGENT_B_MODEL"
    other_endpoint="$AGENT_B_ENDPOINT"
    other_key="$AGENT_B_KEY"
    other_system="$AGENT_B_SYSTEM"
  else
    resolver_provider="$AGENT_B_PROVIDER"
    resolver_model="$AGENT_B_MODEL"
    resolver_endpoint="$AGENT_B_ENDPOINT"
    resolver_key="$AGENT_B_KEY"
    resolver_system="$AGENT_B_SYSTEM"
    other_name="$AGENT_A_NAME"
    other_provider="$AGENT_A_PROVIDER"
    other_model="$AGENT_A_MODEL"
    other_endpoint="$AGENT_A_ENDPOINT"
    other_key="$AGENT_A_KEY"
    other_system="$AGENT_A_SYSTEM"
  fi

  # --- Artifact turn ---
  log "--- Artifact phase: $resolver_name producing deliverable (max_tokens: $ARTIFACT_MAX_TOKENS) ---"

  local art_sys_file art_msgs_file
  art_sys_file=$(mktemp /tmp/hs-art-sys-$$.XXXXXX)
  art_msgs_file=$(mktemp /tmp/hs-art-msgs-$$.XXXXXX)
  printf '%s\n\n%s' "$resolver_system" "$ARTIFACT_PHASE_RULES" > "$art_sys_file"
  build_phase_messages "$resolver_name" "$art_msgs_file" "$ARTIFACT_PHASE_PROMPT"

  local raw_art
  raw_art=$(call_agent "$resolver_name" "$resolver_provider" "$resolver_endpoint" "$resolver_key" \
    "$resolver_model" "$art_msgs_file" "$art_sys_file" "$ARTIFACT_MAX_TOKENS" "$TEMPERATURE")
  rm -f "$art_msgs_file" "$art_sys_file"

  if is_api_error "$raw_art"; then
    log "Artifact phase failed: $raw_art. Continuing without artifact."
    return
  fi

  local art_usage art_text
  art_usage=$(echo "$raw_art" | head -1)
  if [[ "$art_usage" == USAGE:* ]]; then
    local art_in art_out
    art_in=$(echo "$art_usage" | cut -d: -f2)
    art_out=$(echo "$art_usage" | cut -d: -f3)
    art_text=$(echo "$raw_art" | tail -n +2)
    add_cost "$resolver_name" "$art_in" "$art_out"
  else
    art_text="$raw_art"
  fi

  ARTIFACT_CONTENT="$art_text"

  local art_file
  art_file=$(mktemp /tmp/hs-artresp-$$.XXXXXX)
  printf '%s' "$art_text" > "$art_file"
  append_transcript "$resolver_name [artifact]" "$art_file"
  rm -f "$art_file"

  log "Artifact produced (${#art_text} chars)"

  if budget_exceeded; then
    log "Budget exceeded after artifact. Skipping drift check."
    return
  fi

  # --- Drift check turn ---
  log "--- Drift check: $other_name reviewing artifact (max_tokens: $DRIFT_CHECK_MAX_TOKENS) ---"

  local drift_sys_file drift_msgs_file
  drift_sys_file=$(mktemp /tmp/hs-drift-sys-$$.XXXXXX)
  drift_msgs_file=$(mktemp /tmp/hs-drift-msgs-$$.XXXXXX)
  printf '%s\n\n%s' "$other_system" "$DRIFT_CHECK_RULES" > "$drift_sys_file"
  build_phase_messages "$other_name" "$drift_msgs_file" "$DRIFT_CHECK_PROMPT"

  local raw_drift
  raw_drift=$(call_agent "$other_name" "$other_provider" "$other_endpoint" "$other_key" \
    "$other_model" "$drift_msgs_file" "$drift_sys_file" "$DRIFT_CHECK_MAX_TOKENS" "$TEMPERATURE")
  rm -f "$drift_msgs_file" "$drift_sys_file"

  if is_api_error "$raw_drift"; then
    log "Drift check failed: $raw_drift. Continuing without drift check."
    return
  fi

  local drift_usage drift_text
  drift_usage=$(echo "$raw_drift" | head -1)
  if [[ "$drift_usage" == USAGE:* ]]; then
    local drift_in drift_out
    drift_in=$(echo "$drift_usage" | cut -d: -f2)
    drift_out=$(echo "$drift_usage" | cut -d: -f3)
    drift_text=$(echo "$raw_drift" | tail -n +2)
    add_cost "$other_name" "$drift_in" "$drift_out"
  else
    drift_text="$raw_drift"
  fi

  DRIFT_CHECK_CONTENT="$drift_text"

  local drift_file
  drift_file=$(mktemp /tmp/hs-driftresp-$$.XXXXXX)
  printf '%s' "$drift_text" > "$drift_file"
  append_transcript "$other_name [drift-check]" "$drift_file"
  rm -f "$drift_file"

  if echo "$drift_text" | grep -q '\[DRIFT\]'; then
    log "DRIFT flagged by $other_name"
  else
    log "Drift check: aligned"
  fi
}

# --- Conversation loop ---
STATUS="MAX_ROUNDS"
FINAL_RESOLUTION=""
ARTIFACT_CONTENT=""
DRIFT_CHECK_CONTENT=""
TURN=0

while [[ $TURN -lt $MAX_ROUNDS ]]; do
  TURN=$((TURN + 1))

  # Alternate: odd turns = Agent A, even turns = Agent B
  if [[ $((TURN % 2)) -eq 1 ]]; then
    CURRENT_NAME="$AGENT_A_NAME"
    CURRENT_PROVIDER="$AGENT_A_PROVIDER"
    CURRENT_MODEL="$AGENT_A_MODEL"
    CURRENT_ENDPOINT="$AGENT_A_ENDPOINT"
    CURRENT_KEY="$AGENT_A_KEY"
    CURRENT_MAX_TOKENS="${AGENT_A_MAX_TOKENS:-1500}"
    CURRENT_SYSTEM="$AGENT_A_SYSTEM"
  else
    CURRENT_NAME="$AGENT_B_NAME"
    CURRENT_PROVIDER="$AGENT_B_PROVIDER"
    CURRENT_MODEL="$AGENT_B_MODEL"
    CURRENT_ENDPOINT="$AGENT_B_ENDPOINT"
    CURRENT_KEY="$AGENT_B_KEY"
    CURRENT_MAX_TOKENS="${AGENT_B_MAX_TOKENS:-2500}"
    CURRENT_SYSTEM="$AGENT_B_SYSTEM"
  fi

  SYSTEM_FILE=$(mktemp /tmp/hs-sys-$$.XXXXXX)
  printf '%s' "$CURRENT_SYSTEM" > "$SYSTEM_FILE"

  log "--- Turn $TURN/$MAX_ROUNDS: $CURRENT_NAME (max_tokens: $CURRENT_MAX_TOKENS) ---"

  # Search loop
  SEARCH_LOOP=0
  PENDING_SEARCH=""
  TURN_DONE=false

  while [[ "$TURN_DONE" == "false" ]]; do
    MESSAGES_FILE=$(mktemp /tmp/hs-msgs-$$.XXXXXX)
    build_messages "$CURRENT_NAME" "$CURRENT_NAME" "$MESSAGES_FILE" "$SEEDVAULT_CONTEXT" "$PENDING_SEARCH"
    PENDING_SEARCH=""

    RAW_RESULT=$(call_agent "$CURRENT_NAME" "$CURRENT_PROVIDER" "$CURRENT_ENDPOINT" "$CURRENT_KEY" \
      "$CURRENT_MODEL" "$MESSAGES_FILE" "$SYSTEM_FILE" "$CURRENT_MAX_TOKENS" "$TEMPERATURE")
    rm -f "$MESSAGES_FILE"

    if is_api_error "$RAW_RESULT"; then
      log "ERROR: Turn $TURN failed from $CURRENT_NAME: $RAW_RESULT"
      STATUS="API_FAILURE"
      TURN_DONE=true
      break 2
    fi

    # Parse usage line and response text
    USAGE_LINE=$(echo "$RAW_RESULT" | head -1)
    if [[ "$USAGE_LINE" == USAGE:* ]]; then
      INPUT_TOKENS=$(echo "$USAGE_LINE" | cut -d: -f2)
      OUTPUT_TOKENS=$(echo "$USAGE_LINE" | cut -d: -f3)
      RESPONSE_TEXT=$(echo "$RAW_RESULT" | tail -n +2)
      add_cost "$CURRENT_NAME" "$INPUT_TOKENS" "$OUTPUT_TOKENS"
    else
      RESPONSE_TEXT="$RAW_RESULT"
    fi

    # Check for [SEARCH:] requests
    HAS_SEARCHES=false
    SEARCH_RESULTS=""
    while IFS= read -r search_line; do
      SEARCH_QUERY=$(echo "$search_line" | sed 's/\[SEARCH: //;s/\]//')
      if [[ -n "$SEARCH_QUERY" ]]; then
        HAS_SEARCHES=true
        log "Seedvault search requested: $SEARCH_QUERY"
        result=$(seedvault_search "$SEARCH_QUERY")
        if [[ "$result" != *"No results"* ]] && [[ "$result" != *"no results"* ]] && [[ "$result" != *"not configured"* ]]; then
          SEARCH_RESULTS+="Results for \"$SEARCH_QUERY\":
$result

"
        else
          SEARCH_RESULTS+="Results for \"$SEARCH_QUERY\": (no matches)

"
        fi
      fi
    done < <(echo "$RESPONSE_TEXT" | grep -o '\[SEARCH: [^]]*\]')

    if [[ "$HAS_SEARCHES" == "true" ]] && [[ $SEARCH_LOOP -lt $MAX_SEARCH_LOOPS ]]; then
      SEARCH_LOOP=$((SEARCH_LOOP + 1))
      log "Search loop $SEARCH_LOOP/$MAX_SEARCH_LOOPS for $CURRENT_NAME. Feeding results back."

      RESP_FILE=$(mktemp /tmp/hs-resp-$$.XXXXXX)
      printf '%s' "$RESPONSE_TEXT" > "$RESP_FILE"
      append_transcript "$CURRENT_NAME" "$RESP_FILE"
      rm -f "$RESP_FILE"

      PENDING_SEARCH="$SEARCH_RESULTS"

      if budget_exceeded; then
        STATUS="BUDGET_EXCEEDED"
        log "Budget cap reached (\$$TOTAL_COST >= \$$BUDGET_CAP)"
        TURN_DONE=true
        break 2
      fi

      continue
    fi

    TURN_DONE=true

    RESP_FILE=$(mktemp /tmp/hs-resp-$$.XXXXXX)
    printf '%s' "$RESPONSE_TEXT" > "$RESP_FILE"
    append_transcript "$CURRENT_NAME" "$RESP_FILE"
    rm -f "$RESP_FILE"

    log "Turn $TURN response (search loops: $SEARCH_LOOP): ${RESPONSE_TEXT:0:100}..."

    # Check for convergence signals
    if echo "$RESPONSE_TEXT" | grep -q '\[RESOLVED\]'; then
      if [[ $TURN -lt $MIN_TURNS_BEFORE_RESOLVE ]]; then
        log "IGNORED [RESOLVED] at turn $TURN (minimum $MIN_TURNS_BEFORE_RESOLVE turns required). Continuing."
      else
        STATUS="RESOLVED"
        FINAL_RESOLUTION=$(echo "$RESPONSE_TEXT" | sed -n '/\[RESOLVED\]/,$ p' | tail -n +2)
        log "RESOLVED by $CURRENT_NAME at turn $TURN"
        rm -f "$SYSTEM_FILE"
        if [[ "$ARTIFACT_PHASE" == "true" ]] && ! budget_exceeded; then
          run_artifact_phase "$CURRENT_NAME"
        fi
        break 2
      fi
    fi

    if echo "$RESPONSE_TEXT" | grep -q '\[DEADLOCKED\]'; then
      if [[ $TURN -lt $MIN_TURNS_BEFORE_RESOLVE ]]; then
        log "IGNORED [DEADLOCKED] at turn $TURN (minimum $MIN_TURNS_BEFORE_RESOLVE turns required). Continuing."
      else
        STATUS="DEADLOCKED"
        FINAL_RESOLUTION=$(echo "$RESPONSE_TEXT" | sed -n '/\[DEADLOCKED\]/,$ p' | tail -n +2)
        log "DEADLOCKED by $CURRENT_NAME at turn $TURN"
        rm -f "$SYSTEM_FILE"
        break 2
      fi
    fi

  done

  rm -f "$SYSTEM_FILE"

  if budget_exceeded; then
    STATUS="BUDGET_EXCEEDED"
    log "Budget cap reached (\$$TOTAL_COST >= \$$BUDGET_CAP)"
    break
  fi
done

log "Conversation ended: $STATUS after $TURN turns. Cost: \$$TOTAL_COST"

# --- Write output file ---
SOLVE_FILE="$OUTPUT_DIR/${TODAY}-${TOPIC}.md"
if [[ -f "$SOLVE_FILE" ]]; then
  SOLVE_FILE="$OUTPUT_DIR/${TODAY}-${TOPIC}-$(date '+%H%M').md"
fi

TRANSCRIPT_RENDER_FILE=$(mktemp /tmp/hs-render-$$.XXXXXX)
RESOLUTION_FILE=$(mktemp /tmp/hs-resolution-$$.XXXXXX)
printf '%s' "${FINAL_RESOLUTION:-No explicit resolution reached.}" > "$RESOLUTION_FILE"

python3 - "$TRANSCRIPT_JSON" "$TRANSCRIPT_RENDER_FILE" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f: transcript = json.load(f)
lines = []
for i, entry in enumerate(transcript, 1):
    lines.append(f"**{entry['agent']} (Turn {i}):**\n\n{entry['text']}\n\n---\n")
with open(sys.argv[2], "w") as f: f.write("\n".join(lines))
PYEOF

TRANSCRIPT_RENDERED=$(cat "$TRANSCRIPT_RENDER_FILE")
RESOLUTION_RENDERED=$(cat "$RESOLUTION_FILE")
rm -f "$TRANSCRIPT_RENDER_FILE" "$RESOLUTION_FILE"

ARTIFACT_SECTION=""
if [[ -n "$ARTIFACT_CONTENT" ]]; then
  ARTIFACT_SECTION=$'\n## Deliverable\n\n'"$ARTIFACT_CONTENT"$'\n'
fi

DRIFT_SECTION=""
if [[ -n "$DRIFT_CHECK_CONTENT" ]]; then
  DRIFT_SECTION=$'\n## Drift Check\n\n'"$DRIFT_CHECK_CONTENT"$'\n'
fi

NOW_DISPLAY=$(date '+%Y-%m-%d %H:%M')

cat > "$SOLVE_FILE" << OUTPUTEOF
# Hugr Solve: $TOPIC
**Date:** $NOW_DISPLAY
**Status:** $STATUS
**Rounds:** $TURN/$MAX_ROUNDS
**Cost:** \$$TOTAL_COST ($AGENT_A_NAME: \$$AGENT_A_COST, $AGENT_B_NAME: \$$AGENT_B_COST)
**Triggered by:** $TRIGGER_SOURCE

## Problem

$PROBLEM

## Shared Memory Context

${SEEDVAULT_CONTEXT:-(No Seedvault context. Configure SEEDVAULT_URL in config.sh for shared memory.)}

## Transcript

$TRANSCRIPT_RENDERED

## Resolution

$RESOLUTION_RENDERED
$ARTIFACT_SECTION$DRIFT_SECTION
OUTPUTEOF

log "Output saved to $SOLVE_FILE"

# --- JSON output ---
if [[ "$JSON_OUTPUT" == "true" ]]; then
  python3 - "$TRANSCRIPT_JSON" "$STATUS" "$TURN" "$MAX_ROUNDS" "$TOTAL_COST" "$AGENT_A_COST" "$AGENT_B_COST" "$TOPIC" "$SOLVE_FILE" "$AGENT_A_NAME" "$AGENT_B_NAME" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f: transcript = json.load(f)
result = {
    "status": sys.argv[2],
    "turns": int(sys.argv[3]),
    "max_rounds": int(sys.argv[4]),
    "cost": {"total": sys.argv[5], sys.argv[10]: sys.argv[6], sys.argv[11]: sys.argv[7]},
    "topic": sys.argv[8],
    "output_file": sys.argv[9],
    "transcript": transcript,
    "resolution": transcript[-1]["text"].split("[RESOLVED]")[-1].strip() if any("[RESOLVED]" in t["text"] for t in transcript) else None
}
print(json.dumps(result, indent=2))
PYEOF
fi

# --- Notify ---
case "$NOTIFY_METHOD" in
  telegram)
    if [[ -n "$TELEGRAM_BOT_TOKEN" ]] && [[ -n "$TELEGRAM_CHAT_ID" ]]; then
      TG_MSG="Hugr Solve: ${TOPIC} -- ${STATUS} in ${TURN} rounds. Cost: \$${TOTAL_COST}"
      TG_ARGS=(-d "chat_id=${TELEGRAM_CHAT_ID}")
      if [[ -n "$TELEGRAM_THREAD_ID" ]]; then
        TG_ARGS+=(-d "message_thread_id=$TELEGRAM_THREAD_ID")
      fi
      curl -s --max-time 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        "${TG_ARGS[@]}" \
        --data-urlencode "text=$TG_MSG" \
        >/dev/null 2>&1 || log "Telegram notification failed (non-fatal)."
      log "Telegram notification sent."
    fi
    ;;
  discord)
    if [[ -n "$DISCORD_WEBHOOK_URL" ]]; then
      discord_msg=$(printf '%s' "Hugr Solve: ${TOPIC} -- ${STATUS} in ${TURN} rounds. Cost: \$${TOTAL_COST}" | python3 -c 'import sys,json; print(json.dumps({"content": sys.stdin.read()}))')
      curl -s --max-time 10 -X POST "$DISCORD_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$discord_msg" \
        >/dev/null 2>&1 || log "Discord notification failed (non-fatal)."
      log "Discord notification sent."
    fi
    ;;
  none|*)
    ;;
esac

# --- Sync to dashboard viewer ---
SYNC_SCRIPT="$SCRIPT_DIR/hugr-solve-sync.sh"
if [[ -x "$SYNC_SCRIPT" ]]; then
  SYNC_OUT=$(bash "$SYNC_SCRIPT" 2>&1)
  if [[ $? -eq 0 ]]; then
    log "Dashboard synced. $SYNC_OUT"
  else
    log "Dashboard sync failed (non-fatal): $SYNC_OUT"
  fi
fi

log "=== Hugr Solve complete ==="

rm -f "$TRANSCRIPT_JSON"
