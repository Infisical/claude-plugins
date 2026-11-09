#!/usr/bin/env bash
# UserPromptSubmit hook: scans the prompt on this machine with `infisical scan --pipe` and blocks it when it holds a
# secret that hasn't been allowed. It also runs /infisical:allow-secret itself, so the value given to that command is
# never sent to Claude. Nothing is sent to Infisical. Any failure blocks the prompt.

set -o pipefail

ALLOW_COMMAND="/infisical:allow-secret"
LEAK_EXIT_CODE=42
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/infisical-infisical}"
# SHA-256 hashes of the allowed secret values, one per line. The values themselves are never stored.
ALLOWLIST="$DATA_DIR/allowed-secrets"

# The scan must not reach the network: no telemetry event, no update check.
export INFISICAL_DISABLE_TELEMETRY=1 INFISICAL_DISABLE_UPDATE_CHECK=1

SCAN_CONFIG="$PLUGIN_ROOT/config/infisical-scan.toml"
[ -f "$DATA_DIR/infisical-scan.toml" ] && SCAN_CONFIG="$DATA_DIR/infisical-scan.toml"

# Ends the turn without sending the prompt, and shows the message to the user only. suppressOriginalPrompt keeps the
# prompt, which can hold a secret, out of the message.
block() {
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg reason "$1" \
      '{decision: "block", reason: $reason, hookSpecificOutput: {hookEventName: "UserPromptSubmit", suppressOriginalPrompt: true}}'
  else
    local reason="${1//\\/\\\\}"
    reason="${reason//\"/\\\"}"
    printf '{"decision": "block", "reason": "%s", "hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "suppressOriginalPrompt": true}}\n' "$reason"
  fi
  exit 0
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  else
    shasum -a 256
  fi | cut -d ' ' -f 1
}

# Usage: scan <input file> <report file>. Returns 0 for no secrets and LEAK_EXIT_CODE for secrets. It runs from the
# private folder, so files in the user's project, such as a .infisical-scan.toml, can't change the result.
scan() {
  (cd "$tmp" && infisical scan --pipe --config "$SCAN_CONFIG" --silent --no-color \
    --exit-code "$LEAK_EXIT_CODE" --report-format json --report-path "$2" <"$1" >/dev/null 2>&1)
}

scan_failed() {
  block "Infisical: the secret scan failed (exit code $1), so the prompt was not sent. Run 'infisical scan --pipe --config $SCAN_CONFIG' to see the error, and update the Infisical CLI if it is out of date."
}

is_allowed() {
  [ -f "$ALLOWLIST" ] && grep -qxF "$1" "$ALLOWLIST"
}

# Usage: allow_secret <file holding the value given to the command>
allow_secret() {
  local value_file="$1" status hash count i

  [ -s "$value_file" ] || block "Infisical: put the secret to allow after the command: $ALLOW_COMMAND <secret>"

  # The secrets the scanner finds in the value, so that a full line like TOKEN=<value> or a connection string allows
  # the same value that a scan of a prompt reports.
  scan "$value_file" "$tmp/allow-report.json"
  status=$?
  case "$status" in
    0) echo '[]' >"$tmp/allow-report.json" ;;
    "$LEAK_EXIT_CODE") ;;
    *) scan_failed "$status" ;;
  esac

  mkdir -p "$tmp/values"
  cp "$value_file" "$tmp/values/raw"
  # A value given in quotes also allows the value without them.
  jq -Rsj 'if test("\\A([\"'"'"'`]).*\\1\\z"; "s") then .[1:-1] else empty end' "$value_file" >"$tmp/values/unquoted" ||
    block "Infisical: could not read the value to allow."
  count="$(jq 'length' "$tmp/allow-report.json")" || block "Infisical: could not read the secret scan report."
  for ((i = 0; i < count; i++)); do
    jq -j ".[$i].Secret" "$tmp/allow-report.json" >"$tmp/values/found-$i" || block "Infisical: could not read the secret scan report."
  done

  mkdir -p "$DATA_DIR" && touch "$ALLOWLIST" || block "Infisical: could not save the allowed secret in $DATA_DIR."
  for value_file in "$tmp/values"/*; do
    [ -s "$value_file" ] || continue
    hash="$(sha256 <"$value_file")" || block "Infisical: could not hash the value to allow."
    is_allowed "$hash" || echo "$hash" >>"$ALLOWLIST" || block "Infisical: could not save the allowed secret in $ALLOWLIST."
  done

  # decision: block is the only way to stop a prompt without it joining the conversation, so Claude Code labels this
  # confirmation as blocked. continue: false shows a softer label but adds the typed command, secret included, to
  # what Claude sees on the next turn.
  block "Infisical: secret allowed. Prompts that contain it are no longer blocked.
Claude Code labels this as blocked because the plugin keeps the command from Claude, so the secret is never sent."
}

umask 077
tmp="$(mktemp -d)" || block "Infisical: the secret scan could not create a temporary folder, so the prompt was not sent."
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/input.json"

command -v infisical >/dev/null 2>&1 ||
  block "Infisical: the Infisical CLI is not installed, so prompts can't be scanned for secrets and are not sent. Install it: https://infisical.com/docs/cli/overview"
command -v jq >/dev/null 2>&1 ||
  block "Infisical: jq is not installed, so prompts can't be scanned for secrets and are not sent. Install it: https://jqlang.org/download"

if jq -e '(.prompt // "") | test("\\A\\s*/infisical:allow-secret(\\s|\\z)")' "$tmp/input.json" >/dev/null 2>&1; then
  jq -j '.prompt | sub("\\A\\s*/infisical:allow-secret\\s*"; "") | sub("\\s+\\z"; "")' "$tmp/input.json" >"$tmp/value.txt" ||
    block "Infisical: could not read the value to allow."
  allow_secret "$tmp/value.txt"
fi

# Written to the private folder first, so a jq failure blocks the prompt instead of scanning nothing.
jq -j '.prompt // ""' "$tmp/input.json" >"$tmp/prompt.txt" 2>/dev/null ||
  block "Infisical: could not read the prompt to scan it, so it was not sent."

scan "$tmp/prompt.txt" "$tmp/report.json"
status=$?
[ "$status" -eq 0 ] && exit 0
[ "$status" -eq "$LEAK_EXIT_CODE" ] || scan_failed "$status"

count="$(jq 'length' "$tmp/report.json")" || block "Infisical: could not read the secret scan report, so the prompt was not sent."
blocked=()
for ((i = 0; i < count; i++)); do
  hash="$(jq -j ".[$i].Secret" "$tmp/report.json" | sha256)" ||
    block "Infisical: could not read the secret scan report, so the prompt was not sent."
  is_allowed "$hash" || blocked+=("$i")
done

[ "${#blocked[@]}" -eq 0 ] && exit 0

# Only a short prefix of each secret is shown, enough to find it in the prompt.
findings="$(jq -r --argjson blocked "$(printf '%s\n' "${blocked[@]}" | jq -s '.')" '
  [.[$blocked[]]] | unique_by(.Secret) | sort_by(.StartLine, .StartColumn) | .[] |
  "  - \(.RuleID) on line \(.StartLine)" + (if (.Secret | length) >= 16 then ": \(.Secret[0:4])..." else "" end)
' "$tmp/report.json")" || block "Infisical: could not read the secret scan report, so the prompt was not sent."

block "Infisical: the prompt was not sent because it contains secrets:
$findings
Remove them and send the prompt again. To allow a value that is safe to share, run $ALLOW_COMMAND <value>."
