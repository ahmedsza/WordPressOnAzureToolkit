<#
.SYNOPSIS
    Restores a local WordPress database export (and optionally its wp-content files) into an
    Azure Linux App Service, while keeping everything already configured in the Azure
    environment intact.

.DESCRIPTION
    Imports a local WordPress database dump (for example the one produced by a local Docker/dev
    install) into an Azure App Service WordPress container over an authenticated Azure
    remote-connection tunnel, the same way the Backup-AzureWordpress* scripts read it back out.
    It can also merge in a matching wp-content files archive (plugins/themes/mu-plugins).

    -RestoreScope controls how much of the database is touched:

    - ContentOnly (default): only content tables (posts, postmeta, comments, commentmeta, terms,
      term_taxonomy, term_relationships, termmeta) are copied from the local dump. wp_options --
      Azure's "base config" (siteurl, permalinks, mail settings, active plugins/theme, every
      plugin's own settings, API keys, etc.) -- and wp_users/wp_usermeta are never touched. This
      is done by importing the dump under a scratch table prefix in the same database, then
      swapping only the content tables into place, so -SkipUrlReplace, -SkipPluginPreservation,
      and -SkipThemePreservation do not apply (there is nothing in wp_options to fix).
    - Full: the previous behaviour. The entire dump is imported as-is (including wp_options and
      users), then Azure's site/home URL, active plugins, and active theme are restored
      afterwards. Use this only if you specifically need something else from wp_options/wp_users
      in the dump; anything not explicitly restored by this script will take on the local dump's
      value.

    Regardless of scope, this script:

    1. Snapshots the Azure site's currently active plugins, active theme, and site/home URLs
       before touching anything.
    2. Takes a safety backup of the current Azure database (skip with -SkipSafetyBackup).
    3. Uploads and imports the local SQL dump (content-only or full, per -RestoreScope).
    4. Full scope only: restores Azure's original site/home URL in the imported data (skip with
       -SkipUrlReplace, or override with -OldUrl/-NewUrl).
    5. If -FilesArchive (or an auto-detected *.tar.gz under -LocalPath) is supplied:
       - Themes are synced to match the local copy: an existing Azure theme folder is replaced
         with the local one, and any theme that doesn't exist yet on Azure is added.
       - Plugins (and mu-plugins) are added only if they don't already exist on Azure. An
         existing plugin folder is never touched, so a different version already installed on
         Azure is left exactly as-is.
       Skip this entire step with -SkipFilesMerge.
    6. Full scope only: re-applies the pre-restore plugin activation state: plugins that were
       active on Azure are re-activated (if still installed) and any plugin the import turned on
       that was not previously active on Azure is deactivated again. Skip with
       -SkipPluginPreservation.
    7. Full scope only: re-applies the pre-restore active theme, if it differs after import and
       is still installed. Skip with -SkipThemePreservation.

    This script never deletes or overwrites an existing wp-content/plugins or wp-content/mu-plugins
    folder, and never touches wp-config.php on Azure. It does overwrite an existing
    wp-content/themes folder when a matching theme is found in -FilesArchive.

.NOTES
    Requires: PowerShell 7+, Azure CLI (logged in), Posh-SSH module. -RestoreScope ContentOnly
    additionally requires a mysql/mariadb client binary inside the App Service container (already
    present alongside WP-CLI's own db commands).
    Install-Module Posh-SSH -Scope CurrentUser

.EXAMPLE
    # Content-only (default): only posts/pages/comments/terms move over. wp_options and user
    # accounts on Azure are never touched.
    ./RestoreFromLocal.ps1 -ResourceGroup rg-wp -AppName my-wp-site -LocalPath .\localbackups

.EXAMPLE
    ./RestoreFromLocal.ps1 -ResourceGroup rg-wp -AppName my-wp-site -SqlFile .\localbackups\wordpress.sql `
        -RestoreScope Full -OldUrl 'http://localhost:8080' -NewUrl 'https://my-wp-site.azurewebsites.net'

.EXAMPLE
    # Also add any plugin/theme not already present on Azure, and activate the newly added plugins.
    ./RestoreFromLocal.ps1 -ResourceGroup rg-wp -AppName my-wp-site -LocalPath .\localbackups `
        -FilesArchive .\localbackups\wordpress-files.tar.gz -ActivateNewPlugins
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $AppName,
    [string] $Slot,
    [string] $SubscriptionId,

    # Folder containing the local backup. Used to auto-detect the SQL file when -SqlFile is not given.
    [string] $LocalPath = '.\localbackups',
    # Explicit path to the local .sql or .sql.gz dump. Overrides auto-detection under -LocalPath.
    [string] $SqlFile,

    # Explicit path to a wp-content files archive (tar.gz). Auto-detected under -LocalPath when omitted.
    [string] $FilesArchive,
    [switch] $SkipFilesMerge,
    [switch] $ActivateNewPlugins,

    # ContentOnly never touches wp_options/wp_users (Azure's base config and accounts stay exactly
    # as configured). Full imports the entire dump, then patches back site URL/plugins/theme.
    [ValidateSet('ContentOnly', 'Full')] [string] $RestoreScope = 'ContentOnly',

    [string] $OldUrl,
    [string] $NewUrl,
    [switch] $SkipUrlReplace,
    [switch] $SkipPluginPreservation,
    [switch] $SkipThemePreservation,

    [switch] $SkipSafetyBackup,
    [string] $SafetyBackupPath = '.\pre-restore-backups',

    [switch] $KeepRemote,
    [switch] $Force,

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
        '--description', 'Temporary rule added by RestoreFromLocal',
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
        [Parameter(Mandatory)] [int] $TimeoutSeconds,
        [switch] $AllowFailure
    )

    $unixScript = $Script.Replace("`r`n", "`n")
    $encodedScript = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($unixScript))
    $bootstrap = 'eval "$(printf %s ' + (ConvertTo-BashLiteral $encodedScript) + ' | base64 -d)"'
    return Invoke-RemoteCommand -SessionId $SessionId -Script $bootstrap -TimeoutSeconds $TimeoutSeconds -AllowFailure:$AllowFailure
}

