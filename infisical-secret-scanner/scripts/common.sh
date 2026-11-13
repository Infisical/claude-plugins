# Shared by the plugin's scripts. Source it; don't run it.

INSTALL_COMMAND="/infisical-secret-scanner:install-cli"
CLI_DOCS_URL="https://infisical.com/docs/cli/overview"

# For a UserPromptSubmit hook: ends the turn without sending the prompt, and shows the message to the user only.
# suppressOriginalPrompt keeps the prompt, which can hold a secret, out of the message.
block() {
  # Every message starts with two line breaks.
  local reason=$'\n'"$1"

  if command -v jq >/dev/null 2>&1; then
    jq -n --arg reason "$reason" \
      '{decision: "block", reason: $reason, hookSpecificOutput: {hookEventName: "UserPromptSubmit", suppressOriginalPrompt: true}}' &&
      exit 0
  else
    local json="${reason//\\/\\\\}"
    json="${json//\"/\\\"}"
    json="${json//$'\n'/\\n}"
    printf '{"decision": "block", "reason": "%s", "hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "suppressOriginalPrompt": true}}\n' "$json" &&
      exit 0
  fi
  # The JSON could not be written, for example because jq is installed but can't run. Exit code 2 also blocks the
  # prompt and shows stderr to the user only.
  printf '%s\n' "$reason" >&2
  exit 2
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  else
    shasum -a 256
  fi | cut -d ' ' -f 1
}
