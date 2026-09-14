[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$TenantId,
  [Parameter(Mandatory = $true)][string]$SubscriptionId,
  [string]$AppDisplayName = "RECCIA Graph Ingestion",
  [switch]$GrantAdminConsent
)

$ErrorActionPreference = "Stop"
$graphResourceAppId = "00000003-0000-0000-c000-000000000000"
$permissions = @(
  @{ Name = "Files.Read.All"; Id = "df85f4d6-205c-4ac5-a5ea-6bf408dba283" },
  @{ Name = "Files.ReadWrite.All"; Id = "863451e7-0667-486c-a5d6-d135439485f0" }
)

Write-Host "[1/4] Verifying the Azure CLI tenant and subscription"
az account set --subscription $SubscriptionId 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Host "The subscription is not available in the current Azure CLI session. Sign in to tenant '$TenantId'."
  az login --tenant $TenantId --allow-no-subscriptions --output none
  if ($LASTEXITCODE -ne 0) {
    throw "Azure CLI sign-in failed for tenant '$TenantId'."
  }

  az account set --subscription $SubscriptionId
  if ($LASTEXITCODE -ne 0) {
    throw "Subscription '$SubscriptionId' is not available in tenant '$TenantId'."
  }
}

$account = az account show --subscription $SubscriptionId --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $account) {
  throw "Could not read the active Azure CLI account."
}
if ($account.tenantId -ne $TenantId) {
  throw "Tenant mismatch. Subscription '$SubscriptionId' belongs to tenant '$($account.tenantId)', not '$TenantId'. No app registration was changed."
}

Write-Host "  Tenant:       $($account.tenantId)"
Write-Host "  Subscription: $($account.id)"
Write-Host "  Signed in as: $($account.user.name)"

Write-Host "[2/4] Creating or locating the Microsoft Entra app registration"
$escapedDisplayName = $AppDisplayName.Replace("'", "''")
$matchingApps = @(
  az ad app list `
    --filter "displayName eq '$escapedDisplayName'" `
    --query "[?displayName=='$AppDisplayName']" `
    --output json | ConvertFrom-Json
)
if ($LASTEXITCODE -ne 0) {
  throw "Could not query app registrations in tenant '$TenantId'."
}
if ($matchingApps.Count -gt 1) {
  throw "More than one app registration is named '$AppDisplayName'. Use -AppDisplayName with a unique name."
}

if ($matchingApps.Count -eq 0) {
  $manifestPath = Join-Path $env:TEMP "reccia-graph-permissions-$([guid]::NewGuid().ToString('N')).json"
  try {
    @(
      @{
        resourceAppId = $graphResourceAppId
        resourceAccess = @(
          $permissions | ForEach-Object { @{ id = $_.Id; type = "Scope" } }
        )
      }
    ) | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding utf8

    $app = az ad app create `
      --display-name $AppDisplayName `
      --sign-in-audience AzureADMyOrg `
      --is-fallback-public-client true `
      --required-resource-accesses "@$manifestPath" `
      --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $app) {
      throw "Could not create app registration '$AppDisplayName'."
    }
  } finally {
    Remove-Item $manifestPath -Force -ErrorAction SilentlyContinue
  }
  Write-Host "  Created app registration '$AppDisplayName'."
} else {
  $app = $matchingApps[0]
  Write-Host "  Reusing app registration '$AppDisplayName'."

  az ad app update --id $app.appId --is-fallback-public-client true --output none
  if ($LASTEXITCODE -ne 0) {
    throw "Could not enable public client flow for app '$($app.appId)'."
  }

  $configuredPermissionIds = @(
    $app.requiredResourceAccess |
      Where-Object { $_.resourceAppId -eq $graphResourceAppId } |
      ForEach-Object { $_.resourceAccess } |
      ForEach-Object { $_.id }
  )
  $missingPermissions = @($permissions | Where-Object { $_.Id -notin $configuredPermissionIds })
  if ($missingPermissions.Count -gt 0) {
    $apiPermissions = @($missingPermissions | ForEach-Object { "$($_.Id)=Scope" })
    az ad app permission add `
      --id $app.appId `
      --api $graphResourceAppId `
      --api-permissions @apiPermissions `
      --output none
    if ($LASTEXITCODE -ne 0) {
      throw "Could not add Microsoft Graph delegated permissions to app '$($app.appId)'."
    }
  }
}

Write-Host "[3/4] Ensuring the tenant-local service principal exists"
az ad sp show --id $app.appId --output none 2>$null
if ($LASTEXITCODE -ne 0) {
  az ad sp create --id $app.appId --output none
  if ($LASTEXITCODE -ne 0) {
    throw "Could not create the service principal for app '$($app.appId)'."
  }
}

if ($GrantAdminConsent) {
  Write-Host "  Granting tenant-wide admin consent"
  az ad app permission admin-consent --id $app.appId --output none
  if ($LASTEXITCODE -ne 0) {
    throw "Admin consent failed. Sign in as a tenant administrator or omit -GrantAdminConsent and consent during device sign-in."
  }
}

Write-Host "[4/4] Validating the app registration"
$validatedApp = az ad app show --id $app.appId --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $validatedApp) {
  throw "Could not validate app registration '$($app.appId)'."
}
$validatedPermissionIds = @(
  $validatedApp.requiredResourceAccess |
    Where-Object { $_.resourceAppId -eq $graphResourceAppId } |
    ForEach-Object { $_.resourceAccess } |
    ForEach-Object { $_.id }
)
$missingPermissionNames = @($permissions | Where-Object { $_.Id -notin $validatedPermissionIds } | ForEach-Object { $_.Name })
if (-not $validatedApp.isFallbackPublicClient -or $missingPermissionNames.Count -gt 0) {
  throw "App validation failed. Public client: $($validatedApp.isFallbackPublicClient); missing permissions: $($missingPermissionNames -join ', ')."
}

Write-Host "Microsoft Graph client registration is ready. No client secret is required."
[PSCustomObject]@{
  tenantId = $account.tenantId
  subscriptionId = $account.id
  appDisplayName = $validatedApp.displayName
  graphClientId = $validatedApp.appId
  delegatedPermissions = @($permissions.Name)
  adminConsentGrantedByScript = [bool]$GrantAdminConsent
} | ConvertTo-Json -Depth 3