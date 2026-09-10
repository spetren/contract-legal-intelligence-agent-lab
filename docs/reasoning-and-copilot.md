# Reasoning and Copilot Studio setup

## Foundry reasoning

The Azure Function in `reccia-agent-api/function_app.py` uses Azure OpenAI chat completions as the reasoning layer.

The Function retrieves two evidence sets:

1. Text chunks from `reccia-documents`.
2. Visual records from `reccia-images`, including captions, OCR text, tags, page numbers, and SharePoint image links.

The model receives both evidence sets and is instructed to answer only from provided evidence.

## Copilot Studio action

The Power Platform custom connector is defined in:

- `reccia-agent-api/connector/apiDefinition.swagger.json`
- `reccia-agent-api/connector/apiProperties.json`

It exposes one operation:

`SearchRenewableComplianceKnowledge`

The operation calls:

`POST https://<function-app>.azurewebsites.net/api/askrenewablecompliance`

## Important rendering rule

Do not emit inline Markdown images such as:

```markdown
![View diagram](https://sharepoint/...)
```

Copilot Studio chat can show a broken image icon when the target is an authenticated SharePoint asset.

Use normal links instead:

```markdown
Visual: [View diagram](https://sharepoint/...)
```

The Function code normalizes accidental inline image syntax into normal links before returning answers.

## Agent instructions

Use `prompts/copilot-agent-instructions.md` as the Copilot Studio agent instruction block.

The instructions tell the agent to use the connector action for permitting, compliance, zoning, checklist, diagram, form, fee, timeline, and document-comparison questions.

