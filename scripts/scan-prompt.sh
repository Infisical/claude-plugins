#!/usr/bin/env bash
# UserPromptSubmit hook: scan the prompt with `infisical scan --pipe`.
# A prompt with secrets goes to Infisical, which allows it only when every secret was reviewed there.
# Exit code 2 blocks the prompt and shows stderr to the user. Any failure blocks the prompt.

# A failed command in a pipe must fail the pipe: otherwise a jq failure would hand the scan an empty prompt, which
# passes.
set -o pipefail

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
  load_infisical_session ||
    block "Infisical: the CLI is not logged in. Run 'infisical login' in a terminal, then try again."

  if ! is_recent "$FETCHED_AT" "$MAX_CONFIG_AGE_MINUTES"; then
    mkdir -p "$tmp/fetch"
    fetch_scan_config "$tmp/fetch" ||
      block "Infisical: could not load the scan configuration. $FETCH_ERROR"
  fi

  # Use the project's scan config when it has one, so the local scan matches the scan in Infisical.
  local config_args=()
  [ -f "$SCAN_CONFIG" ] && config_args=(--config "$SCAN_CONFIG")

  # Written to the private folder first, so a jq failure blocks the prompt instead of scanning nothing.
  jq -j '.prompt // ""' "$tmp/input.json" >"$tmp/prompt.txt" 2>/dev/null ||
    block "Infisical: could not read the prompt to scan it."

  infisical scan --pipe "${config_args[@]}" --silent --no-color \
    --exit-code "$LEAK_EXIT_CODE" --report-format json --report-path "$tmp/report.json" <"$tmp/prompt.txt" >/dev/null 2>&1
  local status=$?

  [ "$status" -eq 0 ] && exit 0

  [ "$status" -eq "$LEAK_EXIT_CODE" ] ||
    block "Infisical: the secret scan failed (exit code $status). Run 'infisical scan --pipe' to check the CLI."

  # One entry per distinct secret and rule. Infisical matches each value to its findings by a blind index, so the values
  # leave the machine, but the prompt only does when a secret is new.
  jq '{secrets: ([.[] | {value: .Secret, ruleId: .RuleID}] | unique)}' "$tmp/report.json" >"$tmp/check.json" ||
    block "Infisical: could not read the secret scan report."

  local api_url="$INFISICAL_API_URL"
  local check_url="$api_url/v2/secret-scanning/data-sources/claude-code/$DATA_SOURCE_ID"

  # The token goes in a header file, not on the command line, so other processes can't read it.
  printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$INFISICAL_TOKEN_VALUE" >"$tmp/headers"

  local http_code
  http_code="$(curl -sS --max-time 15 -o "$tmp/check-response.json" -w '%{http_code}' \
    -X POST -H @"$tmp/headers" --data-binary @"$tmp/check.json" \
    "$check_url/check-secrets" 2>"$tmp/curl-error")"

  [ "$http_code" = "200" ] ||
    block "Infisical: secret detected, and the request to Infisical failed. $(describe_api_failure "$http_code" "$tmp/check-response.json" "$tmp/curl-error" "$api_url")"

  # The rules of the secrets that hold the prompt back or need a warning, for the message.
  local rules new_count pending_count findings_url
  rules="$(jq -r '[.secrets[] | select(.status != "allowed") | .ruleId] | unique | join(", ")' "$tmp/check-response.json")"
  new_count="$(jq '[.secrets[] | select(.status == "new-finding")] | length' "$tmp/check-response.json")"
  pending_count="$(jq '[.secrets[] | select(.status == "pending-resolution")] | length' "$tmp/check-response.json")"
  findings_url="$(jq -r '.findingsUrl // empty' "$tmp/check-response.json")"

  # Infisical decides whether it needs the prompt: only for a secret that is new, or that came back after its finding
  # was resolved, so it can be scanned and recorded as a new finding. Otherwise Infisical never receives the prompt.
  if [ "$(jq -r '.promptRequired' "$tmp/check-response.json")" = "true" ]; then
    jq --slurpfile check "$tmp/check.json" '{
        prompt: .prompt,
        secrets: $check[0].secrets,
        sessionId: .session_id,
        cwd: .cwd
      } | with_entries(select(.value != null))' "$tmp/input.json" >"$tmp/body.json"

    http_code="$(curl -sS --max-time 20 -o "$tmp/response.json" -w '%{http_code}' \
      -X POST -H @"$tmp/headers" --data-binary @"$tmp/body.json" \
      "$check_url/prompts" 2>"$tmp/curl-error")"

    [ "$http_code" = "200" ] ||
      block "Infisical: new secret detected ($rules), and it could not be reported to Infisical. $(describe_api_failure "$http_code" "$tmp/response.json" "$tmp/curl-error" "$api_url")"
  fi

  local review_status="is waiting for review"
  [ "$pending_count" = "0" ] && review_status="was reported for review"
  [ "$new_count" != "0" ] && [ "$pending_count" != "0" ] && review_status="was reported or is waiting for review"

  if [ "$(jq -r '.allowed' "$tmp/check-response.json")" = "true" ]; then
    # A report-only data source lets unreviewed secrets through; warn the user (and not Claude) about them.
    if [ "$new_count" != "0" ] || [ "$pending_count" != "0" ]; then
      jq -n --arg message "Infisical: secret detected ($rules). It $review_status in Infisical. The prompt was sent to Claude.${findings_url:+ Findings: $findings_url}" \
        '{systemMessage: $message}'
    fi
    exit 0
  fi

  block "Infisical: secret detected ($rules). It $review_status in Infisical. Send the prompt again after a reviewer marks it as false positive or ignored.${findings_url:+
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
