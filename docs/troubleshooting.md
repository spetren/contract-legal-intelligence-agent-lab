# Troubleshooting

## Copilot Studio says "Let's get you connected first"

Cause: the custom connector exists, but the Power Platform connection or the Dataverse connection-reference row is not bound.

Fix:

1. Run `scripts\register-copilot-action.ps1`.
2. Confirm the Power Platform connection status is `Connected`.
3. Confirm the Dataverse `connectionreference.connectionid` field is populated.

## "View diagram" shows a broken image icon

Cause: the model returned Markdown image syntax for an authenticated SharePoint image.

Fix: redeploy the Function code from this repo. It tells the model to use normal links and also converts `![label](url)` to `[label](url)` before returning the answer.

## Image extraction stops during a long run

Cause: Microsoft Graph or SharePoint can occasionally close an upload connection or time out.

Fix: rerun image extraction with:

```powershell
.\scripts\run-image-extraction.ps1 ... -RenderPages -SkipExistingIndexed
```

The script skips records already present in Azure AI Search.

## Azure Function deployment fails because key-based storage auth is blocked

Some tenants disable storage account shared-key access. The reference environment required a Flex Consumption Function with managed-identity storage and private endpoints.

For strict environments:

1. Create the Function with Flex Consumption.
2. Set deployment storage authentication to `SystemAssignedIdentity`.
3. Grant the Function identity `Storage Blob Data Contributor`, `Storage Queue Data Contributor`, and `Storage Table Data Contributor` on the storage account.
4. Remove `DEPLOYMENT_STORAGE_CONNECTION_STRING` and connection-string `AzureWebJobsStorage` app settings.

## Azure OpenAI model deployment fails because a model version is deprecated

List available models:

```powershell
az cognitiveservices account list-models -g <resource-group> -n <openai-account> -o table
```

Use a current chat model such as `gpt-4.1-mini` if available.

