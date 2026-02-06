#!/usr/bin/env bash
# daily.dev Agent Status Hook — LOCAL DEV VERSION
# Tracks state transitions per session. Only sends on state changes.
# Debounce: skips sending if same state was sent <2s ago.

API_URL="https://localhost:5002/api/agent-status"

HOOK_TYPE="${1:-pre}"
INPUT=$(cat)

PROJECT=$(basename "$(pwd)" 2>/dev/null || echo "unknown")

if command -v jq &>/dev/null; then
  TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
  SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
else
  TOOL_NAME=$(echo "$INPUT" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
  SESSION_ID=$(echo "$INPUT" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
fi

# Marker file stores: "<state> <epoch_seconds>"
MARKER="/tmp/dailydev-hook-${SESSION_ID}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

read_state() {
  awk '{print $1}' "$MARKER" 2>/dev/null || echo "none"
}

read_time() {
  awk '{print $2}' "$MARKER" 2>/dev/null || echo "0"
}

write_marker() {
  echo "$1 $(date +%s)" > "$MARKER"
}

should_debounce() {
  local new_state="$1"
  local current_state
  current_state=$(read_state)
  local last_time
  last_time=$(read_time)
  local now
  now=$(date +%s)

  # State changes always send immediately
  if [ "$new_state" != "$current_state" ]; then
    return 1
  fi

  # Same state: debounce if <2s since last send
  local elapsed=$(( now - last_time ))
  if [ "$elapsed" -lt 2 ]; then
    return 0
  fi

  return 1
}

send_status() {
  local status="$1"
  local task="$2"
  local message="$3"
  curl -sk -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -d "{\"agents\":[{\"name\":\"claude-code\",\"session\":\"$SESSION_ID\",\"project\":\"$PROJECT\",\"status\":\"$status\",\"task\":\"$task\",\"message\":\"$message\",\"timestamp\":\"$TIMESTAMP\"}]}" \
    &>/dev/null &
}

CURRENT=$(read_state)

case "$HOOK_TYPE" in
  pre)
    if [ "$TOOL_NAME" = "AskUserQuestion" ]; then
      if should_debounce "waiting"; then
        exit 0
      fi
      write_marker "waiting"
      send_status "waiting" "Waiting for your response" "Agent asked a question"
    else
      if should_debounce "working"; then
        exit 0
      fi
      write_marker "working"
      if [ "$CURRENT" = "none" ]; then
        send_status "working" "Started" "Agent session started"
      else
        send_status "working" "Working" "Agent resumed"
      fi
    fi
    ;;
  post)
    if [ "$TOOL_NAME" = "AskUserQuestion" ]; then
      write_marker "working"
      send_status "working" "Working" "User responded"
    fi
    ;;
  notification)
    if should_debounce "waiting"; then
      exit 0
    fi
    write_marker "waiting"
    send_status "waiting" "Waiting for your input" "Agent needs your attention"
    ;;
  stop)
    write_marker "completed"
    send_status "completed" "Completed" "Agent finished"
    ;;
  *)
    exit 0
    ;;
esac

exit 0
