#!/usr/bin/env bash
# =============================================================================
# parley-analyze.sh - Post-hoc analysis of Parley sessions
# =============================================================================
#
# Analyze a recorded Parley conversation session.
#
# Usage:
#   ./scripts/parley-analyze.sh <session-id> [analysis-type]
#
# Analysis types:
#   summary      Compress full conversation into key points (default)
#   positions    Extract each agent's stance on key topics
#   conflicts    Identify disagreements and root causes
#   consensus    Find areas of agreement across agents
#   timeline     Show how positions evolved across rounds
#   all          Run all analyses
#
# Examples:
#   ./scripts/parley-analyze.sh 2026-05-08-103000-should-we-pivot
#   ./scripts/parley-analyze.sh 2026-05-08-103000-should-we-pivot conflicts
#   ./scripts/parley-analyze.sh 2026-05-08-103000-should-we-pivot all
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SESSIONS_DIR="$ROOT/sessions"

# === Parse Arguments ===
SESSION_ID="${1:-}"
ANALYSIS="${2:-summary}"

usage() {
  echo "Usage: ./scripts/parley-analyze.sh <session-id> [analysis-type]"
  echo ""
  echo "Analysis types: summary, positions, conflicts, consensus, timeline, all"
  echo ""
  echo "Available sessions:"
  for d in "$SESSIONS_DIR"/*/; do
    if [[ -f "$d/session.json" ]]; then
      sid="$(basename "$d")"
      topic="$(jq -r '.topic // "untitled"' "$d/session.json" 2>/dev/null | head -c 60)"
      echo "  $sid"
      echo "    $topic"
    fi
  done
  exit 0
}

if [[ -z "$SESSION_ID" ]]; then
  usage
fi

SESSION_DIR="$SESSIONS_DIR/$SESSION_ID"
SESSION_FILE="$SESSION_DIR/session.json"
ANALYSIS_FILE="$SESSION_DIR/analysis.md"

if [[ ! -f "$SESSION_FILE" ]]; then
  echo "ERROR: Session not found: $SESSION_FILE" >&2
  echo "Run with no arguments to list available sessions." >&2
  exit 1
fi

for cmd in jq curl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is required." >&2
    exit 1
  fi
done

# === Load Session Metadata ===
TOPIC="$(jq -r '.topic // "Untitled"' "$SESSION_FILE")"
PANEL="$(jq -r '.panel // "unknown"' "$SESSION_FILE")"
ROUNDS="$(jq -r '.rounds_total // "?"' "$SESSION_FILE")"
MESSAGE_COUNT="$(jq '.messages | length' "$SESSION_FILE")"
AGENT_NAMES="$(jq -r '.agents[].name' "$SESSION_FILE" | tr '\n' ', ' | sed 's/, $//')"
CREATED="$(jq -r '.created // "?"' "$SESSION_FILE")"

echo "════════════════════════════════════════════"
echo "  Parley Analysis"
echo "════════════════════════════════════════════"
echo "  Session: $SESSION_ID"
echo "  Topic:   $TOPIC"
echo "  Agents:  $AGENT_NAMES"
echo "  Rounds:  $ROUNDS  |  Messages: $MESSAGE_COUNT"
echo "  Date:    $CREATED"
echo ""

# === Analysis Functions ===

analyze_summary() {
  echo "## Session Summary"
  echo ""
  echo "**Topic:** $TOPIC"
  echo "**Panel:** $PANEL"
  echo "**Agents:** $AGENT_NAMES"
  echo "**Rounds:** $ROUNDS completed"
  echo "**Total exchanges:** $MESSAGE_COUNT"
  echo ""
  
  # Per-agent stats
  echo "### Agent Activity"
  echo ""
  echo "| Agent | Messages | Avg Latency | Avg Length |"
  echo "|-------|----------|-------------|------------|"
  
  jq -r '.agents[].name' "$SESSION_FILE" | while read -r name; do
    count=$(jq "[.messages[] | select(.agent_name == \"$name\")] | length" "$SESSION_FILE")
    avg_latency=$(jq "[.messages[] | select(.agent_name == \"$name\") | (.latency_ms // (.latency_s * 1000))] | add / length | floor" "$SESSION_FILE" 2>/dev/null || echo "0")
    avg_len=$(jq "[.messages[] | select(.agent_name == \"$name\") | .content | length] | add / length | floor" "$SESSION_FILE" 2>/dev/null || echo "0")
    printf "| %s | %d | %dms | %d chars |\n" "$name" "$count" "$avg_latency" "$avg_len"
  done
  
  echo ""
  
  # Round-by-round message count
  echo "### Round Activity"
  echo ""
  jq -r '.messages[].round' "$SESSION_FILE" 2>/dev/null | sort -n | uniq -c | while read -r count round; do
    echo "- **Round $round:** $count messages"
  done
  
  echo ""
}

analyze_positions() {
  echo "## Agent Positions"
  echo ""
  
  jq -r '.agents[].name' "$SESSION_FILE" | while read -r name; do
    echo "### $name"
    
    # Get all messages from this agent
    first_msg=$(jq -r "[.messages[] | select(.agent_name == \"$name\")] | first.content // \"\"" "$SESSION_FILE" | head -c 300)
    last_msg=$(jq -r "[.messages[] | select(.agent_name == \"$name\")] | last.content // \"\"" "$SESSION_FILE" | head -c 300)
    
    echo ""
    echo "**First position:**"
    echo "\"${first_msg}...\""
    echo ""
    echo "**Final position:**"
    echo "\"${last_msg}...\""
    echo ""
    
    # Check if position evolved
    if [[ "$first_msg" != "$last_msg" ]]; then
      echo "-> **Evolution detected**"
    fi
    echo ""
  done
}

analyze_conflicts() {
  echo "## Conflicts & Disagreements"
  echo ""
  
  # Find explicit disagreement markers in messages
  disagreement_patterns=("disagree" "however" "but" "on the contrary" "i disagree" "that's wrong" 
                         "mistaken" "overlook" "fails to" "problem is" "issue is" "actually"
                         "incorrect" "not convinced" "push back" "hold on" "wait")
  
  local found=false
  
  for pattern in "${disagreement_patterns[@]}"; do
    matches=$(jq -r ".messages[] | select(.content | test(\"(?i)$pattern\")) | \"[\(.agent_name) R\(.round)]: \(.content | gsub(\"\\n\"; \" \") | .[0:200])...\"" "$SESSION_FILE" 2>/dev/null)
    
    if [[ -n "$matches" ]]; then
      echo "**Pattern: \"$pattern\"**"
      echo ""
      echo "$matches" | while IFS= read -r line; do
        echo "- $line"
      done
      echo ""
      found=true
    fi
  done
  
  if [[ "$found" == false ]]; then
    echo "No explicit disagreement markers found."
    echo "Note: this is a simple pattern match, not deep semantic analysis."
    echo ""
  fi
  
  echo "**Hint:** For deeper conflict analysis, read the transcript directly:"
  echo "  $SESSION_DIR/transcript.md"
  echo ""
}

analyze_consensus() {
  echo "## Consensus & Agreement"
  echo ""
  
  # Find agreement markers
  agreement_patterns=("agree" "correct" "right" "yes" "exactly" "good point" 
                       "i agree" "makes sense" "that's true" "absolutely")
  
  local found=false
  
  for pattern in "${agreement_patterns[@]}"; do
    matches=$(jq -r ".messages[] | select(.content | test(\"(?i)$pattern\")) | \"[\(.agent_name) R\(.round)]: \(.content | gsub(\"\\n\"; \" \") | .[0:200])...\"" "$SESSION_FILE" 2>/dev/null)
    
    if [[ -n "$matches" ]]; then
      echo "**Pattern: \"$pattern\"**"
      echo ""
      echo "$matches" | while IFS= read -r line; do
        echo "- $line"
      done
      echo ""
      found=true
    fi
  done
  
  if [[ "$found" == false ]]; then
    echo "No explicit agreement markers found."
    echo ""
  fi
}

analyze_timeline() {
  echo "## Timeline: Position Evolution"
  echo ""
  
  echo "| Round | Agent | Turn Start | Key Point |"
  echo "|-------|-------|------------|-----------|"
  
  jq -c '.messages[]' "$SESSION_FILE" | while IFS= read -r msg; do
    round=$(echo "$msg" | jq -r '.round')
    name=$(echo "$msg" | jq -r '.agent_name')
    content=$(echo "$msg" | jq -r '.content')
    
    # Extract first sentence as key point
    first_sentence=$(echo "$content" | sed 's/\. /.|/g' | cut -d'|' -f1 | head -c 150)
    
    printf "| %d | %s | %s | %s |\n" "$round" "$name" "$first_sentence..."
  done
  
  echo ""
}

# === Run Analysis ===
run_all=false
case "$ANALYSIS" in
  summary)    analyze_summary ;;
  positions)  analyze_positions ;;
  conflicts)  analyze_conflicts ;;
  consensus)  analyze_consensus ;;
  timeline)   analyze_timeline ;;
  all)        run_all=true ;;
  *)
    echo "ERROR: Unknown analysis type: $ANALYSIS" >&2
    echo "Valid types: summary, positions, conflicts, consensus, timeline, all" >&2
    exit 1
    ;;
esac

if [[ "$run_all" == true ]]; then
  {
    echo "# Parley Analysis: $TOPIC"
    echo ""
    echo "**Session:** $SESSION_ID | **Date:** $CREATED"
    echo ""
    echo "---"
    echo ""
    echo "## Summary"
    echo ""
    echo "**Topic:** $TOPIC  "
    echo "**Panel:** $PANEL  "
    echo "**Agents:** $AGENT_NAMES  "
    echo "**Rounds:** $ROUNDS completed  "
    echo "**Total messages:** $MESSAGE_COUNT"
    echo ""
    
    echo "### Per-Agent Stats"
    echo ""
    echo "| Agent | Messages | Avg Latency | Avg Length |"
    echo "|-------|----------|-------------|------------|"
    
    jq -r '.agents[].name' "$SESSION_FILE" | while read -r name; do
      count=$(jq "[.messages[] | select(.agent_name == \"$name\")] | length" "$SESSION_FILE")
      avg_latency=$(jq "[.messages[] | select(.agent_name == \"$name\") | (.latency_ms // (.latency_s * 1000))] | add / length | floor" "$SESSION_FILE" 2>/dev/null || echo "0")
      avg_len=$(jq "[.messages[] | select(.agent_name == \"$name\") | .content | length] | add / length | floor" "$SESSION_FILE" 2>/dev/null || echo "0")
      printf "| %s | %d | %dms | %d chars |\n" "$name" "$count" "$avg_latency" "$avg_len"
    done
    
    echo ""
    echo "---"
    echo ""
    
    analyze_positions
    echo "---"
    echo ""
    analyze_conflicts
    echo "---"
    echo ""
    analyze_consensus
    echo "---"
    echo ""
    analyze_timeline
    
    echo "---"
    echo ""
    echo "**Raw data:** \`$SESSION_DIR/session.json\`"
    echo "**Transcript:** \`$SESSION_DIR/transcript.md\`"
  } > "$ANALYSIS_FILE"
  
  echo "  Full analysis written to: $ANALYSIS_FILE"
  echo ""
  # Also print to stdout
  analyze_summary
  analyze_positions
  analyze_conflicts
  analyze_consensus
  analyze_timeline
else
  # Single analysis --- run and collect output
  analysis_output_file="$SESSION_DIR/analysis.md"
  {
    echo "# Parley Analysis ($ANALYSIS): $TOPIC"
    echo ""
    echo "**Session:** $SESSION_ID | **Date:** $CREATED"
    echo ""
    echo "---"
    echo ""
    
    case "$ANALYSIS" in
      summary)    analyze_summary ;;
      positions)  analyze_positions ;;
      conflicts)  analyze_conflicts ;;
      consensus)  analyze_consensus ;;
      timeline)   analyze_timeline ;;
    esac
    
    echo "---"
    echo ""
    echo "**Raw data:** \`$SESSION_DIR/session.json\`"
    echo "**Transcript:** \`$SESSION_DIR/transcript.md\`"
  } > "$analysis_output_file"
  
  echo "  Analysis saved: $analysis_output_file"
  echo ""
fi

echo "────────────────────────────────────────────"
echo "  View transcript:  $SESSION_DIR/transcript.md"
echo "  View session:     less $SESSION_FILE"
echo "────────────────────────────────────────────"
