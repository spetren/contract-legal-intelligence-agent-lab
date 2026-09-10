# Bicep infrastructure

`main.bicep` provisions the Azure resources required by the Renewable Energy Compliance Lab:

| Resource | Purpose in the lab |
| --- | --- |
| Azure AI Search | Stores and queries the `reccia-documents` text index and `reccia-images` visual-evidence index. |
| Azure AI Document Intelligence | Extracts layout-aware text from the source documents before chunking and indexing. |
| Azure AI Vision | Captions, OCRs, and tags extracted images, rendered pages, diagrams, checklists, and tables. |
| Azure OpenAI account and chat model deployment | Runs the chat model used by the reasoning API to synthesize grounded, cited answers from retrieved evidence. |
| Storage account for Azure Functions | Provides Function App runtime storage for host state, triggers, deployment packages, and execution metadata. |
| Application Insights | Captures Function logs, traces, latency, and failures for troubleshooting the reasoning API. |
| Linux Azure Function App | Hosts the `askRenewableCompliance` API used by the Copilot Studio custom connector. |
| Managed identity role assignment for the Function App to call Azure OpenAI | Grants the Function's managed identity permission to call Azure OpenAI without storing model account keys. |

Deploy it with:

```powershell
az group create --name rg-reccia-graph-ingestion --location eastus

az deployment group create `
  --resource-group rg-reccia-graph-ingestion `
  --template-file infra\main.bicep `
  --parameters @infra\main.parameters.example.json
```

The repo script `scripts\deploy-azure-resources.ps1` wraps this deployment and is the recommended path for lab participants.

After Bicep creates the infrastructure, run `scripts\deploy-function-api.ps1` to deploy the Function code and inject the Azure AI Search query key into app settings.

## Strict tenant policies

Some tenants block storage shared-key access or require private networking for Function storage. In that case, use the same resources from this template, but adapt the Function hosting to Flex Consumption with managed-identity storage access and private endpoints for blob, queue, and table storage. See `docs\troubleshooting.md`.
