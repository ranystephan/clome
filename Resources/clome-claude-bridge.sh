#!/bin/bash
# Clome <-> Claude Code context bridge
# This script is configured as Claude Code's statusLine command.
# It reads the JSON status data from stdin, extracts context info,
# writes it to a temp file for Clome to read, then passes through
# to the original status line script (if any).

CLOME_DIR="/tmp/clome-claude-context"
mkdir -p "$CLOME_DIR"

# Read stdin (JSON from Claude Code)
INPUT=$(cat)

# Extract key fields with jq (falls back gracefully if jq not available)
if command -v jq &>/dev/null; then
    SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
    CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
    USED_PCT=$(echo "$INPUT" | jq -r '.context_window.used_percentage // empty')
    REMAINING_PCT=$(echo "$INPUT" | jq -r '.context_window.remaining_percentage // empty')
    CONTEXT_SIZE=$(echo "$INPUT" | jq -r '.context_window.context_window_size // empty')
    INPUT_TOKENS=$(echo "$INPUT" | jq -r '.context_window.total_input_tokens // empty')
    OUTPUT_TOKENS=$(echo "$INPUT" | jq -r '.context_window.total_output_tokens // empty')
    MODEL=$(echo "$INPUT" | jq -r '.model.display_name // empty')
    COST=$(echo "$INPUT" | jq -r '.cost.total_cost_usd // empty')

    # Write context data for Clome to read
    if [ -n "$SESSION_ID" ]; then
        cat > "$CLOME_DIR/$SESSION_ID.json" << CLOME_EOF
{"session_id":"$SESSION_ID","cwd":"$CWD","used_percentage":${USED_PCT:-null},"remaining_percentage":${REMAINING_PCT:-null},"context_window_size":${CONTEXT_SIZE:-null},"input_tokens":${INPUT_TOKENS:-null},"output_tokens":${OUTPUT_TOKENS:-null},"model":"$MODEL","cost":${COST:-null},"timestamp":$(date +%s)}
CLOME_EOF
    fi
fi

# Pass through to original status line script (if configured)
ORIGINAL_SCRIPT="__ORIGINAL_STATUSLINE__"
if [ -n "$ORIGINAL_SCRIPT" ] && [ "$ORIGINAL_SCRIPT" != "__ORIGINAL_STATUSLINE__" ] && [ -x "$ORIGINAL_SCRIPT" ]; then
    echo "$INPUT" | "$ORIGINAL_SCRIPT"
elif [ -n "$ORIGINAL_SCRIPT" ] && [ "$ORIGINAL_SCRIPT" != "__ORIGINAL_STATUSLINE__" ]; then
    echo "$INPUT" | eval "$ORIGINAL_SCRIPT"
fi