<#
    .SYNOPSIS
    Resolves the local .sql/.sql.gz dump to restore.
#>
function Resolve-LocalSqlFile {
    param(
        [AllowEmptyString()] [string] $SqlFile,
        [Parameter(Mandatory)] [string] $LocalPath
    )

    if ($SqlFile) {
        $resolved = Resolve-Path -LiteralPath $SqlFile -ErrorAction SilentlyContinue
        if (-not $resolved) {
            throw "SQL file not found: $SqlFile"
        }
        return $resolved.ProviderPath
    }

    if (-not (Test-Path -LiteralPath $LocalPath -PathType Container)) {
        throw "Local backup folder not found: $LocalPath. Pass -LocalPath or -SqlFile explicitly."
    }

    $candidates = @(Get-ChildItem -LiteralPath $LocalPath -File -Filter '*.sql.gz' | Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -eq 0) {
        $candidates = @(Get-ChildItem -LiteralPath $LocalPath -File -Filter '*.sql' | Sort-Object LastWriteTime -Descending)
    }
    if ($candidates.Count -eq 0) {
        throw "No .sql or .sql.gz file found under $LocalPath. Pass -SqlFile explicitly."
    }
    if ($candidates.Count -gt 1) {
        Write-WarningMessage "Multiple SQL dumps found under $LocalPath; using the most recently modified: $($candidates[0].Name)."
    }

    return $candidates[0].FullName
}

<#
    .SYNOPSIS
    Resolves the local wp-content files archive to merge, if any.
#>
function Resolve-LocalFilesArchive {
    param(
        [AllowEmptyString()] [string] $FilesArchive,
        [Parameter(Mandatory)] [string] $LocalPath
    )

    if ($FilesArchive) {
        $resolved = Resolve-Path -LiteralPath $FilesArchive -ErrorAction SilentlyContinue
        if (-not $resolved) {
            throw "Files archive not found: $FilesArchive"
        }
        return $resolved.ProviderPath
    }

    if (-not (Test-Path -LiteralPath $LocalPath -PathType Container)) {
        return $null
    }

    $candidates = @(Get-ChildItem -LiteralPath $LocalPath -File -Filter '*.tar.gz' | Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -eq 0) {
        return $null
    }
    if ($candidates.Count -gt 1) {
        Write-WarningMessage "Multiple files archives found under $LocalPath; using the most recently modified: $($candidates[0].Name)."
    }

    return $candidates[0].FullName
}

<#
    .SYNOPSIS
    Sanitizes a WP-CLI plugin/theme slug so it is safe to embed in a bash heredoc.
#>
function ConvertTo-SafePluginSlug {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Slug)

    return @($Slug | Where-Object { $_ -match '^[A-Za-z0-9_.\-/]+$' })
}

Assert-Prerequisites

$localSqlPath = Resolve-LocalSqlFile -SqlFile $SqlFile -LocalPath $LocalPath
Write-Ok "Using local dump: $localSqlPath"

$localFilesArchivePath = $null
if (-not $SkipFilesMerge) {
    $localFilesArchivePath = Resolve-LocalFilesArchive -FilesArchive $FilesArchive -LocalPath $LocalPath
    if ($localFilesArchivePath) {
        Write-Ok "Using local files archive: $localFilesArchivePath"
    }
    else {
        Write-WarningMessage 'No local files archive found; only the database will be restored. Pass -FilesArchive to also add new plugins/themes.'
    }
}

$tunnel = $null
$tunnelListenerProcessId = $null
$sshSession = $null
$outputLog = $null
$errorLog = $null
$safetyBackupRemoteDir = $null
$safetyBackupLocalDir = $null
$restoreRemoteDir = $null
$restoreRemoteDirCreated = $false
$mergeRemoteDir = $null
$mergeRemoteDirCreated = $false
$accessRestrictions = $null
$temporaryScmRuleName = $null
$restoreScmBasicAuthDisabled = $false
$credential = $null

$result = [ordered]@{
    AppName = $AppName
    RestoreScope = $RestoreScope
    RestoredFrom = $localSqlPath
    FilesArchiveUsed = $localFilesArchivePath
    SafetyBackupPath = $null
    ContentTablesCopied = @()
    ContentTablesMissingInDump = @()
    UrlReplaced = $null
    FilesAdded = @()
    ThemesUpdated = @()
    FilesSkippedExisting = @()
    PluginsKeptActive = @()
    PluginsActivatedToMatchAzure = @()
    PluginsDeactivatedToMatchAzure = @()
    PluginsMissingOnAzure = @()
    PluginsAutoActivated = @()
    ThemeKeptActive = $null
    ThemeRestored = $false
    Success = $false
}

