$ErrorActionPreference = "Stop"
$subscriptionId = "00000000-0000-0000-0000-000000000001"
$mockState = @{
  FlexRegions = @("northcentralus", "eastus2", "eastus", "westus")
  ModelRegions = @("northcentralus", "eastus2", "eastus", "westus")
  QueriedRegions = [System.Collections.Generic.List[string]]::new()
}

function az {
  $arguments = @($args)
  $global:LASTEXITCODE = 0
  $command = ($arguments | Select-Object -First 3) -join " "
  switch -Wildcard ($command) {
    "account set *" { return }
    "account show *" { return (@{ id = $subscriptionId } | ConvertTo-Json) }
    "account list-locations *" {
      return (ConvertTo-Json -InputObject @(
        @{ name = "northcentralus"; displayName = "North Central US" }
        @{ name = "eastus2"; displayName = "East US 2" }
        @{ name = "eastus"; displayName = "East US" }
        @{ name = "westus"; displayName = "West US" }
      ))
    }
    "functionapp list-flexconsumption-locations *" {
      return (ConvertTo-Json -InputObject @($mockState.FlexRegions | ForEach-Object { @{ name = $_ } }))
    }
    "cognitiveservices model list" {
      $region = $arguments[[array]::IndexOf($arguments, "--location") + 1]
      $mockState.QueriedRegions.Add($region)
      if ($region -in $mockState.ModelRegions) {
        return (ConvertTo-Json -Depth 4 -InputObject @(
          @{ model = @{ name = "gpt-4.1-mini"; version = "2025-04-14" } }
        ))
      }
      return "[]"
    }
    default { throw "Unexpected Azure CLI call in offline test: $command" }
  }
}

$finder = Join-Path $PSScriptRoot "..\scripts\find-deployment-regions.ps1"

function Assert-RegionFailure {
  param([hashtable]$Parameters, [string]$ExpectedMessage)
  $message = $null
  try {
    & $finder -SubscriptionId $subscriptionId @Parameters | Out-Null
  } catch {
    $message = $_.Exception.Message
  }
  if (-not $message -or $message -notlike $ExpectedMessage) {
    throw "Expected failure '$ExpectedMessage'; received '$message'."
  }
}

$result = & $finder -SubscriptionId $subscriptionId
if ($result.Region -ne "eastus" -or $result.VisionCaptions -ne $true -or $result.FlexConsumption -ne $true) {
  throw "Default discovery must skip non-caption regions and return East US with all capability flags."
}
if ($result.DisplayName -ne "East US" -or $result.ModelVersion -ne "2025-04-14") {
  throw "Existing region output fields must be preserved."
}
if (($mockState.QueriedRegions -join ",") -ne "eastus") {
  throw "Regions without caption support should not be queried for models."
}

$mockState.QueriedRegions.Clear()
Assert-RegionFailure -Parameters @{ Regions = @("northcentralus") } -ExpectedMessage "*Vision*caption*"
if ($mockState.QueriedRegions.Count -ne 0) { throw "Explicit non-caption region was not rejected early." }

$result = & $finder -SubscriptionId $subscriptionId -Regions @(" WESTUS ", "eastus", "westus")
if ($result.Region -ne "westus") { throw "Explicit region order and normalization must be preserved." }

$mockState.ModelRegions = @("eastus")
$result = & $finder -SubscriptionId $subscriptionId -Regions @("westus", "eastus")
if ($result.Region -ne "eastus") { throw "Must fall back when the first caption region lacks the model." }

Assert-RegionFailure -Parameters @{ Regions = @("eastus"); ModelVersion = "unavailable-version" } -ExpectedMessage "*No regions support*"
Assert-RegionFailure -Parameters @{ Regions = @("eastus"); ModelName = "unavailable-model" } -ExpectedMessage "*No regions support*"

$mockState.FlexRegions = @("westus")
Assert-RegionFailure -Parameters @{ Regions = @("eastus") } -ExpectedMessage "*Flex Consumption*"

$mockState.FlexRegions = @("northcentralus", "eastus2")
Assert-RegionFailure -Parameters @{} -ExpectedMessage "*Vision*caption*"

Write-Host "PASS: eight region checks cover caption gating, existing output, order, model fallback, and failures."
