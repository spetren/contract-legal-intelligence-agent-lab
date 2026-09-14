# Microsoft Graph app registration

The SharePoint ingestion scripts use delegated Microsoft Graph access. A participant signs in through device-code authentication, and the scripts act with that user's existing SharePoint permissions.

Create this registration in the Microsoft Entra tenant that owns the SharePoint document library. For this lab, the Azure subscription and SharePoint library are expected to use the same tenant.

## Recommended: prerequisite script

The script is idempotent: it creates the registration on the first run and validates or repairs the same named registration on later runs. It will not change an app registration if the supplied subscription belongs to a different tenant.

```powershell
$tenantId = "<demo-tenant-id>"
$subscriptionId = "<subscription-id>"

$graphRegistration = .\scripts\register-graph-client.ps1 `
  -TenantId $tenantId `
  -SubscriptionId $subscriptionId | ConvertFrom-Json

$graphClientId = $graphRegistration.graphClientId
```

The script performs these steps visibly:

1. Selects the supplied Azure subscription, signing in to the supplied tenant if needed.
2. Verifies that the selected subscription belongs to that tenant.
3. Creates or locates the single-tenant `RECCIA Graph Ingestion` app registration.
4. Enables public-client device-code authentication.
5. Configures delegated `Files.Read.All` and `Files.ReadWrite.All` permissions.
6. Creates the tenant-local service principal and validates the result.

No client secret is created or required. The text ingestion script requests `Files.Read.All`; visual ingestion requests `Files.ReadWrite.All` because it uploads extracted images to SharePoint.

The delegated permissions do not normally require tenant-wide admin consent. If the tenant's user-consent policy blocks sign-in, a tenant administrator can rerun the script with `-GrantAdminConsent` or grant consent in the portal.

## Manual: Microsoft Entra admin center

Use this path when participants need to practice the underlying identity configuration or when tenant policy prevents CLI-based registration.

1. Open the [Microsoft Entra admin center](https://entra.microsoft.com) and switch to the tenant that owns the SharePoint library.
2. Go to **Identity > Applications > App registrations > New registration**.
3. Enter `RECCIA Graph Ingestion`, select **Accounts in this organizational directory only**, leave **Redirect URI** empty, and register the app.
4. Open **Authentication**, set **Allow public client flows** to **Yes**, and save.
5. Open **API permissions > Add a permission > Microsoft Graph > Delegated permissions**.
6. Add `Files.Read.All` and `Files.ReadWrite.All`.
7. Grant admin consent only if required by the tenant's consent policy.
8. On **Overview**, copy **Directory (tenant) ID** and **Application (client) ID**. Do not create a client secret.

## Run ingestion

Pass both IDs explicitly so PowerShell does not prompt for omitted mandatory parameters:

```powershell
.\scripts\run-text-ingestion.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -GraphClientId $graphClientId `
  -ResourceGroupName "<resource-group>" `
  -SearchServiceName "<search-service>" `
  -DocumentIntelligenceAccountName "<doc-intel-account>" `
  -DriveId "<sharepoint-drive-id>"
```

The first run displays a device-login URL and code. Sign in as a user who can access the target SharePoint library.