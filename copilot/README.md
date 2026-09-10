# Copilot Studio templates

These files show the reusable Copilot Studio action wiring for the lab.

Recommended setup:

1. Create or clone a Copilot Studio agent workspace with `pac copilot init` or `pac copilot clone`.
2. Register the custom connector with `scripts\register-copilot-action.ps1`.
3. Copy `actions\SearchKnowledge.mcs.yml` into the agent workspace `actions` folder.
4. Copy `connectionreferences.mcs.yml` into the agent workspace root.
5. Replace the placeholders:
   - `{{BOT_SCHEMA_NAME}}`
   - `{{CONNECTOR_INTERNAL_ID}}`
   - `{{CONNECTION_NAME}}`
6. Push and publish the agent:

```powershell
pac copilot push --project-dir <agent-workspace>
pac copilot publish --environment <environment-url> --bot <bot-id-or-schema-name>
```

The `register-copilot-action.ps1` script prints the connector internal ID, connection name, and connection-reference logical name to use.

