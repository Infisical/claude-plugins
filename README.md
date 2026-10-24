# Infisical Secret Scan for Claude Code

This plugin scans each prompt before Claude Code sends it. A prompt that contains a secret is blocked until someone reviews the secret in Infisical.

## How it works

1. The plugin scans the prompt locally with `infisical scan --pipe`.
2. If the scan finds no secret, the prompt goes to Claude. The plugin makes no API call.
3. If the scan finds a secret, the plugin sends the prompt and a fingerprint for each secret to your Claude Code data source in Infisical. The fingerprint is the SHA-256 hash of the secret, so a secret that several rules match has one fingerprint.
4. Infisical allows the prompt only if every secret has a finding marked as resolved, false positive, or ignore. Otherwise Infisical records new findings and the plugin blocks the prompt.
5. After a reviewer marks the finding in Infisical, the same secret is allowed for every developer in the project.

The plugin fails closed. It blocks every prompt, also prompts with no secret, if the CLI, `jq`, or `curl` is not installed, if setup is not done, if the CLI is not logged in, or if it must load the scan config and the load fails. It also blocks a prompt if the scan fails, if a request to Infisical fails, or if the check takes more than 45 seconds. Claude Code lets a prompt through when a hook passes its timeout, so the hook stops itself first.

## Requirements

- [Infisical CLI](https://infisical.com/docs/cli/overview) version 0.44.9 or later, logged in with `infisical login`. The plugin checks the login with `infisical login status`, then uses `infisical user get token` and the domain of your CLI login.
- `jq` and `curl`
- A Claude Code data source in Infisical Secret Scanning

## Setup

1. Install the plugin:

   ```
   claude plugin marketplace add Infisical/claude-code-plugin
   claude plugin install infisical-secret-scan@infisical
   ```

2. In Claude Code, run `/infisical-secret-scan:setup`. It checks the CLI and the login, lists your Claude Code data sources, and saves the one you pick. You only do this once. Run it again to change the data source.

Until setup is done, the plugin blocks every prompt. The setup command itself is never blocked.

An admin can set the data source for every developer with the `INFISICAL_CLAUDE_CODE_DATA_SOURCE_ID` env var, for example in a managed Claude Code settings file. The env var wins over the developer's choice.

## Block or report

Each data source has a "When a Secret Is Detected" setting in Infisical:

- **Block the prompt** (default): the prompt is blocked until every secret in it is reviewed in Infisical.
- **Report only**: the prompt goes to Claude, the secret is recorded as a finding, and you see a warning. Claude does not see the warning.

## Scan rules

The local scan uses the same rules as Infisical. If your project has a custom secret scanning configuration, a background hook downloads it at most once every 24 hours. If the project has no custom configuration, both sides use the CLI defaults.

## Test locally

```
claude --plugin-dir /path/to/infisical-claude-plugin
```
