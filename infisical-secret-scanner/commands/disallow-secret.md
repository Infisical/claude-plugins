---
description: Block prompts that contain this secret value again. The value is never sent to Claude.
argument-hint: <secret>
disable-model-invocation: true
---

The Infisical plugin's prompt hook runs this command and blocks the prompt, so you only see this when the hook did not run. Nothing was changed.

Do not repeat, use, or store any value that came with this command. Tell the user only this: "The Infisical plugin's hooks did not run, so /infisical-secret-scanner:disallow-secret did not change anything, and the value you typed was sent to Claude. Check that the plugin is enabled and that hooks are not turned off in your Claude Code settings."
