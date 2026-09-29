$ErrorActionPreference = "Stop"
$mockState = @{ App = $null }
$subscriptionId = "00000000-0000-0000-0000-000000000001"
$tenantId = "00000000-0000-0000-0000-000000000002"

function az {
  $arguments = @($args)
  $global:LASTEXITCODE = 0
  $command = ($arguments | Select-Object -First 3) -join " "

  switch -Wildcard ($command) {
    "account set *" { return }
    "account show *" {
      return (@{
        id = $subscriptionId
        tenantId = $tenantId
        user = @{ name = "test@example.invalid" }
      } | ConvertTo-Json)
    }
    "ad app list" { return "[]" }
    "ad app create" {
      $manifestArgument = $arguments[[array]::IndexOf($arguments, "--required-resource-accesses") + 1]
      $json = Get-Content -LiteralPath $manifestArgument.Substring(1) -Raw
      if (-not $json.TrimStart().StartsWith("[")) {
        throw "The first-run permission manifest must be a JSON array, even with only one API."
      }
      $permissions = @($json | ConvertFrom-Json)
      if ($permissions.Count -ne 1 -or $permissions[0].resourceAppId -ne "00000003-0000-0000-c000-000000000000") {
        throw "Expected exactly one Microsoft Graph permission entry."
      }
      $scopes = @($permissions[0].resourceAccess)
      foreach ($id in @("df85f4d6-205c-4ac5-a5ea-6bf408dba283", "863451e7-0667-486c-a5d6-d135439485f0")) {
        if (@($scopes | Where-Object { $_.id -eq $id -and $_.type -eq "Scope" }).Count -ne 1) {
          throw "Missing or incorrect delegated permission: $id"
        }
      }
      if ($scopes.Count -ne 2) { throw "Unexpected extra permissions." }
      $mockState.App = @{
        appId = "00000000-0000-0000-0000-000000000003"
        displayName = "Test Graph Ingestion"
        isFallbackPublicClient = $true
        requiredResourceAccess = $permissions
      }
      return ($mockState.App | ConvertTo-Json -Depth 10)
    }
    "ad sp show" { return }
    "ad app show" { return ($mockState.App | ConvertTo-Json -Depth 10) }
    default { throw "Unexpected Azure CLI call in offline test: $command" }
  }
}

$registrationScript = Join-Path $PSScriptRoot "..\scripts\register-graph-client.ps1"
$result = & $registrationScript -TenantId $tenantId -SubscriptionId $subscriptionId -AppDisplayName "Test Graph Ingestion" |
  ConvertFrom-Json
if ($result.graphClientId -ne $mockState.App.appId -or $result.adminConsentGrantedByScript) {
  throw "Unexpected registration output."
}
Write-Host "PASS: first-run Graph registration preserves the permission array and both delegated scopes."
