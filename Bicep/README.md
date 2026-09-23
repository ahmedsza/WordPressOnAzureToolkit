# Azure WordPress Bicep Deployment

This template deploys a WordPress container to Azure App Service with Azure Database for MySQL Flexible Server, a virtual network, private DNS, a storage account and blob container, a user-assigned managed identity, and Azure Communication Services email resources.

## Prerequisites

- Azure CLI 2.56 or later, authenticated with `az login`.
- The Azure CLI Bicep integration installed with `az bicep install` or updated with `az bicep upgrade`.
- Permission to create the listed Azure resources in the target resource group.
- `Owner` or `User Access Administrator` permission at the target scope. The template creates role assignments for the managed identity.

## Environment profiles

Use one committed, non-secret profile per environment:

| Environment | App Service plan | MySQL HA | Redis HA | Storage | Soft delete | WAF |
| --- | --- | --- | --- | --- | --- | --- |
| `dev` | P1V3, 1 instance, no zone redundancy | Disabled, Burstable | Disabled | LRS | 7 days | Detection |
| `test` | P1V3, 2 instances, no zone redundancy | SameZone, General Purpose | Enabled | ZRS | 14 days | Detection |
| `prod` | P1V3, 3 instances, zone redundant | ZoneRedundant, General Purpose | Enabled | RA-GRS | 30 days | Prevention |

Only `dev` and `prod` ship as sample profiles: [wordpress-deployment-arm-template.dev.parameters.sample.json](wordpress-deployment-arm-template.dev.parameters.sample.json) and [wordpress-deployment-arm-template.prod.parameters.sample.json](wordpress-deployment-arm-template.prod.parameters.sample.json). Copy the one closest to your target environment to a git-ignored `*.parameters.json` file, set `environmentName` accordingly (`dev`, `test`, or `prod`), and fill in the real values. The samples contain password placeholders but no real passwords, Redis keys, or other secrets.

`environmentName` is restricted to `dev`, `test`, or `prod` and is applied as the `Environment` tag. App Service zone redundancy (`appServiceZoneRedundant`) and MySQL HA (`mysqlHighAvailabilityMode`) are independent. Network prefixes, Blob/container soft-delete retention, Front Door probe path/interval, and WAF mode are explicit profile parameters.

Storage, Key Vault, Redis, private endpoints, the private MySQL topology, and Front Door-origin restrictions remain hardened in every environment; no profile makes these settings optional.

## Required parameters

The main template is `wordpress-deployment-arm-template.bicep`.

| Parameter | Description |
| --- | --- |
| `name` | Prefix for deployed resources and the App Service site name. Use lowercase letters, numbers, and hyphens. |
| `environmentName` | Deployment environment: `dev`, `test`, or `prod`. |
| `wordpressAdminEmail` | Email address used by WordPress. |
| `wordpressPassword` | Secure WordPress administrator password. |
| `serverPassword` | Secure MySQL administrator password. |

The deployment creates a Log Analytics workspace and workspace-based Application Insights component. Diagnostic settings use the workspace automatically, and the App Service receives the Application Insights connection string automatically.

## Validate

From this directory, build the complete module tree:

```powershell
az bicep build --file wordpress-deployment-arm-template.bicep
```

[deployDev.ps1](deployDev.ps1) and [deployProd.ps1](deployProd.ps1) are example end-to-end deployment scripts. Each hardcodes its own `$resourceGroupName`, `$parameterFileName`, and `$location` at the top of the file; edit those values (or copy the script) before running:

```powershell
.\deployDev.ps1
```

Each script creates the resource group and runs `az deployment group create` directly — it does not run `validate` or `what-if` first. For production or unattended changes, run `az deployment group validate` and `az deployment group what-if` yourself against the template and parameter file before deploying, especially to check SKU availability, quota, zone redundancy, and any resource replacements.

Both example scripts also **delete the resource group and purge its Key Vault** at the end of the run, which is only appropriate for disposable test cycles. Remove those final `az group delete` / `az keyvault purge` lines from your own copy before using it against an environment you intend to keep.

Do not commit deployment parameter files containing real passwords or other secrets. Use a local, ignored copy for values that must remain confidential.

Use a short, globally unique `<site-name>` such as `contoso-wp-dev`. The template appends a deterministic suffix to resource names where Azure requires uniqueness.

## Use after deployment

Get the Azure Front Door hostname from the completed deployment and use it to finish the WordPress setup. Do not initialize WordPress through the App Service default hostname because WordPress can persist that origin as its canonical URL.

```powershell
az deployment group show `
  --resource-group <resource-group-name> `
  --name <deployment-name> `
  --query properties.outputs.frontDoorEndpointHostName.value `
  --output tsv
```

Open `https://<front-door-hostname>/`. The App Service receives `AFD_ENABLED=true` and the hostname-only `AFD_ENDPOINT` setting required by the Microsoft WordPress image. After a deployment or configuration change, restart the Web App and allow up to approximately 15 minutes for the image to apply the Front Door URL to WordPress.

For an existing site that still generates `azurewebsites.net` URLs, redeploy this template, restart the Web App, wait for configuration to converge, and then verify the home page, posts, categories, author pages, admin login, canonical links, redirects, and asset URLs through Front Door. Keep both AFD settings in place after convergence.

If URLs still point to the origin after that process, back up the database and inspect `wp-config.php` plus `wp option get home` and `wp option get siteurl` through the App Service SSH/Kudu environment. Use WP-CLI option updates or search-replace for the exact old and new URLs if repair is required. Do not use blind SQL because WordPress content can contain serialized values.

The MySQL server is configured for private VNet access and MySQL 8.4. Access occurs from App Service through VNet integration and managed identity configuration. Key Vault, Blob Storage, and Azure Managed Redis use private endpoints and private DNS zones; the Web App itself deliberately has no private endpoint.

Azure Front Door Standard with a managed WAF policy is the public entry point. The App Service accepts requests only from the `AzureFrontDoor.Backend` service tag containing the specific `X-Azure-FDID` header for this deployment. Direct access to the App Service hostname should return `403`.

## Private media with Front Door Standard

Azure Front Door Standard cannot connect to a private Blob Storage origin. This template therefore keeps the media account private and disables anonymous and Shared Key access. WordPress reaches Blob Storage through its managed identity and private endpoint.

For browser delivery, configure the WordPress media plugin to either proxy media through the Web App or create short-lived user-delegation SAS links. Do not point browser media URLs directly at the private Blob endpoint. The template provides the Redis plugin password through the `REDIS_PASSWORD` and `WP_REDIS_PASSWORD` Key Vault references; confirm the selected WordPress plugin uses one of those settings or map them in its configuration.

## Modules

The root template composes focused modules from the `modules/` directory:

- `modules/app-service-resources.bicep`
- `modules/server-parameters-aad-auth-only.bicep`
- `modules/storage-resources.bicep`
- `modules/storage-role-assignment-managed-identity.bicep`
- `modules/subnet-resources.bicep`
- `modules/add-admins.bicep`

## Notes

The root template builds without Bicep diagnostics. Review the resource SKU, public-access, retention, and backup defaults before using it in production.