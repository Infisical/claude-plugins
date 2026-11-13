#!/usr/bin/env bash
# UserPromptSubmit hook: scans the prompt on this machine with `infisical scan --pipe` and blocks it when it holds a
# secret that hasn't been allowed. It also runs /infisical-secret-scanner:allow and
# /infisical-secret-scanner:disallow itself, so the value given to those commands is never sent to Claude.
# Nothing is sent to Infisical. Any failure blocks the prompt.

set -o pipefail

# Exit code 2 blocks the prompt.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh" 2>/dev/null || {
  echo "Infisical: could not load the plugin's scripts, so the prompt was not sent. Reinstall the plugin." >&2
  exit 2
}

ALLOW_COMMAND="/infisical-secret-scanner:allow"
DISALLOW_COMMAND="/infisical-secret-scanner:disallow"
LEAK_EXIT_CODE=42
# Claude Code gives the hook CLAUDE_PLUGIN_ROOT, the plugin's installed folder, and CLAUDE_PLUGIN_DATA, a folder for the
# plugin's data that is kept across plugin updates.
DATA_DIR="${CLAUDE_PLUGIN_DATA}"
# One empty file for each allowed secret value, named after the SHA-256 hash of the value. The values themselves are
# never stored. A command only creates or deletes its own files, so sessions that change the list at the same time
# can't undo each other's changes, and no lock is needed.
ALLOWLIST="$DATA_DIR/allowlist"

# The scan must not reach the network: no telemetry event, no update check.
export INFISICAL_DISABLE_TELEMETRY=1 INFISICAL_DISABLE_UPDATE_CHECK=1

# Usage: scan <input file> <report file>. Returns 0 for no secrets and LEAK_EXIT_CODE for secrets. It runs from the
# private folder, so files in the user's project, such as a .infisical-scan.toml, can't change the result.
scan() {
  (cd "$tmp" && "$INFISICAL" scan --pipe --config "$SCAN_CONFIG" --silent --no-color \
    --exit-code "$LEAK_EXIT_CODE" --report-format json --report-path "$2" <"$1" >/dev/null 2>&1)
}

scan_failed() {
  block "Infisical: the secret scan failed (exit code $1), so the prompt was not sent. Run '$INFISICAL scan --pipe --config $SCAN_CONFIG' to see the error. If the Infisical CLI is out of date, run $INSTALL_COMMAND to install the version this plugin is tested with."
}

# Sets INFISICAL to the CLI to scan with: first the one that $INSTALL_COMMAND installed in the plugin's data folder,
# then one on PATH. Returns 1 when there is neither.
find_cli() {
  local name
  for name in infisical infisical.exe; do
    if [ -f "$DATA_DIR/bin/$name" ] && [ -x "$DATA_DIR/bin/$name" ]; then
      INFISICAL="$DATA_DIR/bin/$name"
      return 0
    fi
  done
  INFISICAL="$(command -v infisical 2>/dev/null)" && [ -n "$INFISICAL" ]
}

is_allowed() {
  [ -f "$ALLOWLIST/$1" ]
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

  mkdir -p "$ALLOWLIST" || block "Infisical: could not save the allowed secret in $ALLOWLIST."
  while read -r hash; do
    : >"$ALLOWLIST/$hash" || block "Infisical: could not save the allowed secret in $ALLOWLIST."
  done <"$tmp/hashes"

  # decision: block is the only way to stop a prompt without it joining the conversation, so Claude Code labels this
  # confirmation as blocked. continue: false shows a softer label but adds the typed command, secret included, to
  # what Claude sees on the next turn.
  block "Infisical: secret allowed. Prompts that contain it are no longer blocked.
You can now create a new prompt with the secret you allow-listed, and future prompts containing the secret will not be blocked."
}

# Usage: disallow_secret <file holding the value given to the command>
disallow_secret() {
  local hash found=""

  [ -s "$1" ] || block "Infisical: put the secret to disallow after the command: $DISALLOW_COMMAND <secret>"
  value_hashes "$1"

  while read -r hash; do
    is_allowed "$hash" || continue
    found=1
    rm -f "$ALLOWLIST/$hash" || block "Infisical: could not remove the secret from $ALLOWLIST, so it is still allowed."
  done <"$tmp/hashes"
  [ -n "$found" ] || block "Infisical: the secret was not allowed, so nothing changed."

  # Labeled as blocked by Claude Code, for the same reason as the allow_secret confirmation.
  block "Infisical: secret disallowed. Prompts that contain will now be blocked in the future."
}

umask 077
tmp="$(mktemp -d)" || block "Infisical: the secret scan could not create a temporary folder, so the prompt was not sent."
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/input.json" || block "Infisical: could not read the prompt to scan it, so it was not sent."

command -v jq >/dev/null 2>&1 ||
  block "Infisical: jq is not installed, so prompts can't be scanned for secrets and are not sent. Install it: https://jqlang.org/download"
[ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -n "$DATA_DIR" ] ||
  block "Infisical: Claude Code did not give the hook the plugin's folders, so prompts can't be scanned for secrets and are not sent. Update Claude Code."

# install-cli-command.sh, a separate hook, runs this command and blocks it. The prompt holds nothing else to scan, and
# it must pass here when no CLI is installed. With more text after the command, the prompt is scanned as usual.
jq -e --arg command "$INSTALL_COMMAND" '(.prompt // "") | test("\\A\\s*" + $command + "\\s*\\z")' "$tmp/input.json" \
  >/dev/null 2>&1 && exit 0

find_cli ||
  block "Infisical: the Infisical CLI is not installed, so prompts can't be scanned for secrets and are not sent.
Run $INSTALL_COMMAND to download the CLI from GitHub into this plugin's data folder, or install it yourself: $CLI_DOCS_URL"

SCAN_CONFIG="${CLAUDE_PLUGIN_ROOT}/config/infisical-scan.toml"
[ -f "$DATA_DIR/infisical-scan.toml" ] && SCAN_CONFIG="$DATA_DIR/infisical-scan.toml"

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
  "  - \(.RuleID) on line \(.StartLine)" + (if (.Secret | length) >= 16 then ", starts with \(.Secret[0:4])" else "" end)
' "$tmp/report.json")" || block "Infisical: could not read the secret scan report, so the prompt was not sent."

block "Infisical: the prompt was not sent because it contains secrets:
$findings
Remove them and send the prompt again. To allow a value that is safe to share, run $ALLOW_COMMAND <value>."
