# Infisical for Claude Code

This plugin blocks Claude Code prompts that contain secrets, such as API keys, tokens, private keys, and database connection strings, before they reach Claude.

Everything runs on your machine. The plugin scans each prompt with the Infisical CLI's secret scanner and sends nothing to Infisical. You don't need an Infisical account or a login.

## How it works

1. When you send a prompt, a `UserPromptSubmit` hook scans its text with `infisical scan --pipe`. Pasted text is scanned too.
2. If the scan finds no secret, or only secrets you allowed, the prompt goes to Claude.
3. If it finds a secret, the prompt is not sent. You see which rules matched, on which line, and the first characters of each secret. Claude never sees the prompt or the message.

The plugin fails closed: if it finds no Infisical CLI, if `jq` is missing, if the scan fails, or if the hook crashes or times out, the prompt is not sent.

## Requirements

- Infisical CLI. If you don't have it, run `/infisical-secret-scanner:install-cli` (see [Infisical CLI](#infisical-cli)) or [install it yourself](https://infisical.com/docs/cli/overview). The plugin is tested with 0.45.4.
- [jq](https://jqlang.org/download)
- Claude Code 2.1.295 or later. Older versions let a prompt through when the hook times out.

## Install

```
claude plugin marketplace add Infisical/claude-code-plugin
claude plugin install infisical-secret-scanner@infisical
```

## Infisical CLI

The plugin scans with the first Infisical CLI that it finds:

1. The CLI that `/infisical-secret-scanner:install-cli` installed in `~/.claude/plugins/data/infisical-secret-scanner-infisical/bin/`.
2. `infisical` on your `PATH`.

If it finds neither, it blocks the prompt and tells you to run this command:

```
/infisical-secret-scanner:install-cli
```

A separate hook handles this command, so the command works when no CLI is installed, for example in a cloud session that started without one. The command:

1. Downloads Infisical CLI 0.45.4 for your platform from the Infisical CLI releases on GitHub.
2. Checks the SHA-256 hash of the download against the hash that ships with the plugin. If the hashes are different, it installs nothing.
3. Installs the CLI in the folder above. The CLI uses about 160 MB of disk space.

The plugin downloads the CLI only when you run this command. It does not change your `PATH` or other programs, and uninstalling the plugin deletes the folder. Run the command again to reinstall the CLI, or to use the tested version instead of an older CLI on your `PATH`.

The command needs access to `github.com` and `release-assets.githubusercontent.com`. In Claude Code on the web, the default network access ("Limited" with "Allow package managers") allows both. The command supports macOS, Linux, and Windows on x86-64 and ARM64. On other platforms, [install the CLI yourself](https://infisical.com/docs/cli/overview).

## Allow a secret

If a value is safe to share with Claude, for example a test key, allow it:

```
/infisical-secret-scanner:allow <secret>
```

The hook handles this command itself and blocks it, so the value is never sent to Claude. That's why Claude Code shows the confirmation under "UserPromptSubmit operation blocked by hook". Prompts that contain the value are no longer blocked. You can pass the bare value, a quoted value, or a whole line such as `STRIPE_KEY=sk_test_...`; the plugin allows every secret the scanner finds in it.

The plugin stores only the SHA-256 hash of each allowed value, as the name of an empty file in `~/.claude/plugins/data/infisical-secret-scanner-infisical/allowlist/`. To clear all of them, delete that folder.

To stop allowing a value, disallow it:

```
/infisical-secret-scanner:disallow <secret>
```

The hook handles this command the same way, so the value is never sent to Claude. Pass the same value, quoted value, or line that you passed to `/infisical-secret-scanner:allow`.

## Scan rules

The plugin scans with [`config/infisical-scan.toml`](config/infisical-scan.toml): the CLI's default rules, plus an allowlist for placeholder values such as `<your-token>`. A `.infisical-scan.toml` in your project does not change the scan.

To use your own rules, put a config at `~/.claude/plugins/data/infisical-secret-scanner-infisical/infisical-scan.toml`. It replaces the plugin's config. Start it with this block to keep the default rules:

```toml
[extend]
useDefault = true
```

## Limits

- The plugin scans only the text of the prompt. It doesn't scan files you mention with `@` (the prompt holds only the path), files Claude reads with its tools, or images.
- A blocked prompt never reaches Claude, but Claude Code still writes the text you typed, including the value you pass to `/infisical-secret-scanner:allow` or `/infisical-secret-scanner:disallow`, to local files such as your prompt history and the session transcript. See [Claude Code's local data](https://code.claude.com/docs/en/claude-directory).
- A developer can turn off the plugin or all hooks in their own Claude Code settings. To require it for every developer, install it through a managed settings file.

## Test locally

From the root of this repository:

```
claude --plugin-dir ./infisical-secret-scanner
```

## Pin a new CLI version

1. In [`scripts/install-cli.sh`](scripts/install-cli.sh), set `CLI_VERSION`.
2. Download the checksum files of the release: `gh release download v<version> -R Infisical/cli -p 'checksums*.txt'`.
3. Copy the hashes of the six archives from `checksums.txt` and `checksums-darwin.txt` into `scripts/install-cli.sh`.
4. Change the tested version in this README.
5. Increase `version` in [`.claude-plugin/plugin.json`](.claude-plugin/plugin.json). Claude Code updates the plugin only when this value changes.
