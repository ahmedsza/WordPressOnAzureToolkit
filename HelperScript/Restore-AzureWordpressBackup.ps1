<#
.SYNOPSIS
    Disaster-recovery restore of a WordPress App Service from a backup produced by
    Backup-AzureWordpressv5.ps1, for a target environment whose public URL differs from where
    the backup was taken (different Front Door endpoint, different App Service name, custom
    domain, etc.).

.DESCRIPTION
    Same full-overwrite restore as Restore-AzureWordpressBackup.ps1 -- the target database is
    dropped and re-created from the backup's db.sql.gz, and (unless -DatabaseOnly, or the backup
    has no files.tar.gz) wp-content/wp-config.php are replaced with the backup's copies. Nothing
    on the target survives; this is not a merge (see RestoreFromLocal.ps1 for that).

    v2 added environment-aware URL handling for restoring into a *different* environment than
    the one the backup was taken from. v3 additionally auto-detects a custom domain attached to
    the target, instead of only ever resolving the raw Front Door/App Service hostname:

    - The target's real public URL is resolved automatically instead of requiring -NewUrl:
        * If -FrontDoorProfileName/-FrontDoorEndpointName are supplied, it first looks for a
          custom domain attached to one of that endpoint's routes (az afd route list / az afd
          custom-domain show) and uses it if found; otherwise it uses the endpoint's own
          hostname (az afd endpoint show).
        * Otherwise it looks for a custom domain bound directly to the App Service (az webapp
          config hostname list); otherwise it falls back to the App Service's own default
          hostname (https://<app>.azurewebsites.net, or the slot's hostname).
        * -NewUrl still overrides all of the above, if supplied.
        * -SkipCustomDomainDetection disables the custom-domain lookups and goes straight to the
          raw endpoint/App Service hostname, matching v2's behavior.
    - Every URL the restored content might reference is replaced with that target URL, not just
      the backup's siteurl: -OldUrls accepts one or more old URLs (for example both a legacy
      Front Door hostname and the App Service's raw azurewebsites.net hostname). If omitted, it
      defaults to the distinct siteurl/home values read from the backup's manifest.txt.
    - -SkipUrlReplace disables URL rewriting entirely (for example when restoring back onto the
      exact original environment).

    Steps:
    1. Locate and verify the backup (SHA256SUMS) -- from -BackupPath (local) or -BlobSasUri +
       -BlobPrefix (Blob), downloading only what is needed into a temporary folder for Blob.
    2. Resolve the target's real public URL (including any attached custom domain) and the set
       of old URLs to replace (unless -SkipUrlReplace).
    3. Optionally take a best-effort safety backup of the target's current database before
       overwriting it (skip with -SkipSafetyBackup).
    4. Upload db.sql.gz (and files.tar.gz, unless -DatabaseOnly) to the target over SFTP and
       verify their SHA256 checksums remotely.
    5. Reset and re-import the database (`wp db reset` + `wp db import`).
    6. Unless -DatabaseOnly: delete the target's wp-content and wp-config.php, then extract the
       backup's files.tar.gz in their place.
    7. Unless -SkipUrlReplace: run `wp search-replace` once per resolved old URL, into the
       resolved target URL, across all tables.
    8. Flush cache/rewrite rules and print the restored site's version/URLs for confirmation.

.NOTES
    Requires: PowerShell 7+, Azure CLI (logged in), Posh-SSH module.
    Install-Module Posh-SSH -Scope CurrentUser

.EXAMPLE
    # Restore into a DR App Service sitting behind its own Front Door endpoint; if a custom
    # domain is attached to that endpoint's route, it is auto-detected and used as the target URL.
    ./Restore-AzureWordpressBackupv3.ps1 -ResourceGroup rg-wp-dr -AppName my-wp-dr `
        -BackupPath .\wp-backups\my-wp-prod-20260901-090456-326 `
        -FrontDoorProfileName my-dr-afd -FrontDoorEndpointName my-dr-afd-endpoint -Force

.EXAMPLE
    # Explicit control over both sides of the URL replacement.
    ./Restore-AzureWordpressBackupv3.ps1 -ResourceGroup rg-wp-dr -AppName my-wp-dr `
        -BlobSasUri $containerSasUri -BlobPrefix 'my-wp-prod-20260901-090456-326' `
        -OldUrls 'https://old.example.com', 'https://old-afd-endpoint.b02.azurefd.net' `
        -NewUrl 'https://new.example.com' -Force

.EXAMPLE
    # Restoring back onto the exact original environment: skip URL rewriting entirely.
    ./Restore-AzureWordpressBackupv3.ps1 -ResourceGroup rg-wp -AppName my-wp-site `
        -BackupPath .\wp-backups\my-wp-site-20260901-090456-326 -SkipUrlReplace -Force
#>

[CmdletBinding(DefaultParameterSetName = 'Local')]
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $AppName,
    [string] $Slot,
    [string] $SubscriptionId,

    [Parameter(Mandatory, ParameterSetName = 'Local')] [string] $BackupPath,
    [Parameter(Mandatory, ParameterSetName = 'Blob')] [string] $BlobSasUri,
    [Parameter(Mandatory, ParameterSetName = 'Blob')] [string] $BlobPrefix,

    # Skip restoring wp-content/wp-config.php even if the backup includes files.tar.gz.
    [switch] $DatabaseOnly,

    # The target's real public URL. Auto-resolved (Front Door endpoint, else the App Service's
    # own default hostname) when not supplied.
    [string] $NewUrl,
    # Used only to auto-resolve -NewUrl when it is not supplied.
    [string] $FrontDoorProfileName,
    [string] $FrontDoorEndpointName,
    # One or more old URLs to replace. Defaults to the distinct siteurl/home read from manifest.txt.
    [string[]] $OldUrls,
    [switch] $SkipUrlReplace,
    # Skip looking for a custom domain and use the raw Front Door/App Service hostname directly.
    [switch] $SkipCustomDomainDetection,

    [switch] $SkipSafetyBackup,
    [string] $SafetyBackupPath = '.\pre-restore-backups',

    [switch] $Force,
    [switch] $KeepRemote,

    [ValidateRange(1, 65535)] [int] $Port = 2222,
    [ValidateRange(1, 3600)] [int] $TunnelTimeoutSeconds = 60,
    [ValidateRange(1, 86400)] [int] $CommandTimeoutSeconds = 3600,
    [ValidateRange(1, 86400)] [int] $TransferTimeoutSeconds = 3600,

    [switch] $SkipAccessRestrictionCheck,
    [switch] $SkipAccessRemediation,
    [string] $ScmAllowIpAddress
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ContainerUser = 'root'
$ContainerPass = 'Docker!'
$WorkingDirectory = '/home/site/wwwroot'

function Write-Step { param([string] $Message) Write-Host "`n$Message" -ForegroundColor Cyan }
function Write-Ok { param([string] $Message) Write-Host "  $Message" -ForegroundColor Green }
function Write-WarningMessage { param([string] $Message) Write-Host "  $Message" -ForegroundColor Yellow }

function ConvertTo-BashLiteral {
    param([AllowEmptyString()] [string] $Value)

    return "'" + $Value.Replace("'", "'`"'`"'") + "'"
}

function New-LoginShellCommand {
    param([Parameter(Mandatory)] [string] $Script)

    return "bash -lc $(ConvertTo-BashLiteral $Script)"
}

function Assert-Prerequisites {
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "PowerShell 7+ is required (found $($PSVersionTable.PSVersion))."
    }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI was not found. Install it from https://aka.ms/installazurecli.'
    }
    $null = az account show --output none 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Azure CLI is not authenticated. Run az login first.'
    }
    if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
        throw 'Posh-SSH is required. Install it with: Install-Module Posh-SSH -Scope CurrentUser'
    }

    Import-Module Posh-SSH -ErrorAction Stop
}

