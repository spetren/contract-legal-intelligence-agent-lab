param(
  [Parameter(Mandatory = $true)][string]$SubscriptionId,
  [Parameter(Mandatory = $true)][string]$DriveId,
  [string]$DocumentIndexPath = "data\document-index.csv",
  [string]$SourceFolder = "Source Documents",
  [string]$LocalDownloadFolder = "data\source-documents",
  [switch]$IncludeFailedRows
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$indexPath = Join-Path $repo $DocumentIndexPath
$downloadFolder = Join-Path $repo $LocalDownloadFolder

if (-not (Test-Path $indexPath)) {
  throw "Document index not found: $indexPath"
}

New-Item -ItemType Directory -Force -Path $downloadFolder | Out-Null
az account set --subscription $SubscriptionId
$graphToken = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv
$headers = @{ Authorization = "Bearer $graphToken" }

function ConvertTo-GraphPathSegment {
  param([string]$Value)
  return [uri]::EscapeDataString($Value)
}

function ConvertTo-GraphPath {
  param([string]$Path)
  return (($Path -split "/") | Where-Object { $_ } | ForEach-Object { ConvertTo-GraphPathSegment $_ }) -join "/"
}

function Ensure-GraphFolder {
  param(
    [string]$DriveId,
    [string]$FolderPath
  )

  $current = ""
  foreach ($segment in (($FolderPath -split "/") | Where-Object { $_ })) {
    $target = if ($current) { "$current/$segment" } else { $segment }
    $encodedTarget = ConvertTo-GraphPath $target
    $getUri = "https://graph.microsoft.com/v1.0/drives/$DriveId/root:/$encodedTarget"
    try {
      Invoke-RestMethod -Method Get -Uri $getUri -Headers $headers | Out-Null
      $current = $target
      continue
    } catch {
      $body = @{
        name = $segment
        folder = @{}
        "@microsoft.graph.conflictBehavior" = "fail"
      } | ConvertTo-Json

      if ($current) {
        $parent = ConvertTo-GraphPath $current
        $childrenUri = "https://graph.microsoft.com/v1.0/drives/$DriveId/root:/$parent`:/children"
      } else {
        $childrenUri = "https://graph.microsoft.com/v1.0/drives/$DriveId/root/children"
      }

      Invoke-RestMethod -Method Post -Uri $childrenUri -Headers ($headers + @{ "Content-Type" = "application/json" }) -Body $body | Out-Null
      $current = $target
    }
  }
}

function Invoke-DownloadWithRetry {
  param(
    [string]$Url,
    [string]$Path
  )

  for ($attempt = 0; $attempt -lt 5; $attempt++) {
    try {
      Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -TimeoutSec 300
      return
    } catch {
      if ($attempt -eq 4) { throw }
      Start-Sleep -Seconds ([Math]::Min([Math]::Pow(2, $attempt), 20))
    }
  }
}

function Invoke-UploadWithRetry {
  param(
    [string]$DriveId,
    [string]$TargetPath,
    [string]$LocalPath
  )

  $encodedTarget = ConvertTo-GraphPath $TargetPath
  $uri = "https://graph.microsoft.com/v1.0/drives/$DriveId/root:/$encodedTarget`:/content"
  $contentType = if ($LocalPath.EndsWith(".docx")) {
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
  } elseif ($LocalPath.EndsWith(".pptx")) {
    "application/vnd.openxmlformats-officedocument.presentationml.presentation"
  } else {
    "application/pdf"
  }

  for ($attempt = 0; $attempt -lt 5; $attempt++) {
    try {
      Invoke-RestMethod -Method Put -Uri $uri -Headers ($headers + @{ "Content-Type" = $contentType }) -InFile $LocalPath | Out-Null
      return
    } catch {
      if ($attempt -eq 4) { throw }
      Start-Sleep -Seconds ([Math]::Min([Math]::Pow(2, $attempt), 20))
    }
  }
}

Ensure-GraphFolder -DriveId $DriveId -FolderPath $SourceFolder

$rows = Import-Csv $indexPath
if (-not $IncludeFailedRows) {
  $rows = $rows | Where-Object { $_.Status -eq "Downloaded" }
}

$summary = @()
foreach ($row in $rows) {
  $fileName = $row.File
  $url = $row.Url
  if (-not $fileName -or -not $url) {
    continue
  }

  $localPath = Join-Path $downloadFolder $fileName
  if (-not (Test-Path $localPath)) {
    Write-Host "Downloading $fileName"
    Invoke-DownloadWithRetry -Url $url -Path $localPath
  } else {
    Write-Host "Using cached $fileName"
  }

  Write-Host "Uploading $fileName to SharePoint"
  Invoke-UploadWithRetry -DriveId $DriveId -TargetPath "$SourceFolder/$fileName" -LocalPath $localPath

  $summary += [PSCustomObject]@{
    file = $fileName
    category = $row.Category
    technology = $row.Technology
    source = $row.Source
    url = $url
  }
}

$summaryPath = Join-Path $repo "data\bootstrap-summary.json"
$summary | ConvertTo-Json -Depth 5 | Set-Content -Path $summaryPath -Encoding utf8
Write-Host "Bootstrapped $($summary.Count) documents into SharePoint folder '$SourceFolder'."
Write-Host "Summary: $summaryPath"
