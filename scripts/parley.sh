#!/usr/bin/env bash
# =============================================================================
# parley.sh - Interactive Multi-Agent Conversation App
# =============================================================================
#
# Orchestrates real-time conversations between free AI agents. Watch them
# debate, think, and respond to each other interactively in your terminal.
#
# Usage:
#   ./scripts/parley.sh "Should we bootstrap?"      # interactive chat mode
#   ./scripts/parley.sh "Best architecture?" --panel 5-diverse
#   ./scripts/parley.sh "Topic" --rounds 5
#   ./scripts/parley.sh "Topic" --auto               # no pauses, continuous flow
#   ./scripts/parley.sh list                         # show past sessions
#   ./scripts/parley.sh replay <session-id>           # replay a past session
#
# Dependencies: jq, curl
# API key: auto-detected from OpenCode auth or OPENROUTER_API_KEY env var
# =============================================================================

set -euo pipefail

# === Paths ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PANELS_DIR="$ROOT/panels"
SESSIONS_DIR="$ROOT/sessions"

DEFAULT_PANEL="3-debate"
DEFAULT_ROUNDS=3
API_DELAY=0.5

# === Colors ===
C_RST='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_HEADER='\033[1;36m'     # bright cyan for header
C_PROMPT='\033[1;33m'     # bright yellow for prompts
C_THINKING='\033[2;33m'   # dim yellow for thinking indicator
C_SUCCESS='\033[1;32m'    # bright green for success
C_ERROR='\033[1;31m'      # bright red for errors
C_DIVIDER='\033[1;30m'    # dark gray for dividers
C_AGENTS=(
  '\033[1;36m'  # 0: bright cyan    - Facilitator
  '\033[1;32m'  # 1: bright green   - Analyst
  '\033[1;33m'  # 2: bright yellow  - Skeptic
  '\033[1;35m'  # 3: bright magenta - Creative/Strategist
  '\033[1;34m'  # 4: bright blue    - Diplomat/Historian
  '\033[1;31m'  # 5: bright red
  '\033[1;37m'  # 6: bright white
)

# === API Key Detection ===
detect_api_key() {
  if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
    return 0
  fi
  local auth_file="$HOME/.local/share/opencode/auth.json"
  if [[ -f "$auth_file" ]]; then
    local key
    key="$(jq -r '.openrouter.key // empty' "$auth_file" 2>/dev/null)"
    if [[ -n "$key" && "$key" != "null" ]]; then
      export OPENROUTER_API_KEY="$key"
      return 0
    fi
  fi
  return 1
}

# === Terminal Helpers ===
divider() {
  local char="${1:-─}"
  local width="${2:-60}"
  printf "${C_DIVIDER}%*s${C_RST}\n" "$width" '' | tr ' ' "$char"
}

clear_lines() {
  local n="${1:-1}"
  for _ in $(seq 1 "$n"); do
    printf '\033[1A\033[K'
  done
}

agent_color() {
  local idx="$1"
  local count="${#C_AGENTS[@]}"
  echo -n "${C_AGENTS[$((idx % count))]}"
}

# === Session Management ===
list_sessions() {
  echo ""
  echo -e "  ${C_HEADER}Past Parley Sessions${C_RST}"
  echo ""
  if ! ls "$SESSIONS_DIR"/*/session.json &>/dev/null; then
    echo "  No sessions yet. Start one with:"
    echo "    ./scripts/parley.sh \"your topic\""
    echo ""
    exit 0
  fi
  printf "  %-35s %-50s %s\n" "SESSION ID" "TOPIC" "MESSAGES"
  echo "  $(printf '%0.s─' {1..95})"
  for d in "$SESSIONS_DIR"/*/; do
    if [[ -f "$d/session.json" ]]; then
      sid="$(basename "$d")"
      topic="$(jq -r '.topic // "untitled"' "$d/session.json" 2>/dev/null | head -c 48)"
      count="$(jq '.messages | length' "$d/session.json" 2>/dev/null || echo "?")"
      printf "  ${C_BOLD}%-35s${C_RST} %-50s %s\n" "$sid" "$topic" "$count"
    fi
  done
  echo ""
}

replay_session() {
  local session_id="$1"
  local session_dir="$SESSIONS_DIR/$session_id"
  local session_file="$session_dir/session.json"

  if [[ ! -f "$session_file" ]]; then
    echo -e "  ${C_ERROR}Session not found: $session_id${C_RST}"
    exit 1
  fi

  local topic="$(jq -r '.topic // "untitled"' "$session_file")"
  local agents="$(jq -r '.agents[].name' "$session_file" | tr '\n' ', ' | sed 's/, $//')"
  local rounds="$(jq -r '.rounds_total' "$session_file")"
  local msg_count="$(jq '.messages | length' "$session_file")"

  clear
  divider "═" 70
  printf "  ${C_HEADER}%-68s${C_RST}\n" "PARLEY REPLAY"
  divider "═" 70
  echo ""
  echo -e "  ${C_BOLD}Topic:${C_RST}  $topic"
  echo -e "  ${C_BOLD}Agents:${C_RST} $agents"
  echo -e "  ${C_BOLD}Rounds:${C_RST} $rounds  |  Messages: $msg_count"
  echo ""

  local current_round=0
  while IFS= read -r msg; do
    r="$(echo "$msg" | jq -r '.round')"
    name="$(echo "$msg" | jq -r '.agent_name')"
    idx="$(echo "$msg" | jq -r '.agent_index')"
    content="$(echo "$msg" | jq -r '.content')"
    latency_s="$(echo "$msg" | jq -r '.latency_s // empty' 2>/dev/null || true)"
    latency_ms="$(echo "$msg" | jq -r '.latency_ms // empty' 2>/dev/null || true)"
    model="$(echo "$msg" | jq -r '.model' | sed 's|.*/||; s|:free||')"
    color="$(agent_color "$idx")"

    # Show latency in appropriate unit
    local lat_display
    if [[ -n "$latency_s" && "$latency_s" != "null" ]]; then
      lat_display="${latency_s}s"
    elif [[ -n "$latency_ms" && "$latency_ms" != "null" ]]; then
      lat_display="${latency_ms}ms"
    else
      lat_display="?"
    fi

    if [[ "$r" -ne "$current_round" ]]; then
      current_round="$r"
      echo ""
      divider "─" 70
      echo -e "  ${C_BOLD}Round $current_round${C_RST}"
      divider "─" 70
      echo ""
    fi

    echo ""
    echo -e "  ${color}◉ ${name}${C_RST}  ${C_DIM}(${lat_display} via ${model})${C_RST}"
    echo ""
    echo "$content" | while IFS= read -r line; do
      echo -e "    ${color}│${C_RST} $line"
    done
    echo ""

    # Wait for user input
    echo ""
    echo -ne "  ${C_PROMPT}[Enter]${C_RST} next  ${C_DIM}│${C_RST} ${C_PROMPT}[q]${C_RST} quit  "
    key=""
    if [[ -c /dev/tty ]]; then
      read -r -n1 key </dev/tty 2>/dev/null || true
    else
      read -r -n1 key 2>/dev/null || true
    fi
    echo ""
    if [[ "$key" == "q" ]]; then
      echo ""
      echo -e "  ${C_DIM}Replay stopped.${C_RST}"
      return 0
    fi
  done < <(jq -c '.messages[]' "$session_file")

  echo ""
  divider "═" 70
  echo -e "  ${C_SUCCESS}End of replay — $msg_count messages${C_RST}"
  divider "═" 70
  echo ""
  exit 0
}

# === Main Conversation Flow ===

# Header display
show_header() {
  local topic="$1"
  local panel_name="$2"
  local panel_desc="$3"
  local rounds="$4"
  local agent_count="$5"

  clear
  divider "═" 70
  printf "  ${C_HEADER}%-68s${C_RST}\n" "PARLEY — Multi-Agent Conversation"
  divider "═" 70
  echo ""
  echo -e "  ${C_BOLD}Topic:${C_RST}  $topic"
  echo -e "  ${C_BOLD}Panel:${C_RST}  $panel_name — $panel_desc"
  echo -e "  ${C_BOLD}Rounds:${C_RST} $rounds  |  Agents: $agent_count"
  echo ""
  divider "─" 70
  echo ""
}

show_round_header() {
  local round="$1"
  local total="$2"
  echo ""
  echo -e "  ${C_BOLD}─── Round $round of $total ───${C_RST}"
  echo ""
}

show_thinking() {
  local name="$1"
  printf "\r  ${C_THINKING}⏳ %s is thinking...${C_RST}" "$name"
}

clear_thinking() {
  printf "\r\033[K"
}

show_message() {
  local name="$1"
  local content="$2"
  local agent_idx="$3"
  local latency="$4"
  local model="$5"
  local color="$(agent_color "$agent_idx")"

  echo -e "  ${color}◉ ${name}${C_RST}  ${C_DIM}(${latency}s via ${model})${C_RST}"
  echo ""

  # Print message with agent-colored vertical bars
  echo "$content" | while IFS= read -r line; do
    echo -e "  ${color}│${C_RST} $line"
  done
  echo ""
}

prompt_continue() {
  local auto_mode="$1"
  if [[ "$auto_mode" == "true" ]]; then
    sleep 1.5
    return
  fi

  echo -ne "  ${C_PROMPT}[Enter]${C_RST} next  ${C_DIM}│${C_RST} ${C_PROMPT}[a]${C_RST} auto  ${C_DIM}│${C_RST} ${C_PROMPT}[q]${C_RST} quit  "
  read -r -n1 key
  echo ""
  case "$key" in
    q|Q)
      echo ""
      echo -e "  ${C_DIM}Session stopped. Transcript saved.${C_RST}"
      exit 0
      ;;
    a|A)
      echo ""
      echo -e "  ${C_DIM}Auto-play mode (press Ctrl+C to stop)${C_RST}"
      echo ""
      sleep 0.5
      return 1  # signal to switch to auto
      ;;
    *)
      return 0
      ;;
  esac
}

