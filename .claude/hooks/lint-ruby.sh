#!/bin/bash
input=$(cat)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')

# Only lint Ruby files
if [[ ! "$file_path" =~ \.rb$ ]]; then
  exit 0
fi

# Only lint if file exists (wasn't deleted)
if [[ ! -f "$file_path" ]]; then
  exit 0
fi

output=""

# Run rubocop
rubocop_out=$(bundle exec rubocop --format simple "$file_path" 2>&1)
if [[ $? -ne 0 ]]; then
  output+="RuboCop issues:\n$rubocop_out\n\n"
fi

# Run reek
reek_out=$(bundle exec reek "$file_path" 2>&1)
if [[ $? -ne 0 ]]; then
  output+="Reek issues:\n$reek_out\n\n"
fi

if [[ -n "$output" ]]; then
  jq -n --arg reason "$output" '{"decision": "block", "reason": $reason}'
  exit 0
fi
