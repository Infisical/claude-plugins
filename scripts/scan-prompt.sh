#!/usr/bin/env bash
# UserPromptSubmit hook: scan the prompt with `infisical scan --pipe`.
# A prompt with secrets goes to Infisical, which allows it only when every secret was reviewed there.
# Exit code 2 blocks the prompt and shows stderr to the user. Any failure blocks the prompt.

source "$(dirname "$0")/lib.sh"

LEAK_EXIT_CODE=42
# Claude Code lets a prompt through when a hook times out, so the hook stops itself first. Keep this below the
# timeout in hooks.json.
DEADLINE_SECONDS=45
# The async hook refreshes the config every 24 hours. A cache older than this means those refreshes keep failing.
MAX_CONFIG_AGE_MINUTES=2880

# Blocks the prompt. The JSON form lets Claude Code show the message without the script path, and without repeating the
# prompt, which can hold a secret. Exit code 2 and stderr still block the prompt if the JSON can't be read.
block() {
  local message="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg reason "$message" \
      '{decision: "block", reason: $reason, hookSpecificOutput: {hookEventName: "UserPromptSubmit", suppressOriginalPrompt: true}}'
  fi
  echo "$message" >&2
  exit 2
}

# The scan report holds the secrets in plain text, so the folder is private and removed on exit.
umask 077
tmp="$(mktemp -d)" || block "Infisical: the secret scan could not create a temporary folder."
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/input.json"

scan_prompt() {
  # The setup command fixes what the checks below report, so it is never blocked. Only the exact command is let
  # through: arguments after it would reach Claude unscanned.
  [ "$(jq -r '.prompt // "" | gsub("^\\s+|\\s+$"; "")' "$tmp/input.json" 2>/dev/null)" = "$SETUP_COMMAND" ] && exit 0

  local tool
  for tool in infisical jq curl; do
    command -v "$tool" >/dev/null 2>&1 ||
      block "Infisical: $tool is not installed. The secret scan needs the Infisical CLI, jq, and curl: https://infisical.com/docs/cli/overview"
  done

  check_cli_version || block "Infisical: $CLI_VERSION_ERROR"

  [ -n "$DATA_SOURCE_ID" ] ||
    block "Infisical: the secret scan is not set up. Run $SETUP_COMMAND to choose your data source."

  # Checked on every prompt, not only when a secret is found, so a logged-out CLI can't go unnoticed.
  local token
  token="$(infisical_token)"
  [ -n "$token" ] ||
    block "Infisical: the CLI is not logged in. Run 'infisical login' in a terminal, then try again."

  if ! is_recent "$FETCHED_AT" "$MAX_CONFIG_AGE_MINUTES"; then
    mkdir -p "$tmp/fetch"
    fetch_scan_config "$tmp/fetch" ||
      block "Infisical: could not load the scan configuration. $FETCH_ERROR"
  fi

  # Use the project's scan config when it has one, so the local scan matches the scan in Infisical.
  local config_args=()
  [ -f "$SCAN_CONFIG" ] && config_args=(--config "$SCAN_CONFIG")

  jq -j '.prompt // ""' "$tmp/input.json" |
    infisical scan --pipe "${config_args[@]}" --silent --no-color \
      --exit-code "$LEAK_EXIT_CODE" --report-format json --report-path "$tmp/report.json" >/dev/null 2>&1
  local status=$?

  [ "$status" -eq 0 ] && exit 0

  [ "$status" -eq "$LEAK_EXIT_CODE" ] ||
    block "Infisical: the secret scan failed (exit code $status). Run 'infisical scan --pipe' to check the CLI."

  local rules
  rules="$(jq -r '[.[].RuleID] | unique | join(", ")' "$tmp/report.json" 2>/dev/null)"
  rules="${rules:-unknown rule}"

  # Infisical computes the same fingerprint: the sha256 of the secret, so a secret that several rules match is one
  # finding. Secrets can span lines, so they are separated by NUL.
  local fingerprints
  fingerprints="$(
    jq -j '.[] | "\(.Secret)\u0000"' "$tmp/report.json" |
      while IFS= read -r -d '' finding; do
        printf '%s' "$finding" | sha256
      done | jq -R . | jq -s 'unique'
  )"

  local api_url
  api_url="$(infisical_api_url)"

  jq --argjson fingerprints "$fingerprints" '{
      prompt: .prompt,
      fingerprints: $fingerprints,
      sessionId: .session_id,
      cwd: .cwd
    } | with_entries(select(.value != null))' "$tmp/input.json" >"$tmp/body.json"

  # The token goes in a header file, not on the command line, so other processes can't read it.
  printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$token" >"$tmp/headers"

  local http_code
  http_code="$(curl -sS --max-time 20 -o "$tmp/response.json" -w '%{http_code}' \
    -X POST -H @"$tmp/headers" --data-binary @"$tmp/body.json" \
    "$api_url/v2/secret-scanning/data-sources/claude-code/$DATA_SOURCE_ID/prompts" 2>"$tmp/curl-error")"

  [ "$http_code" = "200" ] ||
    block "Infisical: secret detected ($rules), and the request to Infisical failed. $(describe_api_failure "$http_code" "$tmp/response.json" "$tmp/curl-error" "$api_url")"

  local findings_url
  findings_url="$(jq -r '.findingsUrl // empty' "$tmp/response.json" 2>/dev/null)"

  if [ "$(jq -r '.allowed' "$tmp/response.json" 2>/dev/null)" = "true" ]; then
    # A report-only data source lets unreviewed secrets through; warn the user (and not Claude) that it was reported.
    if [ "$(jq -r '.pendingFingerprints | length' "$tmp/response.json" 2>/dev/null)" != "0" ]; then
      jq -n --arg message "Infisical: secret detected ($rules) and reported for review. The prompt was sent to Claude.${findings_url:+ Findings: $findings_url}" \
        '{systemMessage: $message}'
    fi
    exit 0
  fi

  block "Infisical: secret detected ($rules). Mark the finding as resolved, false positive, or ignored in Infisical, then send the prompt again.${findings_url:+
Findings: $findings_url}"
}

scan_prompt &
scan_pid=$!

while kill -0 "$scan_pid" 2>/dev/null; do
  if [ "$SECONDS" -ge "$DEADLINE_SECONDS" ]; then
    # disowned first, so the shell doesn't print a job notice into the message shown to the user
    disown "$scan_pid" 2>/dev/null
    pkill -KILL -P "$scan_pid" 2>/dev/null
    kill -KILL "$scan_pid" 2>/dev/null
    block "Infisical: the secret scan did not finish within $DEADLINE_SECONDS seconds. Check that Infisical is reachable, then try again."
  fi
  sleep 0.05
done

wait "$scan_pid"
status=$?

# Only an explicit allow lets the prompt through; any other way the scan ended blocks it.
[ "$status" -eq 0 ] || [ "$status" -eq 2 ] || block "Infisical: the secret scan ended unexpectedly (exit code $status)."
exit "$status"