# Build history messages for API context
build_history_messages() {
  local session_file="$1"
  local history_json

  history_json="$(jq -r '.messages[] | {role: "assistant", name: .agent_name, content: .content}' "$session_file" 2>/dev/null | jq -s '. // []')"

  local count
  count="$(echo "$history_json" | jq 'length')"
  if [[ "$count" -gt 50 ]]; then
    history_json="$(echo "$history_json" | jq '.[-50:]')"
  fi

  echo "${history_json:-[]}"
}

# Call one agent via OpenRouter
call_agent() {
  local agents_json="$1"
  local agent_index="$2"
  local round="$3"
  local rounds_total="$4"
  local topic="$5"
  local history_json="$6"

  local name="$(echo "$agents_json" | jq -r ".[$agent_index].name")"
  local model="$(echo "$agents_json" | jq -r ".[$agent_index].model")"
  local persona="$(echo "$agents_json" | jq -r ".[$agent_index].persona")"
  local temperature="$(echo "$agents_json" | jq -r ".[$agent_index].temperature // 0.7")"
  local max_tokens="$(echo "$agents_json" | jq -r ".[$agent_index].max_tokens // 800")"

  # Build messages
  local messages
  messages="$(jq -n --arg p "$persona" '[{"role": "system", "content": $p}]')"

  local round_msg
  if [[ "$round" -eq 1 && "$agent_index" -eq 0 ]]; then
    round_msg="Topic: $topic\n\nRound 1 of $rounds_total. You are $name, speaking first. Set up the discussion."
  elif [[ "$round" -eq 1 ]]; then
    round_msg="Topic: $topic\n\nRound 1 of $rounds_total. Respond to what has been said so far."
  else
    round_msg="Topic: $topic\n\nRound $round of $rounds_total. Continue the discussion. You've seen everything said so far. Advance the conversation."
  fi

  messages="$(echo "$messages" | jq --arg m "$round_msg" '. + [{"role": "user", "content": $m}]')"

  if [[ "$history_json" != "[]" && -n "$history_json" ]]; then
    messages="$(echo "$messages" | jq --argjson h "$history_json" '. + $h')"
  fi

  local request
  request="$(jq -n \
    --arg model "$model" \
    --argjson messages "$messages" \
    --argjson temperature "$temperature" \
    --argjson max_tokens "$max_tokens" \
    '{
      model: $model,
      messages: $messages,
      temperature: $temperature,
      max_tokens: $max_tokens
    }')"

  # Call API
  local start_time end_time elapsed response content error_msg

  start_time="$(date +%s%N 2>/dev/null || date +%s)"

  response="$(echo "$request" | curl -sS \
    https://openrouter.ai/api/v1/chat/completions \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" \
    -H "Content-Type: application/json" \
    -H "HTTP-Referer: https://github.com/B67687/agentic-workflows" \
    -H "X-Title: agentic-workflows parley" \
    -d @- 2>/dev/null || echo '{"error": {"message": "curl failed"}}')"

  end_time="$(date +%s%N 2>/dev/null || date +%s)"

  if [[ "$(uname)" == "Linux" ]]; then
    elapsed="$(echo "scale=1; ($end_time - $start_time) / 1000000000" | bc 2>/dev/null || echo "?")"
  else
    elapsed="$(echo "scale=1; $end_time - $start_time" | bc 2>/dev/null || echo "?")"
  fi

  content="$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)"
  if [[ -z "$content" ]]; then
    error_msg="$(echo "$response" | jq -r '.error.message // "unknown error"' 2>/dev/null)"
    [[ "$error_msg" == "null" ]] && error_msg="empty response"
    content="[ERROR: $error_msg]"
  fi

  jq -n \
    --argjson round "$round" \
    --argjson agent_index "$agent_index" \
    --arg agent_name "$name" \
    --arg model "$model" \
    --arg content "$content" \
    --arg elapsed "$elapsed" \
    '{
      round: $round,
      agent_index: $agent_index,
      agent_name: $agent_name,
      model: $model,
      timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      content: $content,
      latency_s: ($elapsed | tonumber)
    }'
}

