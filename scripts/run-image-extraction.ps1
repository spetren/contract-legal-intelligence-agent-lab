param(
  [Parameter(Mandatory = $true)][string]$SubscriptionId,
  [Parameter(Mandatory = $true)][string]$ResourceGroupName,
  [Parameter(Mandatory = $true)][string]$SearchServiceName,
  [Parameter(Mandatory = $true)][string]$VisionAccountName,
  [Parameter(Mandatory = $true)][string]$DriveId,
  [string]$SourceFolder = "Source Documents",
  [string]$ImagesFolder = "Extracted Images",
  [string]$IndexName = "reccia-images",
  [switch]$RenderPages,
  [switch]$SkipExistingIndexed,
  [int]$Dpi = 120,
  [int]$JpegQuality = 72,
  [int]$BatchSize = 100
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$python = Join-Path $repo ".venv\Scripts\python.exe"
if (-not (Test-Path $python)) { $python = "python" }

az account set --subscription $SubscriptionId

$args = @(
  (Join-Path $repo "extract_images_to_search.py"),
  "--subscription", $SubscriptionId,
  "--resource-group", $ResourceGroupName,
  "--search-service", $SearchServiceName,
  "--vision-account", $VisionAccountName,
  "--drive-id", $DriveId,
  "--source-folder", $SourceFolder,
  "--images-folder", $ImagesFolder,
  "--index-name", $IndexName,
  "--dpi", $Dpi,
  "--jpeg-quality", $JpegQuality,
  "--batch-size", $BatchSize
)

if ($RenderPages) { $args += "--render-pages" }
if ($SkipExistingIndexed) { $args += "--skip-existing-indexed" }

& $python @args

