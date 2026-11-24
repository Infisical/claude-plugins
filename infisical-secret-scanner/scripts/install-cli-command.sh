#!/usr/bin/env bash
# UserPromptSubmit hook: runs /infisical-secret-scanner:install-cli, which installs the Infisical CLI that
# scan-prompt.sh scans with. Claude Code runs this hook and scan-prompt.sh at the same time, and scan-prompt.sh lets the
# command pass, so the command works when no CLI is installed. Every other prompt passes this hook unchanged.

set -o pipefail

# Exit code 2 blocks the prompt.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh" 2>/dev/null || {
  echo "Infisical: could not load the plugin's scripts, so the prompt was not sent. Reinstall the plugin." >&2
  exit 2
}

input="$(cat)" || block "Infisical: could not read the prompt."

# Without jq this hook can't read the prompt. scan-prompt.sh then blocks every prompt and tells the user to install jq.
command -v jq >/dev/null 2>&1 || exit 0
jq -e --arg command "$INSTALL_COMMAND" '(.prompt // "") | test("\\A\\s*" + $command + "(\\s|\\z)")' \
  <<<"$input" >/dev/null 2>&1 || exit 0

[ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -n "$CLAUDE_PLUGIN_DATA" ] ||
  block "Infisical: Claude Code did not give the hook the plugin's folders, so the CLI was not installed. Update Claude Code."

umask 077
# install-cli.sh prints one line: what it installed, or why it failed.
if output="$(bash "$CLAUDE_PLUGIN_ROOT/scripts/install-cli.sh" "$CLAUDE_PLUGIN_DATA" 2>&1)"; then
  # decision: block is the only way to stop a prompt without it joining the conversation, so Claude Code labels this
  # confirmation as blocked.
  block "Infisical: ${output##*$'\n'}
Prompts are now scanned with this CLI. You can send your prompt again."
fi
reason="${output##*$'\n'}"
block "Infisical: could not install the Infisical CLI. ${reason:-The install script failed.}
Run $INSTALL_COMMAND to try again, or install the CLI yourself: $CLI_DOCS_URL"