try {
    if ($SubscriptionId) {
        az account set --subscription $SubscriptionId
        if ($LASTEXITCODE -ne 0) {
            throw "Could not select subscription $SubscriptionId."
        }
        Write-Ok "Selected subscription $SubscriptionId."
    }

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
    Write-Ok "WordPress $($probe.Output -join '')."

    #region --- snapshot current Azure state before changing anything ---

    Write-Step 'Snapshotting plugins currently configured on Azure'
    $activeProbe = Invoke-RemoteCommand -SessionId $sshSession.SessionId `
        -Script "cd $(ConvertTo-BashLiteral $WorkingDirectory) && wp plugin list --field=name --status=active --allow-root --skip-themes" `
        -TimeoutSeconds $CommandTimeoutSeconds
    $preActivePlugins = ConvertTo-SafePluginSlug -Slug @($activeProbe.Output | Where-Object { $_ -and $_.Trim() })
    $result.PluginsKeptActive = $preActivePlugins
    Write-Ok "Currently active on Azure: $($(if (@($preActivePlugins).Count) { $preActivePlugins -join ', ' } else { '(none)' }))."

    $siteUrlProbe = Invoke-RemoteCommand -SessionId $sshSession.SessionId `
        -Script "cd $(ConvertTo-BashLiteral $WorkingDirectory) && wp option get siteurl --allow-root --skip-plugins --skip-themes" `
        -TimeoutSeconds $CommandTimeoutSeconds
    $homeUrlProbe = Invoke-RemoteCommand -SessionId $sshSession.SessionId `
        -Script "cd $(ConvertTo-BashLiteral $WorkingDirectory) && wp option get home --allow-root --skip-plugins --skip-themes" `
        -TimeoutSeconds $CommandTimeoutSeconds
    $azureSiteUrl = ($siteUrlProbe.Output -join '').Trim()
    $azureHomeUrl = ($homeUrlProbe.Output -join '').Trim()
    Write-Ok "Azure siteurl=$azureSiteUrl home=$azureHomeUrl"

    $activeThemeProbe = Invoke-RemoteCommand -SessionId $sshSession.SessionId `
        -Script "cd $(ConvertTo-BashLiteral $WorkingDirectory) && wp theme list --field=name --status=active --allow-root --skip-plugins" `
        -TimeoutSeconds $CommandTimeoutSeconds
    $azureActiveTheme = (@(ConvertTo-SafePluginSlug -Slug @($activeThemeProbe.Output | Where-Object { $_ -and $_.Trim() })) | Select-Object -First 1)
    $result.ThemeKeptActive = $azureActiveTheme
    Write-Ok "Currently active theme on Azure: $($(if ($azureActiveTheme) { $azureActiveTheme } else { '(unknown)' }))"

    #endregion

    #region --- safety backup of the current Azure database ---

    if (-not $SkipSafetyBackup) {
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff')
        $safetyBackupRemoteDir = "/home/backups/pre-restore-$stamp"
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

        Write-Step "Backing up the current Azure database to $safetyBackupRemoteDir before restoring"
        Invoke-RemoteScript -SessionId $sshSession.SessionId -Script $safetyBackupScript -TimeoutSeconds $CommandTimeoutSeconds | Out-Null

        $safetyBackupLocalDir = Join-Path $SafetyBackupPath "$AppName-$stamp"
        New-Item -ItemType Directory -Path $safetyBackupLocalDir -Force | Out-Null

        Remove-SSHSession -SessionId $sshSession.SessionId -ErrorAction SilentlyContinue | Out-Null
        $sshSession = $null
        $sftpSession = New-SFTPSession -ComputerName '127.0.0.1' -Port $Port -Credential $credential `
            -AcceptKey -Force -ConnectionTimeout $TransferTimeoutSeconds -OperationTimeout $TransferTimeoutSeconds
        try {
            foreach ($fileName in @('db.sql.gz', 'SHA256SUMS')) {
                Get-SFTPItem -SessionId $sftpSession.SessionId -Path "$safetyBackupRemoteDir/$fileName" `
                    -Destination $safetyBackupLocalDir -Force -ErrorAction Stop | Out-Null
            }
        }
        finally {
            Remove-SFTPSession -SessionId $sftpSession.SessionId -ErrorAction SilentlyContinue | Out-Null
        }
        $sshSession = New-SSHSession -ComputerName '127.0.0.1' -Port $Port -Credential $credential `
            -AcceptKey -Force -ConnectionTimeout $TunnelTimeoutSeconds

        $sumsPath = Join-Path $safetyBackupLocalDir 'SHA256SUMS'
        $sumsLine = @(Get-Content -LiteralPath $sumsPath)[0]
        if ($sumsLine -notmatch '^(?<hash>[A-Fa-f0-9]{64})\s+\*?db\.sql\.gz\s*$') {
            throw 'Safety backup checksum manifest is malformed.'
        }
        $localHash = (Get-FileHash -LiteralPath (Join-Path $safetyBackupLocalDir 'db.sql.gz') -Algorithm SHA256).Hash
        if ($localHash -ine $Matches.hash) {
            throw 'Safety backup db.sql.gz failed SHA256 verification; aborting before touching the live database.'
        }
        $result.SafetyBackupPath = $safetyBackupLocalDir
        Write-Ok "Safety backup verified at $safetyBackupLocalDir."
    }
    else {
        Write-WarningMessage 'Skipping safety backup of the current Azure database (-SkipSafetyBackup).'
    }

    #endregion

    if (-not $Force) {
        Write-Host "`nThis will import the local dump ($([IO.Path]::GetFileName($localSqlPath))) into '$AppName'." -ForegroundColor Yellow
        if ($RestoreScope -eq 'ContentOnly') {
            Write-Host 'Only content (posts, pages, comments, terms) will be replaced. wp_options (site config) and user accounts on Azure are never touched.' -ForegroundColor Yellow
        }
        else {
            Write-Host 'Full scope: the entire database will be overwritten, then plugins and the active theme currently configured on Azure will be restored to that same state afterwards.' -ForegroundColor Yellow
        }
        if ($localFilesArchivePath) {
            Write-Host "Themes from $([IO.Path]::GetFileName($localFilesArchivePath)) will be synced (existing Azure themes overwritten); new plugins will be added without touching existing ones." -ForegroundColor Yellow
        }
        $confirmation = Read-Host "Type 'yes' to continue"
        if ($confirmation -ne 'yes') {
            Write-WarningMessage 'Restore cancelled by user.'
            return [pscustomobject] $result
        }
    }

    #region --- upload and import the local dump ---

    $restoreStamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff')
    $restoreRemoteDir = "/home/restores/$restoreStamp"
    $remoteFileName = [IO.Path]::GetFileName($localSqlPath)

    Invoke-RemoteCommand -SessionId $sshSession.SessionId `
        -Script "mkdir -p -- $(ConvertTo-BashLiteral $restoreRemoteDir)" `
        -TimeoutSeconds $CommandTimeoutSeconds | Out-Null
    $restoreRemoteDirCreated = $true

    Write-Step "Uploading $remoteFileName to $restoreRemoteDir"
    Remove-SSHSession -SessionId $sshSession.SessionId -ErrorAction SilentlyContinue | Out-Null
    $sshSession = $null
    $sftpSession = New-SFTPSession -ComputerName '127.0.0.1' -Port $Port -Credential $credential `
        -AcceptKey -Force -ConnectionTimeout $TransferTimeoutSeconds -OperationTimeout $TransferTimeoutSeconds
    try {
        Set-SFTPItem -SessionId $sftpSession.SessionId -Path $localSqlPath -Destination $restoreRemoteDir -Force | Out-Null
    }
    finally {
        Remove-SFTPSession -SessionId $sftpSession.SessionId -ErrorAction SilentlyContinue | Out-Null
    }
    $sshSession = New-SSHSession -ComputerName '127.0.0.1' -Port $Port -Credential $credential `
        -AcceptKey -Force -ConnectionTimeout $TunnelTimeoutSeconds
    Write-Ok 'Upload complete.'

    Write-Step 'Importing the local dump into the Azure database'
    if ($RestoreScope -eq 'ContentOnly') {
        $importScript = @'
set -euo pipefail
cd /home/site/wwwroot
sql_file=__SQL_FILE__
if [[ "$sql_file" == *.gz ]]; then
    gunzip -f "$sql_file"
    sql_file="${sql_file%.gz}"
fi

command -v mysql >/dev/null 2>&1 || { echo "ERROR: mysql client not found in the container." >&2; exit 1; }

db_host=$(wp config get DB_HOST --allow-root --skip-plugins --skip-themes)
db_name=$(wp config get DB_NAME --allow-root --skip-plugins --skip-themes)
db_user=$(wp config get DB_USER --allow-root --skip-plugins --skip-themes)
db_pass=$(wp config get DB_PASSWORD --allow-root --skip-plugins --skip-themes)
prefix=$(wp config get table_prefix --allow-root --skip-plugins --skip-themes)

mysql_host="${db_host%%:*}"
mysql_port=3306
if [[ "$db_host" == *:* ]]; then
    mysql_port="${db_host##*:}"
fi

export MYSQL_PWD="$db_pass"
mysql_args=(--host="$mysql_host" --port="$mysql_port" --user="$db_user" --protocol=TCP)

if ! grep -qF "\`${prefix}posts\`" "$sql_file"; then
    echo "ERROR: dump does not contain a \`${prefix}posts\` table; table prefix mismatch between the local dump and Azure. Aborting without changing anything." >&2
    exit 1
fi

scratch_prefix=__SCRATCH_PREFIX__

# MySQL identifiers are capped at 64 chars; verify the longer scratch prefix still fits.
max_suffix_len=$(grep -oE "\`${prefix}[A-Za-z0-9_]+\`" "$sql_file" | awk -F'`' '{ print length($2) - length("'"${prefix}"'") }' | sort -n | tail -1)
if [ -n "$max_suffix_len" ]; then
    worst_len=$(( ${#scratch_prefix} + max_suffix_len ))
    if [ "$worst_len" -gt 64 ]; then
        echo "ERROR: scratch prefix '${scratch_prefix}' would create a table identifier ${worst_len} characters long (MySQL's limit is 64). Aborting without changing anything." >&2
        exit 1
    fi
fi

cleanup() {
    local leftover t
    leftover=$(mysql "${mysql_args[@]}" -N -B "$db_name" -e "SHOW TABLES LIKE '${scratch_prefix}%'" 2>/dev/null || true)
    for t in $leftover; do
        mysql "${mysql_args[@]}" "$db_name" -e "DROP TABLE IF EXISTS \`$t\`;" 2>/dev/null || true
    done
}
trap cleanup EXIT

sed -E "s/\`${prefix}/\`${scratch_prefix}/g" "$sql_file" | mysql "${mysql_args[@]}" "$db_name"

# The dump's own siteurl/home, read from the scratch copy of wp_options (never applied to Azure).
old_site_url_from_dump=$(mysql "${mysql_args[@]}" -N -B "$db_name" -e "SELECT option_value FROM \`${scratch_prefix}options\` WHERE option_name='siteurl' LIMIT 1;" 2>/dev/null || true)
old_home_url=$(mysql "${mysql_args[@]}" -N -B "$db_name" -e "SELECT option_value FROM \`${scratch_prefix}options\` WHERE option_name='home' LIMIT 1;" 2>/dev/null || true)

content_tables=(posts postmeta comments commentmeta terms term_taxonomy term_relationships termmeta)
copied=()
missing=()
for t in "${content_tables[@]}"; do
    scratch_table="${scratch_prefix}${t}"
    prod_table="${prefix}${t}"
    exists=$(mysql "${mysql_args[@]}" -N -B "$db_name" -e "SHOW TABLES LIKE '${scratch_table}'" | wc -l)
    if [ "$exists" -eq 0 ]; then
        missing+=("$prod_table")
        continue
    fi
    mysql "${mysql_args[@]}" "$db_name" -e "DROP TABLE IF EXISTS \`${prod_table}\`; RENAME TABLE \`${scratch_table}\` TO \`${prod_table}\`;"
    copied+=("$prod_table")
done

# Fix links hard-coded into the imported content (e.g. localhost URLs baked into post_content),
# without touching wp_options -- restricted to just the tables copied above.
azure_site_url=$(wp option get siteurl --allow-root --skip-plugins --skip-themes)
azure_home_url=$(wp option get home --allow-root --skip-plugins --skip-themes)

old_url_override=__OLD_URL_OVERRIDE__
new_url_override=__NEW_URL_OVERRIDE__
old_site_url="$old_site_url_from_dump"
azure_site_url_target="$azure_site_url"
if [ -n "$old_url_override" ]; then
    old_site_url="$old_url_override"
fi
if [ -n "$new_url_override" ]; then
    azure_site_url_target="$new_url_override"
fi

url_pairs_from=()
url_pairs_to=()
if [ -n "$old_site_url" ] && [ "$old_site_url" != "$azure_site_url_target" ]; then
    url_pairs_from+=("$old_site_url")
    url_pairs_to+=("$azure_site_url_target")
fi
if [ -z "$old_url_override" ] && [ -z "$new_url_override" ] && [ -n "$old_home_url" ] && [ "$old_home_url" != "$old_site_url_from_dump" ] && [ "$old_home_url" != "$azure_home_url" ]; then
    url_pairs_from+=("$old_home_url")
    url_pairs_to+=("$azure_home_url")
fi

url_replaced=()
if [ __SKIP_URL_REPLACE__ != "true" ] && [ "${#copied[@]}" -gt 0 ]; then
    for i in "${!url_pairs_from[@]}"; do
        wp search-replace "${url_pairs_from[$i]}" "${url_pairs_to[$i]}" "${copied[@]}" --precise --recurse-objects --allow-root --skip-plugins --skip-themes --report-changed-only >/dev/null
        url_replaced+=("${url_pairs_from[$i]}||${url_pairs_to[$i]}")
    done
fi

printf 'COPIED=%s\n' "${copied[*]-}"
printf 'MISSING=%s\n' "${missing[*]-}"
printf 'URLREPLACED=%s\n' "$(IFS=';'; echo "${url_replaced[*]-}")"
'@
        $scratchPrefix = "zzrs$([guid]::NewGuid().ToString('N').Substring(0, 4))_"
        $importScript = $importScript.Replace('__SQL_FILE__', (ConvertTo-BashLiteral "$restoreRemoteDir/$remoteFileName"))
        $importScript = $importScript.Replace('__SCRATCH_PREFIX__', (ConvertTo-BashLiteral $scratchPrefix))
        $importScript = $importScript.Replace('__OLD_URL_OVERRIDE__', (ConvertTo-BashLiteral $OldUrl))
        $importScript = $importScript.Replace('__NEW_URL_OVERRIDE__', (ConvertTo-BashLiteral $NewUrl))
        $importScript = $importScript.Replace('__SKIP_URL_REPLACE__', (ConvertTo-BashLiteral $(if ($SkipUrlReplace) { 'true' } else { 'false' })))
        $importResult = Invoke-RemoteScript -SessionId $sshSession.SessionId -Script $importScript -TimeoutSeconds $CommandTimeoutSeconds

        foreach ($line in $importResult.Output) {
            if ($line -match '^COPIED=(?<v>.*)$') {
                $result.ContentTablesCopied = @($Matches.v -split '\s+' | Where-Object { $_ })
            }
            elseif ($line -match '^MISSING=(?<v>.*)$') {
                $result.ContentTablesMissingInDump = @($Matches.v -split '\s+' | Where-Object { $_ })
            }
            elseif ($line -match '^URLREPLACED=(?<v>.*)$') {
                $result.UrlReplaced = @($Matches.v -split ';' | Where-Object { $_ } | ForEach-Object {
                    $parts = $_ -split '\|\|', 2
                    [pscustomobject]@{ From = $parts[0]; To = $parts[1] }
                })
            }
        }
        Write-Ok "Content tables copied: $($result.ContentTablesCopied -join ', ')"
        if (@($result.ContentTablesMissingInDump).Count) {
            Write-WarningMessage "Not found in the dump, left untouched on Azure: $($result.ContentTablesMissingInDump -join ', ')"
        }
        if (@($result.UrlReplaced).Count) {
            foreach ($pair in $result.UrlReplaced) {
                Write-Ok "Replaced '$($pair.From)' with '$($pair.To)' in the copied content tables."
            }
        }
        Write-Ok 'wp_options and user accounts on Azure were not touched (content-only restore).'
    }
    else {
        $importScript = @'
set -euo pipefail
cd /home/site/wwwroot
sql_file=__SQL_FILE__
if [[ "$sql_file" == *.gz ]]; then
    gunzip -f "$sql_file"
    sql_file="${sql_file%.gz}"
fi
wp db import "$sql_file" --allow-root --skip-plugins --skip-themes
'@
        $importScript = $importScript.Replace('__SQL_FILE__', (ConvertTo-BashLiteral "$restoreRemoteDir/$remoteFileName"))
        Invoke-RemoteScript -SessionId $sshSession.SessionId -Script $importScript -TimeoutSeconds $CommandTimeoutSeconds | Out-Null
        Write-Ok 'Database import complete.'
    }

    #endregion

    #region --- restore Azure's site URL in the imported data (full scope only) ---

    if ($RestoreScope -ne 'Full') {
        Write-WarningMessage 'Site URL is unaffected (content-only restore never touches wp_options).'
    }
    elseif (-not $SkipUrlReplace) {
        $importedSiteUrlProbe = Invoke-RemoteCommand -SessionId $sshSession.SessionId `
            -Script "cd $(ConvertTo-BashLiteral $WorkingDirectory) && wp option get siteurl --allow-root --skip-plugins --skip-themes" `
            -TimeoutSeconds $CommandTimeoutSeconds
        $importedHomeUrlProbe = Invoke-RemoteCommand -SessionId $sshSession.SessionId `
            -Script "cd $(ConvertTo-BashLiteral $WorkingDirectory) && wp option get home --allow-root --skip-plugins --skip-themes" `
            -TimeoutSeconds $CommandTimeoutSeconds
        $importedSiteUrl = ($importedSiteUrlProbe.Output -join '').Trim()
        $importedHomeUrl = ($importedHomeUrlProbe.Output -join '').Trim()

        $fromUrl = if ($OldUrl) { $OldUrl } else { $importedSiteUrl }
        $toUrl = if ($NewUrl) { $NewUrl } else { $azureSiteUrl }

        $urlPairs = [System.Collections.Generic.List[string[]]]::new()
        if ($fromUrl -and $toUrl -and $fromUrl -ne $toUrl) {
            $urlPairs.Add(@($fromUrl, $toUrl))
        }
        if (-not $OldUrl -and -not $NewUrl -and $importedHomeUrl -and $azureHomeUrl -and
            $importedHomeUrl -ne $azureHomeUrl -and $importedHomeUrl -ne $importedSiteUrl) {
            $urlPairs.Add(@($importedHomeUrl, $azureHomeUrl))
        }

        if ($urlPairs.Count -eq 0) {
            Write-Ok 'Imported URLs already match the Azure site; no search-replace needed.'
        }
        else {
            foreach ($pair in $urlPairs) {
                Write-Step "Replacing '$($pair[0])' with '$($pair[1])' across all tables"
                $searchReplaceScript = "cd $(ConvertTo-BashLiteral $WorkingDirectory) && wp search-replace $(ConvertTo-BashLiteral $pair[0]) $(ConvertTo-BashLiteral $pair[1]) --all-tables --precise --recurse-objects --allow-root --skip-plugins --skip-themes --report-changed-only"
                Invoke-RemoteCommand -SessionId $sshSession.SessionId -Script $searchReplaceScript `
                    -TimeoutSeconds $CommandTimeoutSeconds | Out-Null
            }
            $result.UrlReplaced = @($urlPairs | ForEach-Object { [pscustomobject]@{ From = $_[0]; To = $_[1] } })
            Write-Ok 'URL replacement complete.'
        }
    }
    else {
        Write-WarningMessage 'Skipping site URL replacement (-SkipUrlReplace).'
    }

    #endregion

    #region --- add new plugins/themes/mu-plugins found locally (never overwrites an existing Azure folder) ---

    if ($localFilesArchivePath) {
        $mergeRemoteDir = "/home/restores/$restoreStamp-files"
        $remoteArchiveName = [IO.Path]::GetFileName($localFilesArchivePath)

        Invoke-RemoteCommand -SessionId $sshSession.SessionId `
            -Script "mkdir -p -- $(ConvertTo-BashLiteral $mergeRemoteDir)" `
            -TimeoutSeconds $CommandTimeoutSeconds | Out-Null
        $mergeRemoteDirCreated = $true

        Write-Step "Uploading $remoteArchiveName to $mergeRemoteDir"
        Remove-SSHSession -SessionId $sshSession.SessionId -ErrorAction SilentlyContinue | Out-Null
        $sshSession = $null
        $sftpSession = New-SFTPSession -ComputerName '127.0.0.1' -Port $Port -Credential $credential `
            -AcceptKey -Force -ConnectionTimeout $TransferTimeoutSeconds -OperationTimeout $TransferTimeoutSeconds
        try {
            Set-SFTPItem -SessionId $sftpSession.SessionId -Path $localFilesArchivePath -Destination $mergeRemoteDir -Force | Out-Null
        }
        finally {
            Remove-SFTPSession -SessionId $sftpSession.SessionId -ErrorAction SilentlyContinue | Out-Null
        }
        $sshSession = New-SSHSession -ComputerName '127.0.0.1' -Port $Port -Credential $credential `
            -AcceptKey -Force -ConnectionTimeout $TunnelTimeoutSeconds
        Write-Ok 'Upload complete.'

        Write-Step 'Syncing themes to the local backup and adding any new plugins (existing plugins are left untouched)'
        $mergeScript = @'
set -euo pipefail
archive=__ARCHIVE__
stage=__STAGE_DIR__
mkdir -p "$stage/extracted"
tar -xzf "$archive" -C "$stage/extracted"

dest_root=/home/site/wwwroot/wp-content
added=()
updated=()
skipped=()

# add-only: never touches a folder that already exists on Azure.
# overwrite: replaces an existing folder's contents with the local copy.
merge_category() {
    local category="$1"
    local mode="$2"
    local src_dir="$stage/extracted/wp-content/$category"
    local dest_dir="$dest_root/$category"
    [ -d "$src_dir" ] || return 0
    mkdir -p "$dest_dir"
    local entry name
    for entry in "$src_dir"/*/; do
        [ -d "$entry" ] || continue
        name=$(basename "$entry")
        if [ -e "$dest_dir/$name" ]; then
            if [ "$mode" = "overwrite" ]; then
                rm -rf -- "$dest_dir/$name"
                # -r (not -a): /home is Azure Files (SMB), which rejects preserving POSIX mode/ownership.
                cp -r "$entry" "$dest_dir/$name"
                chown -R www-data:www-data "$dest_dir/$name" 2>/dev/null || true
                updated+=("$category/$name")
            else
                skipped+=("$category/$name")
            fi
        else
            cp -r "$entry" "$dest_dir/$name"
            chown -R www-data:www-data "$dest_dir/$name" 2>/dev/null || true
            added+=("$category/$name")
        fi
    done
}

merge_category plugins add-only
merge_category themes overwrite
merge_category mu-plugins add-only

rm -rf -- "$stage/extracted"

printf 'ADDED=%s\n' "${added[*]-}"
printf 'UPDATED=%s\n' "${updated[*]-}"
printf 'SKIPPED=%s\n' "${skipped[*]-}"
'@
        $mergeScript = $mergeScript.Replace('__ARCHIVE__', (ConvertTo-BashLiteral "$mergeRemoteDir/$remoteArchiveName"))
        $mergeScript = $mergeScript.Replace('__STAGE_DIR__', (ConvertTo-BashLiteral $mergeRemoteDir))
        $mergeResult = Invoke-RemoteScript -SessionId $sshSession.SessionId -Script $mergeScript -TimeoutSeconds $CommandTimeoutSeconds

        foreach ($line in $mergeResult.Output) {
            if ($line -match '^ADDED=(?<v>.*)$') {
                $result.FilesAdded = @($Matches.v -split '\s+' | Where-Object { $_ })
            }
            elseif ($line -match '^UPDATED=(?<v>.*)$') {
                $result.ThemesUpdated = @($Matches.v -split '\s+' | Where-Object { $_ })
            }
            elseif ($line -match '^SKIPPED=(?<v>.*)$') {
                $result.FilesSkippedExisting = @($Matches.v -split '\s+' | Where-Object { $_ })
            }
        }

        if (@($result.FilesAdded).Count) {
            Write-Ok "Added (new on Azure): $($result.FilesAdded -join ', ')"
        }
        if (@($result.ThemesUpdated).Count) {
            Write-Ok "Updated to match the local copy: $($result.ThemesUpdated -join ', ')"
        }
        if (@($result.FilesSkippedExisting).Count) {
            Write-Ok "Plugins left untouched (already exist on Azure): $($result.FilesSkippedExisting -join ', ')"
        }
        if (-not @($result.FilesAdded).Count -and -not @($result.ThemesUpdated).Count -and -not @($result.FilesSkippedExisting).Count) {
            Write-WarningMessage 'The local files archive did not contain a wp-content/plugins, wp-content/themes, or wp-content/mu-plugins folder.'
        }
    }

    #endregion

    #region --- re-apply the pre-restore plugin activation state (full scope only) ---

    if ($RestoreScope -ne 'Full') {
        Write-WarningMessage 'Plugin activation state is unaffected (content-only restore never touches wp_options).'
        if ($ActivateNewPlugins) {
            Write-WarningMessage '-ActivateNewPlugins is ignored in ContentOnly scope (it would touch wp_options); use -RestoreScope Full if you need it.'
        }
    }
    elseif (-not $SkipPluginPreservation) {
        Write-Step 'Restoring the plugin activation state that was configured on Azure'
        $desiredActiveList = ($preActivePlugins -join "`n")
        $reconcileScript = @'
set -euo pipefail
cd /home/site/wwwroot

mapfile -t desired_active <<'PLUGIN_LIST_EOF'
__DESIRED_ACTIVE__
PLUGIN_LIST_EOF

mapfile -t all_installed < <(wp plugin list --field=name --allow-root --skip-themes)
mapfile -t current_active < <(wp plugin list --field=name --status=active --allow-root --skip-themes)

is_in() {
    local needle="$1"; shift
    local item
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

activated=()
missing=()
for slug in "${desired_active[@]}"; do
    [ -z "$slug" ] && continue
    if is_in "$slug" "${current_active[@]}"; then
        continue
    fi
    if is_in "$slug" "${all_installed[@]}"; then
        wp plugin activate "$slug" --allow-root --skip-themes >/dev/null
        activated+=("$slug")
    else
        missing+=("$slug")
    fi
done

deactivated=()
for slug in "${current_active[@]}"; do
    [ -z "$slug" ] && continue
    if ! is_in "$slug" "${desired_active[@]}"; then
        wp plugin deactivate "$slug" --allow-root --skip-themes >/dev/null
        deactivated+=("$slug")
    fi
done

printf 'ACTIVATED=%s\n' "${activated[*]-}"
printf 'DEACTIVATED=%s\n' "${deactivated[*]-}"
printf 'MISSING=%s\n' "${missing[*]-}"
'@
        $reconcileScript = $reconcileScript.Replace('__DESIRED_ACTIVE__', $desiredActiveList)
        $reconcileResult = Invoke-RemoteScript -SessionId $sshSession.SessionId -Script $reconcileScript `
            -TimeoutSeconds $CommandTimeoutSeconds

        foreach ($line in $reconcileResult.Output) {
            if ($line -match '^ACTIVATED=(?<v>.*)$') {
                $result.PluginsActivatedToMatchAzure = @($Matches.v -split '\s+' | Where-Object { $_ })
            }
            elseif ($line -match '^DEACTIVATED=(?<v>.*)$') {
                $result.PluginsDeactivatedToMatchAzure = @($Matches.v -split '\s+' | Where-Object { $_ })
            }
            elseif ($line -match '^MISSING=(?<v>.*)$') {
                $result.PluginsMissingOnAzure = @($Matches.v -split '\s+' | Where-Object { $_ })
            }
        }

        if (@($result.PluginsActivatedToMatchAzure).Count) {
            Write-Ok "Re-activated to match Azure: $($result.PluginsActivatedToMatchAzure -join ', ')"
        }
        if (@($result.PluginsDeactivatedToMatchAzure).Count) {
            Write-Ok "Deactivated (were not active on Azure before restore): $($result.PluginsDeactivatedToMatchAzure -join ', ')"
        }
        if (@($result.PluginsMissingOnAzure).Count) {
            Write-WarningMessage "Previously active on Azure but not installed there, so they could not be reactivated: $($result.PluginsMissingOnAzure -join ', ')"
        }
        if (-not @($result.PluginsActivatedToMatchAzure).Count -and -not @($result.PluginsDeactivatedToMatchAzure).Count) {
            Write-Ok 'Plugin activation state already matched Azure; nothing to change.'
        }
    }
    else {
        Write-WarningMessage 'Skipping plugin activation reconciliation (-SkipPluginPreservation). The imported dump''s plugin state applies as-is.'
    }

    if ($RestoreScope -eq 'Full' -and $ActivateNewPlugins -and @($result.FilesAdded).Count) {
        $newPluginSlugs = @(
            $result.FilesAdded |
                Where-Object { $_ -like 'plugins/*' } |
                ForEach-Object { $_.Substring('plugins/'.Length) }
        )
        $newPluginSlugs = ConvertTo-SafePluginSlug -Slug $newPluginSlugs
        if (@($newPluginSlugs).Count) {
            Write-Step 'Activating newly added plugins (-ActivateNewPlugins)'
            foreach ($slug in $newPluginSlugs) {
                Invoke-RemoteCommand -SessionId $sshSession.SessionId `
                    -Script "cd $(ConvertTo-BashLiteral $WorkingDirectory) && wp plugin activate $(ConvertTo-BashLiteral $slug) --allow-root --skip-themes" `
                    -TimeoutSeconds $CommandTimeoutSeconds -AllowFailure | Out-Null
            }
            $result.PluginsAutoActivated = $newPluginSlugs
            Write-Ok "Activated: $($newPluginSlugs -join ', ')"
        }
    }

    #endregion

    #region --- re-apply the pre-restore active theme (full scope only) ---

    if ($RestoreScope -ne 'Full') {
        Write-WarningMessage 'Active theme selection is unaffected (content-only restore never touches wp_options).'
    }
    elseif (-not $SkipThemePreservation -and $azureActiveTheme) {
        $importedActiveThemeProbe = Invoke-RemoteCommand -SessionId $sshSession.SessionId `
            -Script "cd $(ConvertTo-BashLiteral $WorkingDirectory) && wp theme list --field=name --status=active --allow-root --skip-plugins" `
            -TimeoutSeconds $CommandTimeoutSeconds
        $importedActiveTheme = (@(ConvertTo-SafePluginSlug -Slug @($importedActiveThemeProbe.Output | Where-Object { $_ -and $_.Trim() })) | Select-Object -First 1)

        if ($importedActiveTheme -eq $azureActiveTheme) {
            Write-Ok "Active theme already matches Azure ($azureActiveTheme)."
        }
        else {
            $installedThemesProbe = Invoke-RemoteCommand -SessionId $sshSession.SessionId `
                -Script "cd $(ConvertTo-BashLiteral $WorkingDirectory) && wp theme list --field=name --allow-root --skip-plugins" `
                -TimeoutSeconds $CommandTimeoutSeconds
            $installedThemes = @(ConvertTo-SafePluginSlug -Slug @($installedThemesProbe.Output | Where-Object { $_ -and $_.Trim() }))

            if ($installedThemes -contains $azureActiveTheme) {
                Write-Step "Restoring the Azure active theme ($azureActiveTheme, import selected $importedActiveTheme)"
                Invoke-RemoteCommand -SessionId $sshSession.SessionId `
                    -Script "cd $(ConvertTo-BashLiteral $WorkingDirectory) && wp theme activate $(ConvertTo-BashLiteral $azureActiveTheme) --allow-root --skip-plugins" `
                    -TimeoutSeconds $CommandTimeoutSeconds | Out-Null
                $result.ThemeRestored = $true
                Write-Ok "Active theme restored to $azureActiveTheme."
            }
            else {
                Write-WarningMessage "Azure's previously active theme ($azureActiveTheme) is not installed there; leaving the imported theme ($importedActiveTheme) active."
            }
        }
    }
    elseif ($SkipThemePreservation) {
        Write-WarningMessage 'Skipping active-theme reconciliation (-SkipThemePreservation). The imported dump''s active theme applies as-is.'
    }

    #endregion

    Write-Step 'Flushing cache and rewrite rules'
    Invoke-RemoteCommand -SessionId $sshSession.SessionId `
        -Script "cd $(ConvertTo-BashLiteral $WorkingDirectory) && wp cache flush --allow-root --skip-themes" `
        -TimeoutSeconds $CommandTimeoutSeconds -AllowFailure | Out-Null
    Invoke-RemoteCommand -SessionId $sshSession.SessionId `
        -Script "cd $(ConvertTo-BashLiteral $WorkingDirectory) && wp rewrite flush --hard --allow-root --skip-themes" `
        -TimeoutSeconds $CommandTimeoutSeconds -AllowFailure | Out-Null
    Write-Ok 'Done.'

    $result.Success = $true
    [pscustomobject] $result
}
finally {
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

    if ($mergeRemoteDirCreated -and -not $KeepRemote) {
        try {
            if (-not $sshSession) {
                $sshSession = New-SSHSession -ComputerName '127.0.0.1' -Port $Port -Credential $credential `
                    -AcceptKey -Force -ConnectionTimeout $TunnelTimeoutSeconds
            }
            Write-Step "Cleaning remote files-merge staging directory $mergeRemoteDir"
            Invoke-RemoteCommand -SessionId $sshSession.SessionId -Script "rm -rf -- $(ConvertTo-BashLiteral $mergeRemoteDir)" `
                -TimeoutSeconds $CommandTimeoutSeconds -AllowFailure | Out-Null
        }
        catch {
            Write-WarningMessage "Could not remove remote files-merge staging directory: $($_.Exception.Message)"
        }
    }
    elseif ($mergeRemoteDirCreated) {
        Write-WarningMessage "Remote files-merge staging directory retained: $mergeRemoteDir"
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
