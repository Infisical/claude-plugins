#!/usr/bin/env bash
# UserPromptSubmit hook: scans the prompt on this machine with `infisical scan --pipe` and blocks it when it holds a
# secret that hasn't been allowed. It also runs /infisical-secret-scanner:allow-secret and
# /infisical-secret-scanner:disallow-secret itself, so the value given to those commands is never sent to Claude.
# Nothing is sent to Infisical. Any failure blocks the prompt.

set -o pipefail

ALLOW_COMMAND="/infisical-secret-scanner:allow-secret"
DISALLOW_COMMAND="/infisical-secret-scanner:disallow-secret"
LEAK_EXIT_CODE=42
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/infisical-secret-scanner-infisical}"
# SHA-256 hashes of the allowed secret values, one per line. The values themselves are never stored.
ALLOWLIST="$DATA_DIR/allowed-secrets"
LOCK="$ALLOWLIST.lock"

# The scan must not reach the network: no telemetry event, no update check.
export INFISICAL_DISABLE_TELEMETRY=1 INFISICAL_DISABLE_UPDATE_CHECK=1

SCAN_CONFIG="$PLUGIN_ROOT/config/infisical-scan.toml"
[ -f "$DATA_DIR/infisical-scan.toml" ] && SCAN_CONFIG="$DATA_DIR/infisical-scan.toml"

