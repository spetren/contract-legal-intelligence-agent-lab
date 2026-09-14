param(
  [Parameter(Mandatory = $true)][string]$SubscriptionId,
  [Parameter(Mandatory = $true)][string]$TenantId,
  [Parameter(Mandatory = $true)][string]$GraphClientId,
  [Parameter(Mandatory = $true)][string]$ResourceGroupName,
  [Parameter(Mandatory = $true)][string]$SearchServiceName,
  [Parameter(Mandatory = $true)][string]$DocumentIntelligenceAccountName,
  [Parameter(Mandatory = $true)][string]$DriveId,
  [string]$SourceFolder = "Source Documents",
  [string]$IndexName = "reccia-documents"
)
 
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$python = Join-Path $repo ".venv\Scripts\python.exe"
if (-not (Test-Path $python)) { $python = "python" }
 
az account set --subscription $SubscriptionId
 
& $python (Join-Path $repo "ingest_sharepoint_to_search.py") `
  --subscription $SubscriptionId `
  --tenant-id $TenantId `
  --graph-client-id $GraphClientId `
  --resource-group $ResourceGroupName `
  --search-service $SearchServiceName `
  --doc-intel-account $DocumentIntelligenceAccountName `
  --drive-id $DriveId `
  --folder $SourceFolder `
  --index-name $IndexName

if ($LASTEXITCODE -ne 0) {
  throw "Text ingestion failed with exit code $LASTEXITCODE."
}