function Get-PropertyOrDefault {
    param(
        $InputObject,
        [Parameter(Mandatory)] [string] $Name,
        $Default = $null
    )

    if ($null -ne $InputObject -and $InputObject.PSObject.Properties[$Name]) {
        $value = $InputObject.PSObject.Properties[$Name].Value
        if ($null -ne $value) {
            return $value
        }
    }

    return $Default
}

<#
    .SYNOPSIS
    Finds a custom domain attached to one of a Front Door endpoint's routes, if any.
#>
function Get-FrontDoorCustomDomainHostname {
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $FrontDoorProfileName,
        [Parameter(Mandatory)] [string] $FrontDoorEndpointName
    )

    $routesJson = (& az afd route list --resource-group $ResourceGroup --profile-name $FrontDoorProfileName `
        --endpoint-name $FrontDoorEndpointName --query '[].customDomains[].id' --output json --only-show-errors 2>&1) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    $customDomainIds = @()
    try {
        $customDomainIds = @(($routesJson | ConvertFrom-Json) | Where-Object { $_ })
    }
    catch {
        return $null
    }
    if ($customDomainIds.Count -eq 0) {
        return $null
    }

    $hostNames = [System.Collections.Generic.List[string]]::new()
    foreach ($id in $customDomainIds) {
        $hostName = (& az afd custom-domain show --ids $id --query hostName --output tsv --only-show-errors 2>&1) -join ''
        if ($LASTEXITCODE -eq 0 -and $hostName.Trim()) {
            $hostNames.Add($hostName.Trim())
        }
    }
    $uniqueHostNames = @($hostNames | Select-Object -Unique)
    if ($uniqueHostNames.Count -eq 0) {
        return $null
    }
    if ($uniqueHostNames.Count -gt 1) {
        Write-WarningMessage "Multiple custom domains are attached to endpoint '$FrontDoorEndpointName'; using '$($uniqueHostNames[0])'. Pass -NewUrl explicitly to choose a different one."
    }

    return $uniqueHostNames[0]
}

<#
    .SYNOPSIS
    Finds a custom domain bound directly to the App Service (not via Front Door), if any.
#>
function Get-AppServiceCustomHostname {
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $AppName,
        [AllowEmptyString()] [string] $Slot
    )

    $slotArguments = @()
    if ($Slot) {
        $slotArguments = @('--slot', $Slot)
    }

    $namesJson = (& az webapp config hostname list --resource-group $ResourceGroup --webapp-name $AppName @slotArguments `
        --query "[?hostType=='Standard'].name" --output json --only-show-errors 2>&1) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    $names = @()
    try {
        $names = @(($namesJson | ConvertFrom-Json) | Where-Object { $_ -and $_ -notlike '*.azurewebsites.net' })
    }
    catch {
        return $null
    }
    if ($names.Count -eq 0) {
        return $null
    }
    if ($names.Count -gt 1) {
        Write-WarningMessage "Multiple custom domains are bound to the App Service; using '$($names[0])'. Pass -NewUrl explicitly to choose a different one."
    }

    return $names[0]
}

<#
    .SYNOPSIS
    Resolves the target environment's real public URL: a custom domain if one is found (attached
    to the Front Door endpoint's route, or directly to the App Service), else the Front Door
    endpoint's own hostname, else the App Service's default hostname.
