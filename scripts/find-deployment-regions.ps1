param(
  [Parameter(Mandatory = $true)][string]$SubscriptionId,
  [string]$ModelName = "gpt-4.1-mini",
  [string]$ModelVersion = "2025-04-14",
  [string[]]$Regions = @()
)

$ErrorActionPreference = "Stop"

function Invoke-AzJson {
  param(
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [switch]$AllowFailure
  )

  $output = & az @Arguments 2>$null
  if ($LASTEXITCODE -ne 0) {
    if ($AllowFailure) { return $null }
    throw "Azure CLI command failed: az $($Arguments -join ' ')"
  }

  if (-not $output) { return $null }
  return $output | ConvertFrom-Json
}

& az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) {
  throw "Subscription '$SubscriptionId' is not available in the current Azure CLI login."
}

$account = Invoke-AzJson -Arguments @(
  "account", "show", "--output", "json"
)

if ($account.id -ne $SubscriptionId) {
  throw "Azure CLI selected subscription '$($account.id)' instead of '$SubscriptionId'."
}

$accountLocations = @(Invoke-AzJson -Arguments @(
  "account", "list-locations", "--output", "json"
))
$locationDisplayNames = @{}
foreach ($location in $accountLocations) {
  $locationDisplayNames[$location.name] = $location.displayName
}

$flexLocations = @(Invoke-AzJson -Arguments @(
  "functionapp", "list-flexconsumption-locations",
  "--subscription", $SubscriptionId,
  "--output", "json"
))
$flexLocationNames = @($flexLocations | ForEach-Object { $_.name.ToLowerInvariant() })

if ($Regions.Count -gt 0) {
  $candidateRegions = @($Regions |
    ForEach-Object { $_.Trim().ToLowerInvariant() } |
    Where-Object { $_ -and $_ -in $flexLocationNames } |
    Select-Object -Unique)
} else {
  $preferredRegions = @(
    "northcentralus",
    "eastus2",
    "eastus",
    "centralus",
    "southcentralus",
    "westus3",
    "westus2",
    "westcentralus",
    "westus"
  )
  $candidateRegions = @($preferredRegions | Where-Object { $_ -in $flexLocationNames })
  $candidateRegions += @($flexLocationNames | Where-Object {
    $_ -notin $candidateRegions -and $_ -notmatch "\(stage\)$" -and $_ -notmatch "euap$"
  })
}

if ($candidateRegions.Count -eq 0) {
  throw "None of the requested regions support Azure Functions Flex Consumption."
}

$result = $null
foreach ($region in $candidateRegions) {
  Write-Progress `
    -Activity "Checking Flex Consumption and model availability" `
    -Status $region

  $models = @(Invoke-AzJson -Arguments @(
    "cognitiveservices", "model", "list",
    "--location", $region,
    "--subscription", $SubscriptionId,
    "--output", "json"
  ) -AllowFailure)
  $model = @($models | Where-Object {
    $_.model.name -eq $ModelName -and $_.model.version -eq $ModelVersion
  }) | Select-Object -First 1

  if ($model) {
    $displayName = $locationDisplayNames[$region]
    if (-not $displayName) { $displayName = $region }

    $result = [PSCustomObject]@{
      Region = $region
      DisplayName = $displayName
      FlexConsumption = $true
      Model = $ModelName
      ModelVersion = $ModelVersion
    }
    break
  }
}

Write-Progress -Activity "Checking Flex Consumption and model availability" -Completed

if (-not $result) {
  throw "No regions support both Flex Consumption and model '$ModelName' version '$ModelVersion'. Model catalog availability does not guarantee deployment capacity or quota."
}

$result