# Lab data

This folder makes the lab data layout explicit for replication.

This repo is scoped to a curated **six-document** corpus sized for a 90-minute guided build or executive
technical demo. `document-index.csv` records where each public source document came from so the lab can
download and upload the corpus into a new SharePoint library as part of the exercise.

## Folder layout

| Path | Purpose |
| --- | --- |
| `source-documents/` | Local cache populated by `scripts\bootstrap-sharepoint-corpus.ps1`; ignored by git except for `.gitkeep`. |
| `extracted-images/` | Optional local cache for visual assets; ignored by git except for `.gitkeep`. |
| `document-index.csv` | The six-document legal/compliance corpus: publisher/source URL, download status, and each document's role in the lab. |
| `sample-questions.json` | Focused evaluation prompts covering contracting, financing, interconnection, permit-readiness, and a legal-advice guardrail check. |

## Corpus

| File | Role in the lab |
| --- | --- |
| `02-Guide-to-Purchasing-Green-Power-Chapter-6-Contracting-for-Green-Power.pdf` | Contracting and procurement obligations. |
| `03-Guide-to-Purchasing-Green-Power-Appendix-B-Commercial-Solar-Financing-Options.pdf` | Commercial and financing considerations. |
| `06-IREC-Model-Interconnection-Procedures-2023.pdf` | Interconnection procedure and compliance steps. |
| `12-California-Solar-Permitting-Guidebook.pdf` | Permitting requirements and authority. |
| `13-Solar-Permit-Application-Template.docx` | Application template for compliance comparison. |
| `14-Permitting-Checklist.docx` | Permit-readiness checklist. |

## Source file note

The source PDFs, Word documents, rendered pages, and extracted images are generated or cached during the
lab. Commit the source index and scripts, not the generated binary corpus.

## Swapping in your own corpus

This is a template, not a fixed corpus. To point the pipeline at a customer's own documents, replace the
rows in `document-index.csv` with your own filenames, sources, and `LabRole` descriptions, and point
`-SourceFolder` / `-DriveId` at wherever those documents live (a different SharePoint library, a different
Graph drive, or another Microsoft 365 location). No script changes are required - the ingestion pipeline
reads the corpus definition from this file.
