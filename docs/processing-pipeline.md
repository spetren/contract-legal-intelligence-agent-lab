# Processing pipeline

## Text ingestion

`ingest_sharepoint_to_search.py` reads source documents from a SharePoint folder through Microsoft Graph, extracts text, chunks it, and uploads records to Azure AI Search.

It uses delegated device-code authentication with `Files.Read.All`. Create the public client first with `scripts\register-graph-client.ps1`; see [Microsoft Graph app registration](graph-app-registration.md).

Supported source types:

- PDF
- PNG/JPG/TIFF images
- DOCX

PDFs and images use Azure AI Document Intelligence layout extraction. DOCX files use package XML text extraction.

## Visual ingestion

`extract_images_to_search.py` creates one Search record per extracted visual asset.

It requests delegated `Files.ReadWrite.All` because extracted assets are written back to SharePoint.

It handles:

- Embedded raster images in PDFs.
- Rendered PDF pages, which capture scanned pages, vector diagrams, tables, and diagrams that are not normal embedded images.
- DOCX `/word/media/*`.
- PPTX `/ppt/media/*`.

For every supported visual asset, the script:

1. Uploads the image/page render to `Extracted Images/<source-document-name>/` in SharePoint.
2. Runs Azure AI Vision captioning, OCR, and tagging when the image meets service requirements.
3. Indexes metadata and reasoning fields in Azure AI Search.

## Resume behavior

Use `--skip-existing-indexed` when rerunning image extraction. The script loads existing image record IDs from Azure AI Search and skips assets already indexed.

This makes long runs restart-safe after transient Graph, SharePoint, or network failures.

## Recommended image settings

For balanced quality and processing cost:

- `--render-pages`
- `--dpi 120`
- `--jpeg-quality 72`
- `--skip-existing-indexed`

