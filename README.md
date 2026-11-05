# Infisical Secret Scan for Claude Code

This plugin scans each prompt before Claude Code sends it. A prompt that contains a secret is blocked until someone reviews the secret in Infisical, or, with a report-only data source, the secret is reported and the prompt continues.

## How it works

1. The plugin scans the prompt locally with `infisical scan --pipe`, using the project's scan config.
2. If the scan finds no secret, the prompt goes to Claude. The plugin sends nothing to Infisical except the login check (`infisical login status`), which runs on every prompt.
3. If the scan finds secrets, the plugin sends only the secret values and their rule IDs to Infisical (`check-secrets`), never the prompt. Infisical matches each value by its blind index to the newest finding for that secret in the project:

   | Newest finding | Result |
   |---|---|
   | None | New finding |
   | Resolved | New finding (the secret came back; the resolved finding stays as history) |
   | False positive or ignored | Allowed, no new finding |
   | Unresolved | Waiting for review, no new finding |

4. If a secret is a new finding, Infisical asks for the prompt (`promptRequired`). Only then does the plugin send it, and Infisical scans it in the background and records the findings. Infisical never receives a prompt whose secrets are all known.
5. Infisical decides if the prompt continues. With "Block the prompt", it continues only when every secret is allowed. With "Report only", it always continues, and you see a warning that Claude does not see.
6. To let developers use a secret, a reviewer marks its finding as false positive or ignored. That applies to every developer in the project.

The plugin fails closed. It blocks every prompt, also prompts with no secret, if the CLI, `jq`, or `curl` is not installed, if setup is not done, if the CLI is not logged in, or if it must load the scan config and the load fails. It also blocks a prompt if the scan fails, if a request to Infisical fails, or if the check takes more than 45 seconds. Claude Code lets a prompt through when a hook passes its timeout, so the hook stops itself first.

## Requirements

- [Infisical CLI](https://infisical.com/docs/cli/overview) version 0.44.9 or later, logged in with `infisical login`. The plugin checks the login with `infisical login status`, then uses `infisical user get token` and the domain of that same session, so it follows `--profile`, `INFISICAL_PROFILE`, and folder profiles like the CLI does.
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

The local scan uses the project's secret scanning configuration. If your project has a custom configuration, a background hook downloads it at most once every 24 hours. If the project has no custom configuration, the local scan uses the CLI defaults.

The local scan and the scan in Infisical can still find different secrets: your CLI version can differ from the one Infisical uses, your cached configuration can be up to 48 hours old, and rules that depend on a file path act differently on a prompt. When the plugin reports a secret that the scan in Infisical misses, Infisical still records a finding for it, so a blocked secret always has a finding to review.

## What the plugin scans

The plugin scans only the text of the prompt. It does not scan:

- the contents of files that you mention with `@`. The prompt holds only the path, and Claude Code reads the file after the hook runs.
- files that Claude reads with its tools
- attachments, such as images

A developer can turn off the plugin or all hooks in their own Claude Code settings. To make every developer use it, install it through a managed settings file.

## Test locally

```
claude --plugin-dir /path/to/infisical-claude-plugin
```
