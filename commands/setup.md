---
description: Choose the Infisical data source that scans your Claude Code prompts for secrets
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh:*), AskUserQuestion
disable-model-invocation: true
---

Set up the Infisical secret scan plugin. Follow these steps exactly. Do not do anything else.

1. Run this command with the Bash tool, exactly as written:

   ```
   ${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh --data-dir ${CLAUDE_PLUGIN_DATA} check
   ```

2. The command prints JSON.
   - If `ok` is `false`: tell the user the `error` text, word for word, and stop. Do not try to fix the problem yourself. For example, do not run `infisical login` or install software.
   - If `override` is present: tell the user that their admin set the data source (show `override.name`, or `override.id` if the name is null), so there is nothing to choose. Stop.

3. Ask the user to choose a data source with the AskUserQuestion tool:
   - Question: "Which Infisical data source should scan your Claude Code prompts?" Header: "Data source".
   - Make one option for each entry in `dataSources`. The label is the data source `name`. The description is the data source `description`, followed by "Blocks prompts with secrets" if `onSecretDetected` is `block`, or "Reports secrets and lets prompts through" if it is `report`. If `current` is not null, add "(current)" to the description of that data source.
   - Never show data source IDs to the user.
   - AskUserQuestion needs 2 to 4 options. If there is only 1 data source, add a second option with the label "Cancel". If there are more than 4, show 3 data sources and a fourth option with the label "More data sources", and show the next ones in a new question when the user picks it.

4. If the user picks "Cancel", stop without changes. If the user types an answer instead of picking a listed data source, do not accept it: tell the user that only a data source from the list can be used, and ask again with the same options.

5. Run this command with the Bash tool, with the `id` of the data source that the user picked. Only use an `id` from the `check` output:

   ```
   ${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh --data-dir ${CLAUDE_PLUGIN_DATA} select <id>
   ```

6. If `ok` is `true`, tell the user that prompts are now scanned by the data source `selected.name`. Also tell them what happens when a secret is found: if `selected.onSecretDetected` is `block`, the prompt is blocked until the secret is reviewed in Infisical; if it is `report`, the prompt is sent and the secret is reported in Infisical. If `warning` is not null, also show the warning. If `ok` is `false`, tell the user the `error` text.
