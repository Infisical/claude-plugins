# Infisical Plugins for Claude Code

This repository is the Infisical plugin marketplace for Claude Code. Each folder at the root of the repository holds one plugin.

## Quick start

```
claude plugin marketplace add Infisical/claude-code-plugin
claude plugin install infisical-secret-scanner@infisical
```

## Plugins

### Infisical Secret Scanner

**Plugin ID**: `infisical-secret-scanner@infisical`

Blocks Claude Code prompts that contain secrets, such as API keys, tokens, and private keys, before they reach Claude. The plugin scans each prompt on your machine with the Infisical CLI and sends nothing to Infisical. See the [plugin README](infisical-secret-scanner/README.md).

## Add a plugin

1. Make a folder at the root of the repository. Give it the name of the plugin.
2. Put the plugin manifest in `<plugin>/.claude-plugin/plugin.json`. Put the commands, hooks, skills, scripts, and config of the plugin in the same folder. A plugin can only use files in its own folder, because Claude Code copies only that folder when it installs the plugin.
3. Add the plugin to `.claude-plugin/marketplace.json` with `"source": "./<plugin>"`.
4. Add the plugin to the list in this README.
5. Run `claude plugin validate .` to check the marketplace.

## Test locally

Add the marketplace from your local copy of the repository:

```
claude plugin marketplace add ./
claude plugin install <plugin>@infisical
```

To load one plugin without installing it:

```
claude --plugin-dir ./<plugin>
```