#>
function Get-TargetPublicUrl {
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $AppName,
        [AllowEmptyString()] [string] $Slot,
        [AllowEmptyString()] [string] $FrontDoorProfileName,
        [AllowEmptyString()] [string] $FrontDoorEndpointName,
        [switch] $SkipCustomDomainDetection
    )

    if ($FrontDoorProfileName -and $FrontDoorEndpointName) {
        if (-not $SkipCustomDomainDetection) {
            $customDomainHostName = Get-FrontDoorCustomDomainHostname -ResourceGroup $ResourceGroup `
                -FrontDoorProfileName $FrontDoorProfileName -FrontDoorEndpointName $FrontDoorEndpointName
            if ($customDomainHostName) {
                Write-Ok "Found a custom domain attached to endpoint '$FrontDoorEndpointName': $customDomainHostName"
                return "https://$customDomainHostName"
            }
        }

        $hostName = (& az afd endpoint show --resource-group $ResourceGroup --profile-name $FrontDoorProfileName `
            --endpoint-name $FrontDoorEndpointName --query hostName --output tsv --only-show-errors 2>&1) -join ''
        if ($LASTEXITCODE -eq 0 -and $hostName.Trim()) {
            return "https://$($hostName.Trim())"
        }
        Write-WarningMessage "Could not read Front Door endpoint '$FrontDoorEndpointName' hostname; falling back to the App Service's hostname."
    }

    if (-not $SkipCustomDomainDetection) {
        $appCustomHostName = Get-AppServiceCustomHostname -ResourceGroup $ResourceGroup -AppName $AppName -Slot $Slot
        if ($appCustomHostName) {
            Write-Ok "Found a custom domain bound to the App Service: $appCustomHostName"
            return "https://$appCustomHostName"
        }
    }

    $slotArguments = @()
    if ($Slot) {
        $slotArguments = @('--slot', $Slot)
    }
    $defaultHostName = (& az webapp show --resource-group $ResourceGroup --name $AppName @slotArguments `
        --query defaultHostName --output tsv --only-show-errors 2>&1) -join ''
    if ($LASTEXITCODE -ne 0 -or -not $defaultHostName.Trim()) {
        throw "Could not determine the target App Service's default hostname. Pass -NewUrl explicitly."
    }

    return "https://$($defaultHostName.Trim())"
}

<#
    .SYNOPSIS
    Reports main-site and SCM access restrictions without modifying any rule.
#>
function Show-AccessRestrictionSummary {
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $AppName,
        [AllowEmptyString()] [string] $Slot
    )

    $slotArguments = @()
    if ($Slot) {
        $slotArguments = @('--slot', $Slot)
    }

    $arguments = @(
        'webapp', 'config', 'access-restriction', 'show',
        '--resource-group', $ResourceGroup,
        '--name', $AppName,
        '--only-show-errors',
        '--output', 'json'
    ) + $slotArguments

    $output = @(& az @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        Write-WarningMessage 'Could not read access restrictions; continuing because the tunnel does not depend on them.'
        return $null
    }

    try {
        $config = ($output -join [Environment]::NewLine) | ConvertFrom-Json
    }
    catch {
        Write-WarningMessage 'Could not parse the access-restriction configuration; continuing.'
        return $null
    }

    $mainRules = @(Get-PropertyOrDefault -InputObject $config -Name 'ipSecurityRestrictions' -Default @())
    $scmRules = @(Get-PropertyOrDefault -InputObject $config -Name 'scmIpSecurityRestrictions' -Default @())
    $mainDefault = Get-PropertyOrDefault -InputObject $config -Name 'ipSecurityRestrictionsDefaultAction' -Default 'Unspecified'
    $scmDefault = Get-PropertyOrDefault -InputObject $config -Name 'scmIpSecurityRestrictionsDefaultAction' -Default 'Unspecified'
    $scmUsesMain = [bool] (Get-PropertyOrDefault -InputObject $config -Name 'scmIpSecurityRestrictionsUseMain' -Default $false)

    # The remote-connection tunnel reaches the app through the SCM site, so SCM rules gate this restore.
    $effectiveScmRules = if ($scmUsesMain) { $mainRules } else { $scmRules }
    $effectiveScmDefault = if ($scmUsesMain) { $mainDefault } else { $scmDefault }

    Write-Ok "Main site: default action $mainDefault, $($mainRules.Count) rule(s). Not used by this restore."
    Write-Ok "SCM site: default action $effectiveScmDefault, $($effectiveScmRules.Count) rule(s), inherits main rules: $scmUsesMain."

    $scmBasicAuth = $null
    $appId = (& az webapp show --resource-group $ResourceGroup --name $AppName @slotArguments --query id --output tsv --only-show-errors 2>&1) -join ''
    if ($LASTEXITCODE -eq 0 -and $appId) {
        $policy = (& az resource show --ids "$appId/basicPublishingCredentialsPolicies/scm" `
            --api-version 2022-03-01 --query properties.allow --output tsv --only-show-errors 2>&1) -join ''
        if ($LASTEXITCODE -eq 0) {
            $scmBasicAuth = ($policy.Trim() -ieq 'true')
        }
    }

    if ($scmBasicAuth -eq $false) {
        Write-WarningMessage 'SCM basic authentication publishing is disabled. az webapp create-remote-connection authenticates with publishing credentials, so the tunnel will fail with 401 until it is enabled.'
    }
    elseif ($scmBasicAuth) {
        Write-Ok 'SCM basic authentication publishing is enabled.'
    }

    if ($effectiveScmDefault -ieq 'Deny') {
        Write-WarningMessage "SCM default action is Deny. This machine's public egress IP must match an SCM allow rule, or the tunnel will be blocked."
    }

    return [pscustomobject]@{
        MainRuleCount = $mainRules.Count
        MainDefaultAction = $mainDefault
        ScmRuleCount = $effectiveScmRules.Count
        ScmDefaultAction = $effectiveScmDefault
        ScmUsesMainRules = $scmUsesMain
        ScmBasicAuthEnabled = $scmBasicAuth
        AppId = $appId
        ScmRulePriorities = @($effectiveScmRules | ForEach-Object { [int] (Get-PropertyOrDefault -InputObject $_ -Name 'priority' -Default 0) })
    }
}

function Get-PublicEgressIpAddress {
    try {
        $response = Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 20
        $candidate = ($response.ip).Trim()
        if ($candidate -as [ipaddress]) {
            return $candidate
        }
    }
    catch {
        return $null
    }

    return $null
}

function Set-ScmBasicAuthPolicy {
    param(
        [Parameter(Mandatory)] [string] $AppId,
        [Parameter(Mandatory)] [bool] $Allow
    )

    $value = if ($Allow) { 'true' } else { 'false' }
    $output = @(& az resource update --ids "$AppId/basicPublishingCredentialsPolicies/scm" `
        --api-version 2022-03-01 --set "properties.allow=$value" --output none --only-show-errors 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not set SCM basic authentication publishing to $value. $($output -join ' ')"
    }
}

function Add-TemporaryScmAllowRule {
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $AppName,
        [AllowEmptyString()] [string] $Slot,
        [Parameter(Mandatory)] [string] $RuleName,
        [Parameter(Mandatory)] [string] $IpAddress,
        [Parameter(Mandatory)] [int] $Priority
    )

    $arguments = @(
        'webapp', 'config', 'access-restriction', 'add',
        '--resource-group', $ResourceGroup,
        '--name', $AppName,
        '--rule-name', $RuleName,
        '--action', 'Allow',
        '--ip-address', "$IpAddress/32",
        '--priority', $Priority,
        '--scm-site', 'true',
        '--description', 'Temporary rule added by Restore-AzureWordpressBackupv3',
        '--output', 'none',
        '--only-show-errors'
    )
    if ($Slot) {
        $arguments += @('--slot', $Slot)
    }

    $output = @(& az @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not add temporary SCM allow rule $RuleName. $($output -join ' ')"
    }
}

function Remove-TemporaryScmAllowRule {
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $AppName,
        [AllowEmptyString()] [string] $Slot,
        [Parameter(Mandatory)] [string] $RuleName
    )

    $arguments = @(
        'webapp', 'config', 'access-restriction', 'remove',
        '--resource-group', $ResourceGroup,
        '--name', $AppName,
        '--rule-name', $RuleName,
        '--scm-site', 'true',
        '--output', 'none',
        '--only-show-errors'
    )
    if ($Slot) {
        $arguments += @('--slot', $Slot)
    }

    $output = @(& az @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not remove temporary SCM allow rule $RuleName. $($output -join ' ')"
    }
}

function Test-PortFree {
    param([int] $CandidatePort)

    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $CandidatePort)
        $listener.Start()
        $listener.Stop()
        return $true
    }
    catch {
        return $false
    }
}

function Wait-TunnelReady {
    param(
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process,
        [Parameter(Mandatory)] [int] $TunnelPort,
        [Parameter(Mandatory)] [int] $TimeoutSeconds,
        [Parameter(Mandatory)] [string] $OutputLog,
        [Parameter(Mandatory)] [string] $ErrorLog
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($Process.HasExited) {
            $details = @(
                Get-Content -Path $ErrorLog -Raw -ErrorAction SilentlyContinue
                Get-Content -Path $OutputLog -Raw -ErrorAction SilentlyContinue
            ) -join [Environment]::NewLine
            throw "Azure remote-connection tunnel exited before becoming ready.`n$details"
        }

        try {
            $client = [System.Net.Sockets.TcpClient]::new()
            $client.Connect('127.0.0.1', $TunnelPort)
            $client.Dispose()
            return
        }
        catch {
            Start-Sleep -Milliseconds 750
        }
    }

    throw "Azure remote-connection tunnel did not become ready within $TimeoutSeconds seconds."
}

function Invoke-RemoteCommand {
    param(
        [Parameter(Mandatory)] [int] $SessionId,
        [Parameter(Mandatory)] [string] $Script,
        [Parameter(Mandatory)] [int] $TimeoutSeconds,
        [switch] $AllowFailure
    )

    $result = Invoke-SSHCommand -SessionId $SessionId `
        -Command (New-LoginShellCommand $Script) `
        -TimeOut $TimeoutSeconds

    if ($result.ExitStatus -ne 0 -and -not $AllowFailure) {
        $details = (@($result.Error) + @($result.Output)) -join [Environment]::NewLine
        throw "Remote command failed with exit code $($result.ExitStatus).`n$details"
    }

    return $result
}

