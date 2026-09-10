# Recreating This With an AI Coding Assistant

Everything in this repo - the deployed agent, the trimmed six-document corpus, the companion Lab Guide,
the one-slide deck, and this standalone repo itself - was produced end-to-end with an AI coding assistant
(Microsoft Scout / GitHub Copilot CLI) driving Azure CLI, Microsoft Graph, Power Platform CLI, and Office
document automation on the operator's behalf. Nothing here required hand-editing Bicep, XML, or OOXML
directly.

If you want an assistant to reproduce this pattern for your own scenario, corpus, or customer, give it the
prompts below in order. Each step is written the way you would actually type it to Scout or Copilot, not as
abstract guidance - copy, adapt, and go.

## What you will end up with

1. A working Copilot Studio agent grounded on your own document corpus, with text and visual-evidence
   retrieval.
2. A demo-sized corpus scoped to your time box (this build used six documents for 90 minutes).
3. A companion Lab Guide (`.docx`) that matches the deployed solution and corpus exactly.
4. A one-slide What/Why/How/Next-Steps deck for framing the demo with a customer.
5. A standalone GitHub repo scoped to just that demo - the thing you can actually hand to someone else.

## Prerequisites

- A single Azure + Microsoft 365 tenant you can deploy into (BYOT linked to CDX, or your own tenant) -
  see the main [README prerequisites](../README.md#prerequisites). Do not split resources across tenants.
- An assistant with shell, file system, Azure CLI, Microsoft Graph/M365, and Office document (Word/
  PowerPoint COM automation or equivalent) access.
- Read access to the source scenario you are adapting - in this case,
  [ai-agent-runbooks: Contract-and-Legal-Intelligence-Agent](https://github.com/microsoft/ai-agent-runbooks/tree/main/01-scenarios/Contract-and-Legal-Intelligence-Agent).

## Step 1 - Have the assistant scope the deployment before building anything

> "Let's deploy this solution: `https://github.com/microsoft/ai-agent-runbooks/tree/main/01-scenarios/Contract-and-Legal-Intelligence-Agent`. I will provide the source documents - just create a deployment plan before building."

Let it inspect the scenario, identify prerequisites and required inputs, and produce a phased plan
(prerequisites -> environment prep -> deploy -> verify) before it touches your tenant. Review the plan
before approving.

## Step 2 - Validate tenant access, then deploy

> "Confirm Azure CLI and Microsoft 365 are both signed into the target tenant, then deploy the
> infrastructure from the plan, bootstrap the SharePoint corpus, run text and image ingestion, deploy the
> reasoning API, register the Copilot Studio connector, and create and publish the agent. Validate with a
> real test question at the end and show me the result."

This is exactly `scripts/deploy-azure-resources.ps1` -> `bootstrap-sharepoint-corpus.ps1` ->
`run-text-ingestion.ps1` -> `run-image-extraction.ps1` -> `deploy-function-api.ps1` ->
`register-copilot-action.ps1` -> Copilot Studio agent creation, in that order. Do not let the assistant
skip a step's exit criteria to save time - an unbound connector or an empty index surfaces later as a
confusing agent failure, not an obvious infrastructure error.

## Step 3 - Choose your demo-sized corpus

> "We need to fit this into a 90-minute demo. Pick 5-6 documents from the full corpus that best cover
> [your scenario's core questions - e.g. contracting, financing, interconnection, permit readiness], and
> produce a trimmed `document-index.csv` and a matching `sample-questions.json` for just those documents."

Keep the full corpus file and the trimmed one side by side at first (as an alternate path) until you are
sure of the cut - this repo went through exactly that intermediate state before being promoted to a
standalone demo repo in Step 6.

## Step 4 - Generate the companion one-slide deck

> "Create a one-slide PowerPoint summarizing this solution for a customer: What it is, Why it matters, How
> it works (with a short pipeline diagram), and what's next (fork it, swap the corpus, deploy your own).
> Add speaker notes to each box with a talking point, a concrete example, and the Azure resource(s) that
> box represents."

Iterate on wording and layout conversationally - ask for a specific slide export/preview so you can review
it before signing off, and be explicit if a rendered preview looks stale after a regeneration (PowerPoint
COM can return cached output immediately after a file is rewritten; regenerating to a fresh local path and
closing stray PowerPoint processes before re-exporting resolves it).

## Step 5 - Generate the companion Lab Guide

> "Take the existing Lab Guide and update it to match this slide and the trimmed corpus: rename the title,
> update every document-count and time estimate to the new corpus size, replace sample prompts that
> reference documents we cut, and add (a) a short 'What this demo is for' section framing it as a template
> an AI assistant can help deploy in a fixed time box, and (b) a single-tenant BYOT/CDX prerequisite
> warning in the prerequisites checklist. Show me each addition before you add it, then fix the page map."

Two things worth knowing before you ask for this:

- Large `.docx` edits are reliable when the assistant treats them as **verified find-and-replace**: locate
  each anchor string, confirm an exact expected match count, and only write the file once every anchor
  passes verification. Anything ambiguous (duplicate text, styled runs splitting a sentence) should widen
  the anchor rather than guess.
- If the guide has a real Word Table of Contents field (not typed-in page numbers), "fix the page map"
  means opening the file with Word automation and updating the fields/TOC and repaginating - not editing
  page numbers by hand.

## Step 6 - Fork it into a standalone demo repo

> "Create a new public GitHub repo for just this 90-minute demo. Copy the working solution's code into it,
> but trim `data/` down to only the documents we chose in Step 3, swap in the new Lab Guide and slide deck
> under `docs/` and `assets/`, and rewrite the README so there's a single path through the repo - no
> leftover references to the full corpus or the old branding. Push it and show me the final file list."

This repo is exactly that output. Compare its `README.md` and `data/` folder against
[`spetren/renewable-energy-compliance-lab`](https://github.com/spetren/renewable-energy-compliance-lab) to
see precisely what "trim to a single path" looked like in practice.

## Why this order matters

Each step depends on the one before it being verified, not just completed: a deployment plan you never
reviewed, a corpus trim that does not match the slide, or a Lab Guide that still says "15 documents" while
the repo says "6" will surface as confusion in front of a customer, not as an error message. Ask your
assistant to show you the result of each step - a rendered slide, a page of the guide, a file listing on
GitHub - before moving to the next one.