# Ends the turn without sending the prompt, and shows the message to the user only. suppressOriginalPrompt keeps the
# prompt, which can hold a secret, out of the message.
block() {
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg reason "$1" \
      '{decision: "block", reason: $reason, hookSpecificOutput: {hookEventName: "UserPromptSubmit", suppressOriginalPrompt: true}}' &&
      exit 0
  else
    local reason="${1//\\/\\\\}"
    reason="${reason//\"/\\\"}"
    printf '{"decision": "block", "reason": "%s", "hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "suppressOriginalPrompt": true}}\n' "$reason" &&
      exit 0
  fi
  # The JSON could not be written, for example because jq is installed but can't run. Exit code 2 also blocks the
  # prompt and shows stderr to the user only.
  echo "$1" >&2
  exit 2
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

# Takes the lock that allow_secret and disallow_secret hold while they change the allowlist, so that two sessions can't
# undo each other's changes. mkdir is atomic, so only one hook can create the lock folder.
lock_allowlist() {
  local i

  mkdir -p "$DATA_DIR" || block "Infisical: could not create $DATA_DIR, so nothing changed."
  for ((i = 0; i < 100; i++)); do
    if mkdir "$LOCK" 2>/dev/null; then
      trap 'rm -f "$ALLOWLIST.new"; rmdir "$LOCK"; rm -rf "$tmp"' EXIT
      return 0
    fi
    # The hook times out after 30 seconds, so a lock older than a minute was left by a hook that was stopped.
    [ -n "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ] && rmdir "$LOCK" 2>/dev/null
    sleep 0.1
  done
  block "Infisical: another session is changing the allowed secrets, so nothing changed. Try again."
}

# Usage: command_value <command>. When the prompt runs the command, writes the value given to it to $tmp/value.txt.
# Returns 1 when the prompt doesn't run the command.
command_value() {
  jq -e --arg command "$1" '(.prompt // "") | test("\\A\\s*" + $command + "(\\s|\\z)")' "$tmp/input.json" >/dev/null 2>&1 ||
    return 1
  jq -j --arg command "$1" '.prompt | sub("\\A\\s*" + $command + "\\s*"; "") | sub("\\s+\\z"; "")' "$tmp/input.json" >"$tmp/value.txt" ||
    block "Infisical: could not read the value given to $1."
}

# Usage: value_hashes <file holding the value given to a command>. Writes the SHA-256 hashes of the values that the
# command applies to, one per line, to $tmp/hashes.
value_hashes() {
  local value_file="$1" status count i

  # The secrets the scanner finds in the value, so that a full line like TOKEN=<value> or a connection string applies to
  # the same value that a scan of a prompt reports.
  scan "$value_file" "$tmp/value-report.json"
  status=$?
  case "$status" in
    0) echo '[]' >"$tmp/value-report.json" ;;
    "$LEAK_EXIT_CODE") ;;
    *) scan_failed "$status" ;;
  esac

  mkdir -p "$tmp/values" && cp "$value_file" "$tmp/values/raw" || block "Infisical: could not read the value."
  # A value given in quotes also applies to the value without them.
  jq -Rsj 'if test("\\A([\"'"'"'`]).*\\1\\z"; "s") then .[1:-1] else empty end' "$value_file" >"$tmp/values/unquoted" ||
    block "Infisical: could not read the value."
  count="$(jq 'length' "$tmp/value-report.json")" || block "Infisical: could not read the secret scan report."
  for ((i = 0; i < count; i++)); do
    jq -j ".[$i].Secret" "$tmp/value-report.json" >"$tmp/values/found-$i" || block "Infisical: could not read the secret scan report."
  done

  : >"$tmp/hashes"
  for value_file in "$tmp/values"/*; do
    [ -s "$value_file" ] || continue
    sha256 <"$value_file" >>"$tmp/hashes" || block "Infisical: could not hash the value."
  done
}

# Usage: allow_secret <file holding the value given to the command>
allow_secret() {
  local hash

  [ -s "$1" ] || block "Infisical: put the secret to allow after the command: $ALLOW_COMMAND <secret>"
  value_hashes "$1"

  lock_allowlist
  # The new list is written next to the allowlist and then moved over it, so a scan never reads a partial list and a
  # failed write keeps the old list.
  { [ ! -f "$ALLOWLIST" ] || cat "$ALLOWLIST"; } >"$ALLOWLIST.new" ||
    block "Infisical: could not save the allowed secret in $ALLOWLIST."
  while read -r hash; do
    grep -qxF "$hash" "$ALLOWLIST.new" || echo "$hash" >>"$ALLOWLIST.new" ||
      block "Infisical: could not save the allowed secret in $ALLOWLIST."
  done <"$tmp/hashes"
  mv -f "$ALLOWLIST.new" "$ALLOWLIST" || block "Infisical: could not save the allowed secret in $ALLOWLIST."

  # decision: block is the only way to stop a prompt without it joining the conversation, so Claude Code labels this
  # confirmation as blocked. continue: false shows a softer label but adds the typed command, secret included, to
  # what Claude sees on the next turn.
  block "Infisical: secret allowed. Prompts that contain it are no longer blocked.
Claude Code labels this as blocked because the plugin keeps the command from Claude, so the secret is never sent."
}

# Usage: disallow_secret <file holding the value given to the command>
disallow_secret() {
  [ -s "$1" ] || block "Infisical: put the secret to disallow after the command: $DISALLOW_COMMAND <secret>"
  value_hashes "$1"

  lock_allowlist
  [ -f "$ALLOWLIST" ] && grep -qxF -f "$tmp/hashes" "$ALLOWLIST" ||
    block "Infisical: the secret was not allowed, so nothing changed."

  # grep exits with 1 when it removes every line. The new list replaces the allowlist in one step, as in allow_secret.
  grep -vxF -f "$tmp/hashes" "$ALLOWLIST" >"$ALLOWLIST.new"
  [ $? -le 1 ] && mv -f "$ALLOWLIST.new" "$ALLOWLIST" ||
    block "Infisical: could not remove the secret from $ALLOWLIST, so it is still allowed."

  # Labeled as blocked by Claude Code, for the same reason as the allow_secret confirmation.
  block "Infisical: secret disallowed. Prompts that contain it are blocked again.
Claude Code labels this as blocked because the plugin keeps the command from Claude, so the secret is never sent."
}

umask 077
tmp="$(mktemp -d)" || block "Infisical: the secret scan could not create a temporary folder, so the prompt was not sent."
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/input.json" || block "Infisical: could not read the prompt to scan it, so it was not sent."

command -v infisical >/dev/null 2>&1 ||
  block "Infisical: the Infisical CLI is not installed, so prompts can't be scanned for secrets and are not sent. Install it: https://infisical.com/docs/cli/overview"
command -v jq >/dev/null 2>&1 ||
  block "Infisical: jq is not installed, so prompts can't be scanned for secrets and are not sent. Install it: https://jqlang.org/download"

command_value "$ALLOW_COMMAND" && allow_secret "$tmp/value.txt"
command_value "$DISALLOW_COMMAND" && disallow_secret "$tmp/value.txt"

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