# === Usage ===
usage() {
  echo "Usage: ./scripts/parley.sh <topic> [options]"
  echo ""
  echo "Options:"
  echo "  --panel NAME    Agent panel (default: $DEFAULT_PANEL)"
  echo "  --rounds N      Conversation rounds (default: $DEFAULT_ROUNDS)"
  echo "  --auto          Continuous play without pauses"
  echo "  --dry-run       Show lineup without calling APIs"
  echo "  --help, -h      Show this help"
  echo ""
  echo "Subcommands:"
  echo "  list            Show past sessions"
  echo "  replay <id>     Replay a past session interactively"
  echo ""
  echo "Panels:"
  if ls "$PANELS_DIR"/*.json &>/dev/null; then
    for f in "$PANELS_DIR"/*.json; do
      name="$(basename "$f" .json)"
      desc="$(jq -r '.description // ""' "$f" 2>/dev/null)"
      echo "  $name  - $desc"
    done 2>/dev/null
  fi
  exit 0
}

# === Early exits (no API key needed) ===
SUBCOMMAND="${1:-}"

case "$SUBCOMMAND" in
  help|-h|--help)
    usage
    ;;
  list|ls|sessions)
    list_sessions
    exit 0
    ;;
  replay|view|show)
    replay_session "${2:-}"
    exit 0
    ;;
esac

if [[ $# -eq 0 ]]; then
  usage
fi

# === Parse Arguments ===
TOPIC=""
PANEL_NAME="$DEFAULT_PANEL"
ROUNDS="$DEFAULT_ROUNDS"
AUTO_MODE=false
DRY_RUN=false

TOPIC="$1"
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --panel)
      PANEL_NAME="${2:-}"
      shift 2
      ;;
    --rounds)
      ROUNDS="${2:-}"
      shift 2
      ;;
    --auto)
      AUTO_MODE=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help|-h)
      usage
      ;;
    *)
      echo -e "${C_ERROR}ERROR: Unknown option: $1${C_RST}" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# === Validate Panel ===
PANEL_FILE="$PANELS_DIR/$PANEL_NAME.json"
if [[ ! -f "$PANEL_FILE" ]]; then
  echo -e "${C_ERROR}ERROR: Panel not found: $PANEL_NAME${C_RST}" >&2
  echo "Available panels:" >&2
  for f in "$PANELS_DIR"/*.json; do
    echo "  $(basename "$f" .json)" >&2
  done
  exit 1
fi

for cmd in jq curl bc; do
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${C_ERROR}ERROR: $cmd is required.${C_RST}" >&2
    exit 1
  fi
done

# Load panel info
AGENTS_JSON="$(jq '.agents' "$PANEL_FILE")"
AGENT_COUNT="$(echo "$AGENTS_JSON" | jq 'length')"
PANEL_DESC="$(jq -r '.description // "Conversation panel"' "$PANEL_FILE")"

# === Dry run: show lineup and exit ===
if [[ "$DRY_RUN" == true ]]; then
  echo ""
  echo -e "  ${C_HEADER}Dry Run — Panel: $PANEL_NAME${C_RST}"
  echo ""
  printf "  %-18s %-12s %s\n" "AGENT" "ROLE" "MODEL"
  echo "  $(printf '%0.s─' {1..65})"
  for i in $(seq 0 $((AGENT_COUNT - 1))); do
    name="$(echo "$AGENTS_JSON" | jq -r ".[$i].name")"
    role="$(echo "$AGENTS_JSON" | jq -r ".[$i].role")"
    model="$(echo "$AGENTS_JSON" | jq -r ".[$i].model" | sed 's|:free||')"
    printf "  %-18s %-12s %s\n" "$name" "($role)" "$model"
  done
  echo ""
  echo -e "  ${C_DIM}Rounds: $ROUNDS | Total turns: $((AGENT_COUNT * ROUNDS))${C_RST}"
  echo ""
  echo -e "  ${C_DIM}Run without --dry-run to start the conversation.${C_RST}"
  echo ""
  exit 0
fi

# === API Key (needed for live conversations) ===
if ! detect_api_key; then
  echo -e "${C_ERROR}ERROR: No OpenRouter API key found.${C_RST}"
  echo ""
  echo "I checked:"
  echo "  1. OPENROUTER_API_KEY env var"
  echo "  2. ~/.local/share/opencode/auth.json (openrouter key)"
  echo ""
  echo "Options:"
  echo "  export OPENROUTER_API_KEY='sk-or-v1-...'"
  echo "  Or add an openrouter key to your OpenCode auth."
  exit 1
fi

# === Create Session ===
slug="$(echo "$TOPIC" \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' \
  | head -c 50)"
SESSION_ID="$(date -u +%Y-%m-%d-%H%M%S)-$slug"
SESSION_DIR="$SESSIONS_DIR/$SESSION_ID"
mkdir -p "$SESSION_DIR"

SESSION_FILE="$SESSION_DIR/session.json"
TRANSCRIPT_FILE="$SESSION_DIR/transcript.md"

created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -n \
  --arg session_id "$SESSION_ID" \
  --arg topic "$TOPIC" \
  --arg panel "$PANEL_NAME" \
  --arg panel_file "$PANEL_FILE" \
  --arg created "$created" \
  --argjson rounds "$ROUNDS" \
  --argjson agent_count "$AGENT_COUNT" \
  --argjson agents "$AGENTS_JSON" \
  '{
    session_id: $session_id,
    topic: $topic,
    panel: $panel,
    panel_file: $panel_file,
    created: $created,
    rounds_total: $rounds,
    rounds_completed: 0,
    agent_count: $agent_count,
    agents: $agents,
    messages: [],
    summary: null
  }' > "$SESSION_FILE"

# === Conversation Loop ===
show_header "$TOPIC" "$PANEL_NAME" "$PANEL_DESC" "$ROUNDS" "$AGENT_COUNT"

for round in $(seq 1 "$ROUNDS"); do
  show_round_header "$round" "$ROUNDS"

  for agent_i in $(seq 0 $((AGENT_COUNT - 1))); do
    name="$(echo "$AGENTS_JSON" | jq -r ".[$agent_i].name")"
    model_short="$(echo "$AGENTS_JSON" | jq -r ".[$agent_i].model" | sed 's|.*/||; s|:free||')"

    # Show thinking indicator
    show_thinking "$name"

    # Build context and call agent
    prev_messages="$(build_history_messages "$SESSION_FILE")"
    result="$(call_agent "$AGENTS_JSON" "$agent_i" "$round" "$ROUNDS" "$TOPIC" "$prev_messages")" || {
      clear_thinking
      echo -e "  ${C_ERROR}✗ $name — API call failed${C_RST}"
      if [[ "$AUTO_MODE" == false ]]; then
        prompt_continue "false" || AUTO_MODE=true
      fi
      continue
    }

    latency="$(echo "$result" | jq -r '.latency_s')"
    content="$(echo "$result" | jq -r '.content')"

    # Save message
    tmp="$(mktemp)"
    jq --argjson msg "$result" '.messages += [$msg]' "$SESSION_FILE" > "$tmp" && mv "$tmp" "$SESSION_FILE"

    # Clear thinking and show message
    clear_thinking
    show_message "$name" "$content" "$agent_i" "$latency" "$model_short"

    # Rate-limit delay
    sleep "$API_DELAY"

    # Interactive prompt (skip in auto mode)
    if [[ "$AUTO_MODE" == false ]]; then
      prompt_continue "false" || AUTO_MODE=true
    fi
  done

  # Update rounds completed
  tmp="$(mktemp)"
  jq --argjson round "$round" '.rounds_completed = $round' "$SESSION_FILE" > "$tmp" && mv "$tmp" "$SESSION_FILE"
done

# === Generate Transcript ===
message_count="$(jq '.messages | length' "$SESSION_FILE")"

{
  echo "# Parley Transcript: $TOPIC"
  echo ""
  panel_agents="$(jq -r '.agents | map(.name + " (" + .role + ")") | join(", ")' "$SESSION_FILE")"
  echo "**Panel:** $PANEL_NAME | **Agents:** $panel_agents"
  echo "**Rounds:** $ROUNDS | **Messages:** $message_count"
  echo "**Date:** $created"
  echo ""
  echo "---"
  echo ""

  current_round=0
  jq -c '.messages[]' "$SESSION_FILE" | while IFS= read -r msg; do
    r="$(echo "$msg" | jq -r '.round')"
    name="$(echo "$msg" | jq -r '.agent_name')"
    content="$(echo "$msg" | jq -r '.content')"
    latency="$(echo "$msg" | jq -r '.latency_s')"
    model="$(echo "$msg" | jq -r '.model' | sed 's|.*/||; s|:free||')"

    if [[ "$r" -ne "$current_round" ]]; then
      current_round="$r"
      echo ""
      echo "## Round $current_round"
      echo ""
    fi

    echo "### $name"
    echo "*${latency}s via ${model}*"
    echo ""
    echo "$content"
    echo ""
    echo "---"
    echo ""
  done
} > "$TRANSCRIPT_FILE"

# === End Screen ===
echo ""
divider "═" 70
echo -e "  ${C_SUCCESS}Conversation complete — $message_count messages${C_RST}"
divider "═" 70
echo ""
echo -e "  ${C_BOLD}Session:${C_RST}  $SESSION_ID"
echo -e "  ${C_BOLD}Saved:${C_RST}    $SESSION_DIR"
echo -e "  ${C_BOLD}View:${C_RST}     $TRANSCRIPT_FILE"
echo ""
echo -e "  ${C_DIM}Analyze:   ./scripts/parley-analyze.sh $SESSION_ID summary${C_RST}"
echo -e "  ${C_DIM}Replay:    ./scripts/parley.sh replay $SESSION_ID${C_RST}"
echo -e "  ${C_DIM}Transcript: less $TRANSCRIPT_FILE${C_RST}"
echo ""
divider "═" 70
echo ""