function Invoke-RemoteScript {
    param(
        [Parameter(Mandatory)] [int] $SessionId,
        [Parameter(Mandatory)] [string] $Script,
        [Parameter(Mandatory)] [int] $TimeoutSeconds
    )

    $unixScript = $Script.Replace("`r`n", "`n")
    $encodedScript = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($unixScript))
    $bootstrap = 'eval "$(printf %s ' + (ConvertTo-BashLiteral $encodedScript) + ' | base64 -d)"'
    return Invoke-RemoteCommand -SessionId $SessionId -Script $bootstrap -TimeoutSeconds $TimeoutSeconds
}

function Get-RemoteFiles {
    param(
        [Parameter(Mandatory)] [string[]] $FileNames,
        [Parameter(Mandatory)] [string] $RemoteDirectory,
        [Parameter(Mandatory)] [string] $DestinationDirectory,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [Parameter(Mandatory)] [int] $TunnelPort,
        [Parameter(Mandatory)] [int] $TimeoutSeconds
    )

    $sftpSession = $null
    try {
        $sftpSession = New-SFTPSession -ComputerName '127.0.0.1' -Port $TunnelPort -Credential $Credential `
            -AcceptKey -Force -ConnectionTimeout $TimeoutSeconds -OperationTimeout $TimeoutSeconds
        foreach ($fileName in $FileNames) {
            Get-SFTPItem -SessionId $sftpSession.SessionId -Path "$RemoteDirectory/$fileName" `
                -Destination $DestinationDirectory -Force -ErrorAction Stop | Out-Null
        }
    }
    finally {
        if ($sftpSession) {
            Remove-SFTPSession -SessionId $sftpSession.SessionId -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

function Send-RemoteFiles {
    param(
        [Parameter(Mandatory)] [string[]] $FileNames,
        [Parameter(Mandatory)] [string] $LocalDirectory,
        [Parameter(Mandatory)] [string] $RemoteDirectory,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [Parameter(Mandatory)] [int] $TunnelPort,
        [Parameter(Mandatory)] [int] $TimeoutSeconds
    )

    $sftpSession = $null
    try {
        $sftpSession = New-SFTPSession -ComputerName '127.0.0.1' -Port $TunnelPort -Credential $Credential `
            -AcceptKey -Force -ConnectionTimeout $TimeoutSeconds -OperationTimeout $TimeoutSeconds
        foreach ($fileName in $FileNames) {
            $localFile = Join-Path $LocalDirectory $fileName
            Set-SFTPItem -SessionId $sftpSession.SessionId -Path $localFile -Destination $RemoteDirectory `
                -Force -ErrorAction Stop | Out-Null
        }
    }
    finally {
        if ($sftpSession) {
            Remove-SFTPSession -SessionId $sftpSession.SessionId -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

<#
    .SYNOPSIS
    Removes a container SAS URI and token from diagnostic text.
#>
function Protect-SasText {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text,
        [Parameter(Mandatory)] [string] $OriginalUri,
        [Parameter(Mandatory)] [string] $SasToken
    )

    $protectedText = $Text
    $parsedUri = $null
    if ([Uri]::TryCreate($OriginalUri, [UriKind]::Absolute, [ref] $parsedUri)) {
        $containerUri = $parsedUri.GetLeftPart([UriPartial]::Path)
        $protectedText = $protectedText.Replace($OriginalUri, $containerUri)
    }
    else {
        $protectedText = $protectedText.Replace($OriginalUri, '[REDACTED SAS URI]')
    }

    return $protectedText.Replace($SasToken, '[REDACTED SAS TOKEN]')
}

<#
    .SYNOPSIS
    Splits an HTTPS container SAS URI into non-secret addressing fields and its token.
#>
function ConvertFrom-BlobContainerSasUri {
    param([Parameter(Mandatory)] [string] $BlobSasUri)

    if ($BlobSasUri.StartsWith('https:', [StringComparison]::OrdinalIgnoreCase) -and
        -not $BlobSasUri.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The Blob container SAS URI must include a host authority.'
    }

    $parsedUri = $null
    if (-not [Uri]::TryCreate($BlobSasUri, [UriKind]::Absolute, [ref] $parsedUri)) {
        throw 'The Blob container SAS URI must be an absolute URI.'
    }
    if ($parsedUri.Scheme -ine 'https') {
        throw 'The Blob container SAS URI must use HTTPS.'
    }
    if ([string]::IsNullOrWhiteSpace($parsedUri.Host) -or [string]::IsNullOrWhiteSpace($parsedUri.Authority)) {
        throw 'The Blob container SAS URI must include a host authority.'
    }
    if (-not [string]::IsNullOrEmpty($parsedUri.UserInfo)) {
        throw 'The Blob container SAS URI must not contain user information.'
    }
    if (-not [string]::IsNullOrEmpty($parsedUri.Fragment)) {
        throw 'The Blob container SAS URI must not contain a fragment.'
    }
    if ([string]::IsNullOrWhiteSpace($parsedUri.Query) -or $parsedUri.Query.Length -le 1) {
        throw 'The Blob container SAS URI must include a query token.'
    }

    $escapedPath = $parsedUri.AbsolutePath
    if ($escapedPath.Length -le 1 -or -not $escapedPath.StartsWith('/')) {
        throw 'The Blob container SAS URI must contain one container path segment.'
    }

    $escapedContainer = $escapedPath.Substring(1)
    if ($escapedContainer.Contains('/') -or $escapedContainer.Contains('\') -or $escapedContainer -match '%(?:2[fF]|5[cC])') {
        throw 'The Blob container SAS URI must contain exactly one container path segment.'
    }

    $containerName = [Uri]::UnescapeDataString($escapedContainer)
    if ([string]::IsNullOrWhiteSpace($containerName) -or $containerName.Contains('/') -or $containerName.Contains('\')) {
        throw 'The Blob container SAS URI contains an invalid container path segment.'
    }

    $blobEndpoint = $parsedUri.GetLeftPart([UriPartial]::Authority)
    $containerUri = "$blobEndpoint/$([Uri]::EscapeDataString($containerName))"

    return [pscustomobject]@{
        BlobEndpoint = $blobEndpoint
        ContainerName = $containerName
        SasToken = $parsedUri.Query.Substring(1)
        ContainerUri = $containerUri
    }
}

function Invoke-AzStorage {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string] $OriginalUri,
        [Parameter(Mandatory)] [string] $SasToken
    )

    $output = @(& az @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $details = Protect-SasText -Text ($output -join [Environment]::NewLine) `
            -OriginalUri $OriginalUri -SasToken $SasToken
        throw "Azure CLI storage operation failed with exit code $LASTEXITCODE.`n$details"
    }

    return $output
}

function Get-BlobBackupArtifacts {
    param(
        [Parameter(Mandatory)] [string[]] $FileNames,
        [Parameter(Mandatory)] [string] $BlobPrefix,
        [Parameter(Mandatory)] [string] $ContainerSasUri,
        [Parameter(Mandatory)] [string] $DestinationDirectory
    )

    $sas = ConvertFrom-BlobContainerSasUri -BlobSasUri $ContainerSasUri
    $previousSasToken = [Environment]::GetEnvironmentVariable('AZURE_STORAGE_SAS_TOKEN', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('AZURE_STORAGE_SAS_TOKEN', $sas.SasToken, 'Process')
        foreach ($fileName in $FileNames) {
            $blobName = "$BlobPrefix/$fileName"
            $localFile = Join-Path $DestinationDirectory $fileName
            $downloadArguments = @(
                'storage', 'blob', 'download',
                '--blob-endpoint', $sas.BlobEndpoint,
                '--container-name', $sas.ContainerName,
                '--name', $blobName,
                '--file', $localFile,
                '--only-show-errors',
                '--output', 'none'
            )
            Invoke-AzStorage -Arguments $downloadArguments -OriginalUri $ContainerSasUri -SasToken $sas.SasToken | Out-Null
            Write-Ok "Downloaded $blobName."
        }
    }
    catch {
        $safeMessage = Protect-SasText -Text $_.Exception.Message -OriginalUri $ContainerSasUri -SasToken $sas.SasToken
        throw "Blob download failed for prefix $($sas.ContainerUri)/$BlobPrefix. $safeMessage"
    }
    finally {
        [Environment]::SetEnvironmentVariable('AZURE_STORAGE_SAS_TOKEN', $previousSasToken, 'Process')
    }
}

<#
    .SYNOPSIS
    Parses a SHA256SUMS file into an ordered list of referenced file names, rejecting anything
    that is not a plain, single-segment file name.
#>
function Get-Sha256SumsFileNames {
    param([Parameter(Mandatory)] [string] $SumsPath)

    if (-not (Test-Path -LiteralPath $SumsPath -PathType Leaf)) {
        throw "$SumsPath was not found."
    }

    $lines = @(Get-Content -LiteralPath $SumsPath)
    if ($lines.Count -eq 0) {
        throw 'SHA256SUMS is empty.'
    }

    $fileNames = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    foreach ($line in $lines) {
        if ($line -notmatch '^(?<hash>[A-Fa-f0-9]{64})\s+\*?(?<name>.+)$') {
            throw "Invalid checksum entry: $line"
        }

        $fileName = $Matches.name.Trim()
        if ([IO.Path]::IsPathRooted($fileName) -or $fileName.Contains('/') -or
            $fileName.Contains('\') -or $fileName -eq '..') {
            throw "Invalid checksum file name: $fileName"
        }
        if ($seen.ContainsKey($fileName)) {
            throw "Duplicate checksum entry: $fileName"
        }

        $seen[$fileName] = $true
        $fileNames.Add($fileName)
    }

    return $fileNames
}

function Assert-BackupChecksums {
    param(
        [Parameter(Mandatory)] [string] $BackupDirectory,
        [Parameter(Mandatory)] [string[]] $FileNames
    )

    $sumsPath = Join-Path $BackupDirectory 'SHA256SUMS'
    $entries = @{}
    foreach ($line in @(Get-Content -LiteralPath $sumsPath)) {
        if ($line -match '^(?<hash>[A-Fa-f0-9]{64})\s+\*?(?<name>.+)$') {
            $entries[$Matches.name.Trim()] = $Matches.hash
        }
    }

    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($fileName in $FileNames) {
        if (-not $entries.ContainsKey($fileName)) {
            $failures.Add("$fileName has no entry in SHA256SUMS")
            continue
        }

        $localFile = Join-Path $BackupDirectory $fileName
        if (-not (Test-Path -LiteralPath $localFile -PathType Leaf)) {
            $failures.Add("$fileName is missing")
            continue
        }

        $actual = (Get-FileHash -LiteralPath $localFile -Algorithm SHA256).Hash
        if ($actual -ine $entries[$fileName]) {
            $failures.Add("$fileName hash mismatch")
        }
    }

    if ($failures.Count -gt 0) {
        throw "Backup SHA256 verification failed: $($failures -join '; ')"
    }

    Write-Ok "Verified SHA256 for: $($FileNames -join ', ')."
}

function Get-ManifestValues {
    param([Parameter(Mandatory)] [string] $ManifestPath)

    $values = @{}
    if (Test-Path -LiteralPath $ManifestPath -PathType Leaf) {
        foreach ($line in @(Get-Content -LiteralPath $ManifestPath)) {
            if ($line -match '^(?<key>[^=]+)=(?<value>.*)$') {
                $values[$Matches.key] = $Matches.value
            }
        }
    }

    return $values
}

$tunnel = $null
$tunnelListenerProcessId = $null
$sshSession = $null
$credential = $null
$outputLog = $null
$errorLog = $null
$stagingDirectory = $null
$temporaryBackupDirectory = $null
$restoreRemoteDir = $null
$restoreRemoteDirCreated = $false
$safetyBackupRemoteDir = $null
$accessRestrictions = $null
$temporaryScmRuleName = $null
$restoreScmBasicAuthDisabled = $false
$result = [ordered]@{
    Success = $false
    Source = $PSCmdlet.ParameterSetName
    DatabaseOnly = [bool] $DatabaseOnly
    FilesRestored = $false
    SafetyBackupPath = $null
    TargetUrl = $null
    OldUrlsReplaced = @()
}

try {
    Write-Step 'Checking prerequisites'
    Assert-Prerequisites
    Write-Ok 'PowerShell, Azure CLI, and Posh-SSH are available.'

    if ($SubscriptionId) {
        az account set --subscription $SubscriptionId
        if ($LASTEXITCODE -ne 0) {
            throw "Could not select subscription $SubscriptionId."
        }
        Write-Ok "Selected subscription $SubscriptionId."
    }

    #region --- locate and verify the backup ---

    Write-Step 'Resolving backup source'
    if ($PSCmdlet.ParameterSetName -eq 'Local') {
        if (-not (Test-Path -LiteralPath $BackupPath -PathType Container)) {
            throw "BackupPath '$BackupPath' was not found."
        }
        $stagingDirectory = (Resolve-Path -LiteralPath $BackupPath).Path
        Write-Ok "Using local backup folder $stagingDirectory."
    }
    else {
        $temporaryBackupDirectory = Join-Path ([IO.Path]::GetTempPath()) "wordpress-restore-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $temporaryBackupDirectory -Force | Out-Null
        $stagingDirectory = $temporaryBackupDirectory

        $safeContainer = (ConvertFrom-BlobContainerSasUri -BlobSasUri $BlobSasUri).ContainerUri
        Write-Ok "Downloading backup from $safeContainer/$BlobPrefix."
        Get-BlobBackupArtifacts -FileNames @('SHA256SUMS', 'manifest.txt') -BlobPrefix $BlobPrefix `
            -ContainerSasUri $BlobSasUri -DestinationDirectory $stagingDirectory
    }

    $backupFileNames = Get-Sha256SumsFileNames -SumsPath (Join-Path $stagingDirectory 'SHA256SUMS')
    if ('db.sql.gz' -notin $backupFileNames) {
        throw 'The backup does not contain db.sql.gz.'
    }
    $backupHasFilesArchive = 'files.tar.gz' -in $backupFileNames
    $applyFiles = $backupHasFilesArchive -and -not $DatabaseOnly

    if ($PSCmdlet.ParameterSetName -eq 'Blob') {
        $remainingFileNames = @($backupFileNames | Where-Object { $_ -notin @('SHA256SUMS', 'manifest.txt') })
        if (-not $applyFiles) {
            $remainingFileNames = @($remainingFileNames | Where-Object { $_ -ne 'files.tar.gz' })
        }
        Get-BlobBackupArtifacts -FileNames $remainingFileNames -BlobPrefix $BlobPrefix `
            -ContainerSasUri $BlobSasUri -DestinationDirectory $stagingDirectory
    }

    $verifyFileNames = @($backupFileNames | Where-Object { $applyFiles -or $_ -ne 'files.tar.gz' })
    Assert-BackupChecksums -BackupDirectory $stagingDirectory -FileNames $verifyFileNames

    $manifest = Get-ManifestValues -ManifestPath (Join-Path $stagingDirectory 'manifest.txt')
    if ($manifest.Count -gt 0) {
        Write-Ok "Backup manifest: app=$($manifest['app']) timestamp_utc=$($manifest['timestamp_utc']) wp_version=$($manifest['wp_version']) siteurl=$($manifest['siteurl'])"
    }
    if ($DatabaseOnly -and $backupHasFilesArchive) {
        Write-WarningMessage 'Backup includes files.tar.gz, but -DatabaseOnly was specified; wp-content/wp-config.php will not be restored.'
    }
    elseif (-not $backupHasFilesArchive) {
        Write-WarningMessage 'Backup does not include files.tar.gz (database-only backup); wp-content/wp-config.php will not be restored.'
    }

    #endregion

    #region --- resolve the target environment's URL(s) ---

    $targetUrl = $null
    $effectiveOldUrls = @()
    if (-not $SkipUrlReplace) {
        Write-Step "Resolving the target environment's public URL"
        $targetUrl = if ($NewUrl) { $NewUrl } else {
            Get-TargetPublicUrl -ResourceGroup $ResourceGroup -AppName $AppName -Slot $Slot `
                -FrontDoorProfileName $FrontDoorProfileName -FrontDoorEndpointName $FrontDoorEndpointName `
                -SkipCustomDomainDetection:$SkipCustomDomainDetection
        }
        Write-Ok "Target URL: $targetUrl"

        $effectiveOldUrls = if ($OldUrls -and $OldUrls.Count -gt 0) {
            @($OldUrls | Where-Object { $_ })
        }
        else {
            @(@($manifest['siteurl'], $manifest['home']) | Where-Object { $_ } | Select-Object -Unique)
        }
        $effectiveOldUrls = @($effectiveOldUrls | Where-Object { $_ -ne $targetUrl } | Select-Object -Unique)

        if ($effectiveOldUrls.Count -eq 0) {
            Write-WarningMessage 'No old URL to replace was found (manifest has none, and -OldUrls was not given); URL replacement will be skipped.'
        }
        else {
            Write-Ok "Old URL(s) to replace: $($effectiveOldUrls -join ', ')"
        }
        $result.TargetUrl = $targetUrl
    }
    else {
        Write-WarningMessage 'Skipping URL replacement (-SkipUrlReplace). Restored content will keep the backup''s original URLs.'
    }

    #endregion

    if (-not $SkipAccessRestrictionCheck) {
        Write-Step 'Checking App Service access restrictions'
        $accessRestrictions = Show-AccessRestrictionSummary -ResourceGroup $ResourceGroup -AppName $AppName -Slot $Slot
    }

    if ($accessRestrictions -and -not $SkipAccessRemediation) {
        if ($accessRestrictions.ScmBasicAuthEnabled -eq $false) {
            if ($accessRestrictions.AppId) {
                Write-Step 'Temporarily enabling SCM basic authentication publishing'
                Set-ScmBasicAuthPolicy -AppId $accessRestrictions.AppId -Allow $true
                $restoreScmBasicAuthDisabled = $true
                Write-Ok 'Enabled; it will be disabled again when this run finishes.'
            }
            else {
                Write-WarningMessage 'SCM basic authentication is disabled but the app resource id could not be read; cannot remediate.'
            }
        }

        if ($accessRestrictions.ScmDefaultAction -ieq 'Deny') {
            $allowIpAddress = if ($ScmAllowIpAddress) { $ScmAllowIpAddress } else { Get-PublicEgressIpAddress }
            if (-not $allowIpAddress) {
                Write-WarningMessage 'Could not determine this machine public egress IP, so no SCM rule was added. Pass -ScmAllowIpAddress to remediate explicitly.'
            }
            else {
                $usedPriorities = @($accessRestrictions.ScmRulePriorities)
                $rulePriority = 100
                while ($usedPriorities -contains $rulePriority) {
                    $rulePriority++
                }

                $candidateRuleName = "wprestore-temp-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
                Write-Step "Adding temporary SCM allow rule for $allowIpAddress/32"
                Add-TemporaryScmAllowRule -ResourceGroup $ResourceGroup -AppName $AppName -Slot $Slot `
                    -RuleName $candidateRuleName -IpAddress $allowIpAddress -Priority $rulePriority
                $temporaryScmRuleName = $candidateRuleName
                Write-Ok "Added $candidateRuleName at priority $rulePriority; it will be removed when this run finishes."
                Start-Sleep -Seconds 10
            }
        }
    }

    while (-not (Test-PortFree -CandidatePort $Port)) {
        Write-WarningMessage "Port $Port is already in use; trying $($Port + 1)."
        $Port++
    }

    Write-Step "Opening Azure remote-connection tunnel on localhost:$Port"
    $azArguments = @('webapp', 'create-remote-connection', '--resource-group', $ResourceGroup, '--name', $AppName, '--port', $Port)
    if ($Slot) {
        $azArguments += @('--slot', $Slot)
    }

    $outputLog = [IO.Path]::GetTempFileName()
    $errorLog = [IO.Path]::GetTempFileName()
    $azExecutable = (Get-Command az -ErrorAction Stop).Source
    $tunnel = Start-Process -FilePath $azExecutable -ArgumentList $azArguments -NoNewWindow -PassThru `
        -RedirectStandardOutput $outputLog -RedirectStandardError $errorLog
    Wait-TunnelReady -Process $tunnel -TunnelPort $Port -TimeoutSeconds $TunnelTimeoutSeconds `
        -OutputLog $outputLog -ErrorLog $errorLog
    $tunnelListenerProcessId = (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop |
        Select-Object -First 1).OwningProcess
    Start-Sleep -Seconds 2
    Write-Ok "Tunnel is ready on 127.0.0.1:$Port."

    $securePassword = ConvertTo-SecureString $ContainerPass -AsPlainText -Force
    $credential = [pscredential]::new($ContainerUser, $securePassword)
    $sshSession = New-SSHSession -ComputerName '127.0.0.1' -Port $Port -Credential $credential `
        -AcceptKey -Force -ConnectionTimeout $TunnelTimeoutSeconds
    Write-Ok "SSH session $($sshSession.SessionId) established."

    Write-Step 'Verifying WordPress CLI in a login shell'
    $probe = Invoke-RemoteCommand -SessionId $sshSession.SessionId `
        -Script "cd $(ConvertTo-BashLiteral $WorkingDirectory) && wp core version --allow-root" `
        -TimeoutSeconds $CommandTimeoutSeconds
    Write-Ok "Target WordPress $($probe.Output -join '') before restore."

    #region --- safety backup of the current target database ---

    if (-not $SkipSafetyBackup) {
        $safetyStamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff')
        $safetyBackupRemoteDir = "/home/backups/pre-restore-$safetyStamp"
        $safetyBackupScript = @'
set -euo pipefail
umask 077
backup_dir=__REMOTE_DIRECTORY__
mkdir -p "$backup_dir"
cd /home/site/wwwroot
wp db export "$backup_dir/db.sql" --allow-root --add-drop-table --single-transaction --quick
gzip -9 "$backup_dir/db.sql"
cd "$backup_dir"
sha256sum db.sql.gz > SHA256SUMS
'@
        $safetyBackupScript = $safetyBackupScript.Replace('__REMOTE_DIRECTORY__', (ConvertTo-BashLiteral $safetyBackupRemoteDir))

        try {
            Write-Step "Backing up the target's current database to $safetyBackupRemoteDir before restoring"
            Invoke-RemoteScript -SessionId $sshSession.SessionId -Script $safetyBackupScript -TimeoutSeconds $CommandTimeoutSeconds | Out-Null

            $safetyBackupLocalDir = Join-Path $SafetyBackupPath "$AppName-$safetyStamp"
            New-Item -ItemType Directory -Path $safetyBackupLocalDir -Force | Out-Null

            Remove-SSHSession -SessionId $sshSession.SessionId -ErrorAction SilentlyContinue | Out-Null
            $sshSession = $null
            Get-RemoteFiles -FileNames @('db.sql.gz', 'SHA256SUMS') -RemoteDirectory $safetyBackupRemoteDir `
                -DestinationDirectory $safetyBackupLocalDir -Credential $credential -TunnelPort $Port `
                -TimeoutSeconds $TransferTimeoutSeconds
            $sshSession = New-SSHSession -ComputerName '127.0.0.1' -Port $Port -Credential $credential `
                -AcceptKey -Force -ConnectionTimeout $TunnelTimeoutSeconds

            Assert-BackupChecksums -BackupDirectory $safetyBackupLocalDir -FileNames @('db.sql.gz')
            $result.SafetyBackupPath = $safetyBackupLocalDir
            Write-Ok "Safety backup of the target's prior database verified at $safetyBackupLocalDir."
        }
        catch {
            Write-WarningMessage "Could not take a safety backup of the target's current database; continuing anyway. $($_.Exception.Message)"
        }
        finally {
            if (-not $sshSession) {
                $sshSession = New-SSHSession -ComputerName '127.0.0.1' -Port $Port -Credential $credential `
                    -AcceptKey -Force -ConnectionTimeout $TunnelTimeoutSeconds
            }
        }
    }
    else {
        Write-WarningMessage 'Skipping safety backup of the target database (-SkipSafetyBackup).'
    }

    #endregion

    if (-not $Force) {
        Write-Host "`nThis will PERMANENTLY OVERWRITE the database on '$AppName' with the backup's db.sql.gz." -ForegroundColor Yellow
        if ($applyFiles) {
            Write-Host "wp-content and wp-config.php on '$AppName' will also be deleted and replaced with the backup's files.tar.gz." -ForegroundColor Yellow
        }
        if ($effectiveOldUrls.Count -gt 0) {
            Write-Host "All occurrences of $($effectiveOldUrls -join ', ') will be replaced with '$targetUrl' across every table." -ForegroundColor Yellow
        }
        $confirmation = Read-Host "Type 'yes' to continue"
        if ($confirmation -ne 'yes') {
            Write-WarningMessage 'Restore cancelled by user.'
            return [pscustomobject] $result
        }
    }

    #region --- upload the backup artifacts ---

    $restoreStamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff')
    $restoreRemoteDir = "/home/restores/$restoreStamp"
    $uploadFileNames = @('db.sql.gz')
    if ($applyFiles) {
        $uploadFileNames += 'files.tar.gz'
    }

    Invoke-RemoteCommand -SessionId $sshSession.SessionId -Script "mkdir -p -- $(ConvertTo-BashLiteral $restoreRemoteDir)" `
        -TimeoutSeconds $CommandTimeoutSeconds | Out-Null
    $restoreRemoteDirCreated = $true

    Write-Step "Uploading $($uploadFileNames -join ', ') to $restoreRemoteDir"
    Remove-SSHSession -SessionId $sshSession.SessionId -ErrorAction SilentlyContinue | Out-Null
    $sshSession = $null
    Send-RemoteFiles -FileNames $uploadFileNames -LocalDirectory $stagingDirectory -RemoteDirectory $restoreRemoteDir `
        -Credential $credential -TunnelPort $Port -TimeoutSeconds $TransferTimeoutSeconds
    $sshSession = New-SSHSession -ComputerName '127.0.0.1' -Port $Port -Credential $credential `
        -AcceptKey -Force -ConnectionTimeout $TunnelTimeoutSeconds
    Write-Ok 'Upload complete.'

    $localSums = @{}
    foreach ($line in @(Get-Content -LiteralPath (Join-Path $stagingDirectory 'SHA256SUMS'))) {
        if ($line -match '^(?<hash>[A-Fa-f0-9]{64})\s+\*?(?<name>.+)$') {
            $localSums[$Matches.name.Trim()] = $Matches.hash
        }
    }
    $checksumLines = ($uploadFileNames | ForEach-Object { "$($localSums[$_])  $_" }) -join "`n"

    Write-Step 'Verifying uploaded artifacts on the target'
    $verifyScript = @'
set -euo pipefail
cd __REMOTE_DIRECTORY__
cat > SHA256SUMS.restore <<'__SUMSEOF__'
__CHECKSUM_LINES__
__SUMSEOF__
sha256sum -c SHA256SUMS.restore
rm -f SHA256SUMS.restore
'@
    $verifyScript = $verifyScript.Replace('__REMOTE_DIRECTORY__', (ConvertTo-BashLiteral $restoreRemoteDir))
    $verifyScript = $verifyScript.Replace('__CHECKSUM_LINES__', $checksumLines)
    Invoke-RemoteScript -SessionId $sshSession.SessionId -Script $verifyScript -TimeoutSeconds $CommandTimeoutSeconds | Out-Null
    Write-Ok 'Uploaded artifacts verified on the target.'

    #endregion

    #region --- full overwrite restore ---

    $filesRestoreStep = if ($applyFiles) {
        @'
rm -rf wp-content
rm -f wp-config.php
tar -xzf "$backup_dir/files.tar.gz" -C .
chown -R www-data:www-data wp-content 2>/dev/null || true
rm -f "$backup_dir/files.tar.gz"
'@
    }
    else {
        'printf "database-only restore; wp-content/wp-config.php left untouched\\n"'
    }

    # Replaces every old URL (one per line in a heredoc, so none of them need shell-escaping here)
    # with the single resolved target URL, across all tables.
    $urlReplaceStep = if ($effectiveOldUrls.Count -gt 0) {
        @'
new_url=__NEW_URL__
while IFS= read -r old_url; do
    [ -z "$old_url" ] && continue
    [ "$old_url" = "$new_url" ] && continue
    printf 'Replacing %s -> %s\n' "$old_url" "$new_url"
    wp search-replace "$old_url" "$new_url" --all-tables --allow-root --report-changed-only
done <<'__OLDURLS_EOF__'
__OLD_URLS_LIST__
__OLDURLS_EOF__
'@
    }
    else {
        'printf "no URLs to replace\\n"'
    }

    Write-Step "Restoring the database on '$AppName' (full overwrite)"
    $restoreScript = @'
set -euo pipefail
backup_dir=__REMOTE_DIRECTORY__
cd __WORKING_DIRECTORY__

gunzip -f "$backup_dir/db.sql.gz"
wp db reset --yes --allow-root
wp db import "$backup_dir/db.sql" --allow-root
rm -f "$backup_dir/db.sql"

__FILES_RESTORE_STEP__

__URL_REPLACE_STEP__

wp cache flush --allow-root --skip-themes || true
wp rewrite flush --hard --allow-root --skip-themes || true

printf 'restored_wp_version=%s\n' "$(wp core version --allow-root)"
printf 'restored_siteurl=%s\n' "$(wp option get siteurl --allow-root)"
printf 'restored_home=%s\n' "$(wp option get home --allow-root)"
'@
    $restoreScript = $restoreScript.Replace('__REMOTE_DIRECTORY__', (ConvertTo-BashLiteral $restoreRemoteDir))
    $restoreScript = $restoreScript.Replace('__WORKING_DIRECTORY__', (ConvertTo-BashLiteral $WorkingDirectory))
    $restoreScript = $restoreScript.Replace('__FILES_RESTORE_STEP__', $filesRestoreStep.Trim())
    if ($effectiveOldUrls.Count -gt 0) {
        $urlReplaceStep = $urlReplaceStep.Replace('__NEW_URL__', (ConvertTo-BashLiteral $targetUrl))
        $urlReplaceStep = $urlReplaceStep.Replace('__OLD_URLS_LIST__', ($effectiveOldUrls -join "`n"))
    }
    $restoreScript = $restoreScript.Replace('__URL_REPLACE_STEP__', $urlReplaceStep)

    $restoreOutput = Invoke-RemoteScript -SessionId $sshSession.SessionId -Script $restoreScript -TimeoutSeconds $CommandTimeoutSeconds
    $restoreOutput.Output | ForEach-Object { Write-Ok $_ }
    Write-Ok 'Database restore complete.'
    if ($applyFiles) {
        $result.FilesRestored = $true
        Write-Ok 'wp-content and wp-config.php restore complete.'
    }
    if ($effectiveOldUrls.Count -gt 0) {
        $result.OldUrlsReplaced = $effectiveOldUrls
        Write-Ok "URL(s) replaced: $($effectiveOldUrls -join ', ') -> $targetUrl"
    }

    #endregion

    $result.Success = $true
    [pscustomobject] $result
}
finally {
    if ($temporaryBackupDirectory) {
        Remove-Item -LiteralPath $temporaryBackupDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($restoreRemoteDirCreated -and -not $KeepRemote) {
        try {
            if (-not $sshSession) {
                $sshSession = New-SSHSession -ComputerName '127.0.0.1' -Port $Port -Credential $credential `
                    -AcceptKey -Force -ConnectionTimeout $TunnelTimeoutSeconds
            }
            Write-Step "Cleaning remote restore staging directory $restoreRemoteDir"
            Invoke-RemoteCommand -SessionId $sshSession.SessionId -Script "rm -rf -- $(ConvertTo-BashLiteral $restoreRemoteDir)" `
                -TimeoutSeconds $CommandTimeoutSeconds -AllowFailure | Out-Null
        }
        catch {
            Write-WarningMessage "Could not remove remote restore staging directory: $($_.Exception.Message)"
        }
    }
    elseif ($restoreRemoteDirCreated) {
        Write-WarningMessage "Remote restore staging directory retained: $restoreRemoteDir"
    }

    if ($safetyBackupRemoteDir -and -not $KeepRemote) {
        try {
            if (-not $sshSession) {
                $sshSession = New-SSHSession -ComputerName '127.0.0.1' -Port $Port -Credential $credential `
                    -AcceptKey -Force -ConnectionTimeout $TunnelTimeoutSeconds
            }
            Invoke-RemoteCommand -SessionId $sshSession.SessionId -Script "rm -rf -- $(ConvertTo-BashLiteral $safetyBackupRemoteDir)" `
                -TimeoutSeconds $CommandTimeoutSeconds -AllowFailure | Out-Null
        }
        catch {
            Write-WarningMessage "Could not remove remote safety-backup staging directory: $($_.Exception.Message)"
        }
    }
    elseif ($safetyBackupRemoteDir) {
        Write-WarningMessage "Remote safety-backup staging directory retained: $safetyBackupRemoteDir"
    }

    if ($sshSession) {
        Remove-SSHSession -SessionId $sshSession.SessionId -ErrorAction SilentlyContinue | Out-Null
    }
    if ($tunnelListenerProcessId -and $tunnelListenerProcessId -ne $tunnel.Id) {
        Stop-Process -Id $tunnelListenerProcessId -Force -ErrorAction SilentlyContinue
    }
    if ($tunnel -and -not $tunnel.HasExited) {
        Stop-Process -Id $tunnel.Id -Force -ErrorAction SilentlyContinue
    }
    @($outputLog, $errorLog) |
        Where-Object { $_ } |
        Remove-Item -ErrorAction SilentlyContinue

    if ($temporaryScmRuleName) {
        try {
            Write-Step "Removing temporary SCM allow rule $temporaryScmRuleName"
            Remove-TemporaryScmAllowRule -ResourceGroup $ResourceGroup -AppName $AppName -Slot $Slot -RuleName $temporaryScmRuleName
            Write-Ok 'Removed.'
        }
        catch {
            Write-WarningMessage "Could not remove temporary SCM allow rule $temporaryScmRuleName. $($_.Exception.Message)"
        }
    }
    if ($restoreScmBasicAuthDisabled -and $accessRestrictions -and $accessRestrictions.AppId) {
        try {
            Write-Step 'Restoring SCM basic authentication publishing to disabled'
            Set-ScmBasicAuthPolicy -AppId $accessRestrictions.AppId -Allow $false
            Write-Ok 'Restored.'
        }
        catch {
            Write-WarningMessage "Could not restore SCM basic authentication publishing. $($_.Exception.Message)"
        }
    }
}
