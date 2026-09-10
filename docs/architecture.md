# Architecture

The lab demonstrates a retrieval-augmented Copilot Studio agent that can reason over both text and visual evidence from renewable-energy compliance documents.

## Components

| Layer | Component | Role |
| --- | --- | --- |
| Content | SharePoint document library | Stores source PDFs, Word documents, PowerPoint files, and extracted image assets. |
| Processing | `ingest_sharepoint_to_search.py` | Extracts text with Azure AI Document Intelligence and chunks it for Search. |
| Processing | `extract_images_to_search.py` | Extracts embedded images, renders PDF pages, runs Azure AI Vision captions/OCR, and indexes visual metadata. |
| Retrieval | Azure AI Search | Hosts `reccia-documents` and `reccia-images`. |
| Reasoning | Azure Function + Azure OpenAI | Merges text/image evidence and produces grounded answers with citations. |
| Experience | Copilot Studio | Provides the agent UI and invokes the custom connector action. |

## Indexes

### Text index

Default name: `reccia-documents`

Key fields:

- `documentName`
- `sourceUrl`
- `pageNumber`
- `chunkIndex`
- `content`
- `ocrEngine`
- `lastModifiedDateTime`

### Image index

Default name: `reccia-images`

Key fields:

- `sourceDocumentName`
- `sourceUrl`
- `imageUrl`
- `imageKind`
- `pageNumber`
- `caption`
- `captionConfidence`
- `ocrText`
- `tags`
- `visionStatus`

## Reasoning flow

1. Copilot Studio receives a user question.
2. The `SearchRenewableComplianceKnowledge` connector action calls the Azure Function.
3. The Function retrieves matching text chunks and image records from Azure AI Search.
4. The Function sends the evidence bundle to Azure OpenAI in Foundry.
5. The model answers only from supplied evidence and cites document/page/image links.

