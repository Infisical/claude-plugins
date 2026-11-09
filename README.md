# Infisical for Claude Code

This plugin blocks Claude Code prompts that contain secrets, such as API keys, tokens, private keys, and database connection strings, before they reach Claude.

Everything runs on your machine. The plugin scans each prompt with the Infisical CLI's secret scanner and sends nothing to Infisical. You don't need an Infisical account or a login.

## How it works

1. When you send a prompt, a `UserPromptSubmit` hook scans its text with `infisical scan --pipe`. Pasted text is scanned too.
2. If the scan finds no secret, or only secrets you allowed, the prompt goes to Claude.
3. If it finds a secret, the prompt is not sent. You see which rules matched, on which line, and the first characters of each secret. Claude never sees the prompt or the message.

The plugin fails closed: if the CLI or `jq` is missing, if the scan fails, or if the hook crashes or times out, the prompt is not sent.

## Requirements

- [Infisical CLI](https://infisical.com/docs/cli/overview). Use a recent version; the plugin is tested with 0.45.4.
- [jq](https://jqlang.org/download)
- Claude Code 2.1.295 or later. Older versions let a prompt through when the hook times out.

## Install

```
claude plugin marketplace add Infisical/claude-code-plugin
claude plugin install infisical-secret-scanner@infisical
```

## Allow a secret

If a value is safe to share with Claude, for example a test key, allow it:

```
/infisical-secret-scanner:allow-secret <secret>
```

The hook handles this command itself and blocks it, so the value is never sent to Claude. That's why Claude Code shows the confirmation under "UserPromptSubmit operation blocked by hook". Prompts that contain the value are no longer blocked. You can pass the bare value, a quoted value, or a whole line such as `STRIPE_KEY=sk_test_...`; the plugin allows every secret the scanner finds in it.

The plugin stores only the SHA-256 hash of each allowed value, in `~/.claude/plugins/data/infisical-secret-scanner-infisical/allowed-secrets`. To clear all of them, delete that file.

To stop allowing a value, disallow it:

```
/infisical-secret-scanner:disallow-secret <secret>
```

The hook handles this command the same way, so the value is never sent to Claude. Pass the same value, quoted value, or line that you passed to `/infisical-secret-scanner:allow-secret`.

## Scan rules

The plugin scans with [`config/infisical-scan.toml`](config/infisical-scan.toml): the CLI's default rules, plus an allowlist for placeholder values such as `<your-token>`. A `.infisical-scan.toml` in your project does not change the scan.

To use your own rules, put a config at `~/.claude/plugins/data/infisical-secret-scanner-infisical/infisical-scan.toml`. It replaces the plugin's config. Start it with this block to keep the default rules:

```toml
[extend]
useDefault = true
```

## Limits

- The plugin scans only the text of the prompt. It doesn't scan files you mention with `@` (the prompt holds only the path), files Claude reads with its tools, or images.
- A blocked prompt never reaches Claude, but Claude Code still writes the text you typed, including the value you pass to `/infisical-secret-scanner:allow-secret` or `/infisical-secret-scanner:disallow-secret`, to local files such as your prompt history and the session transcript. See [Claude Code's local data](https://code.claude.com/docs/en/claude-directory).
- A developer can turn off the plugin or all hooks in their own Claude Code settings. To require it for every developer, install it through a managed settings file.

## Test locally

```
claude --plugin-dir /path/to/claude-code-plugin
```
