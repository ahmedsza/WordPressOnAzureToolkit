# Azure App Service WordPress Backup

`Backup-AzureWordpress.ps1` backs up a WordPress site hosted on Azure Linux App Service to either a local directory or an Azure Blob Storage container. It exports the WordPress database, optionally archives the site files, downloads the artifacts through the authenticated tunnel, and validates their SHA-256 checksums before completing the selected destination transfer.

The script does not use Kudu VFS for file transfer. It opens an Azure remote-connection tunnel, which authenticates to the SCM endpoint with the app's publishing credentials, then connects to the container over SSH, runs WP-CLI in the same login-shell context used by App Service Web SSH, and transfers the backup through that tunnel with SFTP. Because the tunnel goes through SCM, see [Access Restrictions](#access-restrictions). Blob uploads use Azure CLI and a caller-provided container SAS URI.

Before connecting, the script checks the SCM access restrictions and basic-authentication policy, and temporarily remediates only what would block the tunnel, reverting the change once the backup finishes. See [Access Restrictions](#access-restrictions) for details.

## Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Backup Output](#backup-output)
- [Access Restrictions](#access-restrictions)
- [How It Works](#how-it-works)
- [Parameters](#parameters)
- [Examples](#examples)
- [Remote Retention and Cleanup](#remote-retention-and-cleanup)
- [Troubleshooting](#troubleshooting)
- [Security Notes](#security-notes)
- [Disaster Recovery Runbook Example](#disaster-recovery-runbook-example)
- [Related Scripts](#related-scripts)

## Prerequisites

Run the script from PowerShell 7 or later on the computer where you want the backup stored.

### Required software

1. **PowerShell 7+**

   Verify the version:

   ```powershell
   $PSVersionTable.PSVersion
   ```

2. **Azure CLI**

   Install instructions: <https://aka.ms/installazurecli>

   Authenticate before running a backup:

   ```powershell
   az login
   az account show
   ```

3. **Posh-SSH PowerShell module**

   Install it once for the current Windows user:

   ```powershell
   Install-Module Posh-SSH -Scope CurrentUser
   ```

   If PowerShell asks whether to trust PSGallery, select `Y`.

### Required Azure access

The Azure identity running the script needs to read the app **and list its publishing credentials**, because the tunnel authenticates with them. `Contributor` or `Website Contributor` on the app or its resource group is sufficient; the built-in `Reader` role is **not**, because it cannot call `Microsoft.Web/sites/config/list/action`.

The target must be a Linux App Service WordPress container with:

- WP-CLI installed and usable from `/home/site/wwwroot`.
- WordPress configured to access its database.
- SSH available through Azure App Service remote connection.
- Enough free persistent storage under `/home/backups` for the temporary database dump and file archive.

The script starts an `az webapp create-remote-connection` tunnel locally. This authenticates using the current Azure CLI login; it does not require opening an inbound public SSH port on the app.

### Execution policy

If Windows blocks the local script because it is unsigned, run it in a one-time PowerShell 7 process with an execution-policy bypass:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Backup-AzureWordpress.ps1 -ResourceGroup $RG -AppName $APP_NAME -Destination Local -LocalPath D:\backup
```

The bypass affects only that child PowerShell process. It does not modify the machine-wide or user execution policy.

## Quick Start

From this folder, set the App Service details and run a full backup:

```powershell
$RG = 'ahms-wg-prod-rg'
$APP_NAME = 'wordpressexampleprod-wp-prod-6lqeuzsy4wou4'

.\Backup-AzureWordpress.ps1 `
    -ResourceGroup $RG `
    -AppName $APP_NAME `
    -Destination Local `
    -LocalPath D:\backup
```

The backup is stored in a timestamped directory such as:

```text
D:\backup\wordpressexampleprod-wp-prod-6lqeuzsy4wou4-20260831-130035-511
```

The script returns a PowerShell object with `Destination`, `BackupPath`, `BlobPrefix`, `RemotePath`, `DatabaseOnly`, and `ChecksumVerified` fields. Local mode sets `BackupPath`; Blob mode sets `BlobPrefix`. A successful backup has `ChecksumVerified` set to `True`.

## Backup Output

A full backup creates these local artifacts:

| File | Description |
| --- | --- |
| `db.sql.gz` | Gzip-compressed SQL database export made by `wp db export`. It includes `DROP TABLE` statements and uses a single transaction where supported. |
| `files.tar.gz` | Gzip-compressed archive containing `wp-content` and `wp-config.php`. Omitted with `-DatabaseOnly`. |
| `manifest.txt` | Backup metadata: app name, UTC timestamp, WordPress/PHP versions, site URLs, and database size. |
| `plugins.csv` | WP-CLI plugin inventory. |
| `themes.csv` | WP-CLI theme inventory. |
| `SHA256SUMS` | SHA-256 digests created on the container for every downloaded backup artifact. |

The file archive excludes transient or high-churn paths to avoid unnecessary size and archive failures:

- `wp-content/cache`
- `wp-content/upgrade`
- `*.log`

The database export excludes `wp_actionscheduler_logs` by default. Supply `-ExcludeTables` to replace this default list.

## How It Works

1. The script validates PowerShell, Azure CLI authentication, and the Posh-SSH module.
2. It finds an unused loopback port, starting at `2222` by default.
3. It starts `az webapp create-remote-connection` as a child process and waits until the local tunnel accepts TCP connections.
4. It authenticates over the tunnel to `root@127.0.0.1` using the App Service Linux container SSH credentials.
5. It runs WP-CLI through `bash -lc`, a Bash login shell. This is important: the login shell loads App Service settings such as `DATABASE_HOST`, `DATABASE_NAME`, managed-identity settings, and other WordPress configuration that are absent from a plain non-interactive SSH command.
6. It writes the database dump, optional file archive, inventories, manifest, and SHA-256 manifest to `/home/backups/<UTC timestamp>` in App Service persistent storage.
7. It closes the command SSH session and opens a Posh-SSH SFTP session through the same local tunnel to download each expected artifact.
8. It recomputes each local SHA-256 hash and compares it with `SHA256SUMS`.
9. After all hashes match, it removes the remote staging directory unless `-KeepRemote` is supplied.
10. Its `finally` block closes SSH/SFTP sessions, stops the Azure tunnel process, and deletes temporary local tunnel logs even if a command fails.

## Parameters

| Parameter | Required | Default | Description |
| --- | --- | --- | --- |
| `-ResourceGroup` | Yes | None | Azure resource group containing the App Service. |
| `-AppName` | Yes | None | Azure App Service name. |
| `-Slot` | No | None | Deployment slot name. The tunnel connects to this slot. |
| `-SubscriptionId` | No | Current Azure CLI subscription | Subscription to select before connecting. |
| `-Destination` | Yes | None | Selects `Local` or `Blob` output. |
| `-LocalPath` | Local mode | None | Parent directory for the timestamped local backup directory. |
| `-BlobSasUri` | Blob mode | None | HTTPS container SAS URI used for Blob upload. |
| `-ExcludeTables` | No | `wp_actionscheduler_logs` | One or more tables passed to WP-CLI's `--exclude_tables` option. |
| `-DatabaseOnly` | No | Off | Creates only the database, manifest, inventory, and checksum artifacts. No `files.tar.gz` is made. |
| `-KeepRemote` | No | Off | Retains `/home/backups/<timestamp>` after local checksum validation. |
| `-Port` | No | `2222` | First loopback port to try for the Azure tunnel. The script increments it if occupied. |
| `-TunnelTimeoutSeconds` | No | `60` | Maximum time to wait for the tunnel to start listening. |
| `-CommandTimeoutSeconds` | No | `3600` | Maximum time allowed for WP-CLI export/archive operations and remote cleanup. |
| `-TransferTimeoutSeconds` | No | `3600` | Maximum connection and operation timeout for the SFTP download. |
| `-SkipAccessRestrictionCheck` | No | Off | Skips the SCM access and basic-authentication preflight. |
| `-SkipAccessRemediation` | No | Off | Reports blocking SCM settings but does not change them. |
| `-ScmAllowIpAddress` | No | Auto-detected | IP to allow on the SCM site instead of detecting this machine's public egress IP. |

## Examples

### Full backup to a local drive

```powershell
.\Backup-AzureWordpress.ps1 `
    -ResourceGroup $RG `
    -AppName $APP_NAME `
    -Destination Local `
    -LocalPath D:\backup
```

### Full backup to Azure Blob Storage

The SAS must target one container, remain valid for the full run, and grant create, write, and read permissions. The script uploads to a timestamped virtual folder and uploads `SHA256SUMS` last as the completion marker.

```powershell
$containerSasUri = 'https://storageaccount.blob.core.windows.net/backups?<SAS-token>'

.\Backup-AzureWordpress.ps1 `
    -ResourceGroup $RG `
    -AppName $APP_NAME `
    -Destination Blob `
    -BlobSasUri $containerSasUri
```

The resulting blob names have this layout:

```text
<app-name>-<UTC-timestamp>/db.sql.gz
<app-name>-<UTC-timestamp>/files.tar.gz
<app-name>-<UTC-timestamp>/manifest.txt
<app-name>-<UTC-timestamp>/plugins.csv
<app-name>-<UTC-timestamp>/themes.csv
<app-name>-<UTC-timestamp>/SHA256SUMS
```

Existing blobs are not overwritten. A failed upload may leave an incomplete timestamped prefix without `SHA256SUMS`; the remote App Service staging copy is retained when the destination is not fully verified.

### Database-only backup

Use this to create a quick SQL backup without transferring site files:

```powershell
.\Backup-AzureWordpress.ps1 `
    -ResourceGroup $RG `
    -AppName $APP_NAME `
    -Destination Local `
    -LocalPath D:\backup `
    -DatabaseOnly
```

### Keep the remote staging copy

Normally, the remote directory is deleted only after the local hashes have validated. Retain it for a second copy or inspection:

```powershell
.\Backup-AzureWordpress.ps1 `
    -ResourceGroup $RG `
    -AppName $APP_NAME `
    -Destination Local `
    -LocalPath D:\backup `
    -KeepRemote
```

The result object displays the retained `/home/backups/<timestamp>` path. Delete it later through the App Service SSH session after confirming the local backup is usable.

### Back up a deployment slot

```powershell
.\Backup-AzureWordpress.ps1 `
    -ResourceGroup $RG `
    -AppName $APP_NAME `
    -Slot staging `
    -Destination Local `
    -LocalPath D:\backup
```

### Select an Azure subscription explicitly

```powershell
.\Backup-AzureWordpress.ps1 `
    -ResourceGroup $RG `
    -AppName $APP_NAME `
    -SubscriptionId '00000000-0000-0000-0000-000000000000' `
    -Destination Local `
    -LocalPath D:\backup
```

### Change the excluded table list

`-ExcludeTables` replaces the default. Pass an empty array if no tables should be excluded.

```powershell
.\Backup-AzureWordpress.ps1 `
    -ResourceGroup $RG `
    -AppName $APP_NAME `
    -ExcludeTables 'wp_actionscheduler_logs', 'wp_wc_admin_notes' `
    -Destination Local `
    -LocalPath D:\backup
```

## Remote Retention and Cleanup

Remote staging uses `/home/backups`, which is persistent App Service storage. It is used only as a temporary transfer area by default.

- On a successful backup, the script verifies every downloaded checksum first, then deletes the remote staging directory.
- When `-KeepRemote` is used, it leaves the remote staging directory in place.
- When backup creation fails before the artifacts are complete, the script leaves the staging directory available for diagnosis rather than deleting potentially useful evidence.
- If downloading or validation fails, do not treat the local folder as a trusted backup. Resolve the error, then rerun the backup. Remove incomplete local folders manually once they are no longer needed.

## Troubleshooting

### Script execution is blocked because it is unsigned

Use the temporary PowerShell 7 invocation shown in [Execution policy](#execution-policy). Do not lower execution policy permanently just to run this script.

### `Azure CLI is not authenticated`

Run:

```powershell
az login
az account show
```

For multiple subscriptions, pass `-SubscriptionId` or run `az account set --subscription <id>` first.

### The tunnel does not become ready

Check that the app name, resource group, subscription, and optional slot are correct. Confirm Azure CLI can locate the app:

```powershell
az webapp show --resource-group $RG --name $APP_NAME --output table
```

The script automatically tries the next port if its requested local port is busy. Use `-Port` to start from a different port range when another local process repeatedly occupies nearby ports.

### WP-CLI says the site is not installed

This usually means the command was run outside the App Service login-shell environment, where database settings are unavailable. `Backup-AzureWordpress.ps1` uses `bash -lc` specifically to load that environment. Ensure you are running the current script version and that its `Verifying WordPress CLI in a login shell` step succeeds.

### Database export or file archive times out

Increase the relevant timeout for larger sites:

```powershell
.\Backup-AzureWordpress.ps1 `
    -ResourceGroup $RG `
    -AppName $APP_NAME `
    -Destination Local `
    -LocalPath D:\backup `
    -CommandTimeoutSeconds 14400 `
    -TransferTimeoutSeconds 14400
```

Also confirm sufficient App Service persistent storage for the temporary archive and enough free local disk space for the final backup.

### Local checksum validation fails

The script intentionally fails the operation when any artifact is absent or has a different SHA-256 hash. Do not use that local backup for restore. Re-run the backup after checking local disk health, available space, and connection stability.

### SFTP download fails

SFTP is used because it is compatible with the App Service remote-connection tunnel used by this script. Ensure Posh-SSH is installed and retry the backup. If the error mentions connection loss, retry with a larger `-TransferTimeoutSeconds` and check the Azure CLI tunnel logs reported by the error.

## Access Restrictions

**The SCM site is what matters. The main site does not.**

`az webapp create-remote-connection` does not bypass Kudu. It resolves the SCM hostname, retrieves the app's publishing credentials, and opens a WebSocket to `https://<app>.scm.azurewebsites.net/AppServiceTunnel/Tunnel.ashx` with an HTTP `Authorization: Basic` header. The local `127.0.0.1` listener is only the near end of that connection. Two SCM-side settings therefore gate every backup in this repository.

| Surface | What its rules control | Required for backups |
| --- | --- | --- |
| Main site | Public HTTP/HTTPS traffic to the WordPress site | No — restrict freely |
| SCM site | Kudu, `*.scm.azurewebsites.net`, and the backup tunnel | **Yes** |

One exception links them: if `scmIpSecurityRestrictionsUseMain` is `true`, the SCM site inherits the main-site rules, so main-site rules then apply to the tunnel as well.

### What must be in place

1. **SCM access restrictions must permit the machine running the script.** Either leave the SCM default action as `Allow`, or add an allow rule for the workstation's public egress IP (its internet-facing NAT/VPN address, not its private LAN address).
2. **SCM basic authentication publishing must be enabled.** The tunnel authenticates with publishing credentials. If the `scm` basic publishing credentials policy is `allow: false`, the tunnel fails with `401`.

The second point is easy to miss, because disabling basic auth publishing is a common hardening default.

### Preflight

`Backup-AzureWordpress.ps1` reports both before it connects:

```text
Checking App Service access restrictions (read-only)
  Main site: default action Deny, 3 rule(s). Not used by this backup.
  SCM site: default action Allow, 0 rule(s), inherits main rules: False.
  SCM basic authentication publishing is enabled.
```

When something will block the tunnel, it warns instead:

```text
  SCM basic authentication publishing is disabled. az webapp create-remote-connection authenticates
  with publishing credentials, so the tunnel will fail with 401 until it is enabled.
  SCM default action is Deny. This machine's public egress IP must match an SCM allow rule,
  or the tunnel will be blocked.
```

Use `-SkipAccessRestrictionCheck` to omit the preflight. Use `-SkipAccessRemediation` to keep the preflight but report blocking settings without changing a rule or policy. The returned object exposes `AccessRestrictions` with `ScmDefaultAction`, `ScmUsesMainRules`, and `ScmBasicAuthEnabled`.

### Automatic remediation

`Backup-AzureWordpress.ps1` runs the same check, then fixes only what would block the tunnel and undoes it afterwards:

| Condition found | Temporary change | Revert |
| --- | --- | --- |
| SCM basic auth disabled | Sets the `scm` policy to `allow: true` | Sets it back to `false` |
| SCM default action is `Deny` | Adds an SCM allow rule for this machine's public egress IP (`/32`), at the lowest free priority from 100 | Removes that rule |

```powershell
.\Backup-AzureWordpress.ps1 `
    -ResourceGroup $RG `
    -AppName $APP_NAME `
    -Destination Local `
    -LocalPath D:\backup
```

Design points worth knowing:

- **Least privilege.** It adds a `/32` rule for one IP rather than setting the SCM default to `Allow`, so the SCM endpoint is never opened to the internet.
- **Only what is broken.** If basic auth is already enabled, or SCM already defaults to `Allow`, nothing is changed.
- **Guaranteed revert.** Both undo steps run in the `finally` block, so they execute after success, failure, or an error mid-backup. If a revert itself fails, it warns with the exact rule name or policy to fix manually.
- **Fail-closed.** The egress IP is detected via `https://api.ipify.org`. If detection fails, the script warns and changes nothing rather than falling back to opening SCM. Pass `-ScmAllowIpAddress <ip>` to skip the lookup and supply the address yourself.
- **Opt out** with `-SkipAccessRemediation` to get a report-only run that changes nothing.

A hard kill (`Ctrl+C` twice, or terminating the process) can bypass `finally`. If that happens, remove the `wpbackup-temp-*` SCM rule and re-disable basic auth manually.

## Security Notes

- The Azure remote-connection tunnel listens only on local loopback (`127.0.0.1`); it does not expose container SSH publicly.
- Main-site access restrictions can stay as strict as you like; they do not affect backups. Keep SCM restricted to known operator IPs rather than opening it broadly.
- Access to the tunnel is authorized by the Azure CLI identity. Protect the device and Azure sign-in session used to run backups.
- The script uses the documented App Service Linux container SSH credentials only over that Azure-authenticated loopback tunnel.
- Backups contain the complete database and, for full backups, `wp-config.php`. They may include secrets, user data, application data, and personally identifiable information.
- Store backup folders and Blob containers with access limited to operators who require recovery access. Do not commit generated backups to source control or place them in broadly shared locations.
- Treat the Blob container SAS URI as a secret. The script passes its token to Azure CLI through the process environment and removes or restores that value after upload; it does not print the SAS query string.
- The script disables host-key verification for the short-lived local tunnel. This is appropriate only because the SSH endpoint is reached through the authenticated Azure tunnel on `127.0.0.1`.

## Disaster Recovery Runbook Example

[restorenotes.txt](restorenotes.txt) is a copy-paste runbook that chains together a full DR restore, Redis reconfiguration, and a Front Door cache purge for a site sitting behind Azure Front Door:

```powershell
$RG_DR = "<resource-group-name>"
$APP_NAME_DR = '<APPSERVICENAME>'
$AFD_PROFILE_NAME = '<FRONTDOORPROFILENAME>'
$AFD_ENDPOINT_NAME = '<AFDENDPOINTNAME>'
$AFD_CONTENT_PATHS = '/*'
$AFD_DOMAIN_NAME = 'AFDDOMAINNAME'
$RedisName = 'REDISNAME'
$BackupPath = '.\wp-backups\....'

# Restore Azure WordPress backup and configure Redis, then purge Front Door cache

./Restore-AzureWordpressBackup.ps1 -ResourceGroup $RG_DR -AppName $APP_NAME_DR `
    -BackupPath $BackupPath `
    -FrontDoorProfileName $AFD_PROFILE_NAME -FrontDoorEndpointName $AFD_ENDPOINT_NAME

./SetupRedis.ps1 -ResourceGroup $RG_DR -AppName $APP_NAME_DR -RedisName $RedisName

az afd endpoint purge --resource-group $RG_DR `
  --profile-name $AFD_PROFILE_NAME `
  --endpoint-name $AFD_ENDPOINT_NAME `
  --domains $AFD_DOMAIN_NAME `
  --content-paths $AFD_CONTENT_PATHS
```

Steps:

1. [Restore-AzureWordpressBackup.ps1](Restore-AzureWordpressBackup.ps1) restores the backup onto the DR App Service. Passing `-FrontDoorProfileName`/`-FrontDoorEndpointName` lets it auto-detect the DR site's real public URL (custom domain or endpoint hostname) instead of requiring `-NewUrl`.
2. [SetupRedis.ps1](SetupRedis.ps1) re-points the restored site's W3 Total Cache plugin at the DR environment's own Redis instance, since the restored database still references the source environment's cache config.
3. `az afd endpoint purge` clears the Front Door edge cache for the domain so visitors immediately see the restored content instead of stale cached pages.

The file also keeps this WP-CLI snippet for resetting a WordPress user's password directly, run from an interactive shell such as [Invoke-WpCommand.ps1](Invoke-WpCommand.ps1)`-Interactive` or the App Service SSH console (assumes the user is `wpadmin`):

```bash
wp user update wpadmin --user_pass="<PASSWORD>" --path=/home/site/wwwroot --allow-root
```

Treat `restorenotes.txt` as a template: replace every placeholder (`<...>`) with the DR environment's real resource names before running it, and never commit it with real values filled in.

## Related Scripts

This folder also contains scripts that use the same Azure remote-connection tunnel mechanism but are not covered in detail by this README:

- [Invoke-WpCommand.ps1](Invoke-WpCommand.ps1) runs individual WP-CLI commands, or an interactive shell, over the same tunnel and login-shell mechanism.
- [Restore-AzureWordpressBackup.ps1](Restore-AzureWordpressBackup.ps1) restores a backup produced by this script onto a target App Service, including auto-detection of the target's public URL and rewriting old URLs to it.
- [RestoreFromLocal.ps1](RestoreFromLocal.ps1) imports a local WordPress database dump (and optionally its files) into an Azure site without overwriting the Azure environment's own configuration by default.
- [SetupRedis.ps1](SetupRedis.ps1) configures the W3 Total Cache plugin to use an Azure Managed Redis instance.

See each script's own `.SYNOPSIS`/`.DESCRIPTION` comment header for full parameter and usage details.