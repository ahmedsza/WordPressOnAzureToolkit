<#
.SYNOPSIS
    Backs up a WordPress App Service over an authenticated Azure remote-connection tunnel.

.DESCRIPTION
    Creates database and optional file archives in persistent App Service storage, downloads
    them through the same SSH tunnel with Posh-SSH, verifies SHA256 checksums, and writes the
    verified backup to either a local directory or an Azure Blob container using a SAS URI.

    Before connecting, it checks the SCM access restrictions and SCM basic-authentication policy.
    The remote-connection tunnel authenticates to the SCM endpoint with publishing credentials, so
    both must permit this machine. When either would block the tunnel, this script applies the
    narrowest temporary change that unblocks it and reverts that change when the backup finishes.
#>

[CmdletBinding(DefaultParameterSetName = 'Local')]
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $AppName,
    [Parameter(Mandatory, ParameterSetName = 'Local')]
    [Parameter(Mandatory, ParameterSetName = 'Blob')]
    [ValidateSet('Local', 'Blob')]
    [string] $Destination,
    [string] $Slot,
    [string] $SubscriptionId,
    [Parameter(Mandatory, ParameterSetName = 'Local')] [string] $LocalPath,
    [Parameter(Mandatory, ParameterSetName = 'Blob')] [string] $BlobSasUri,
    [string[]] $ExcludeTables = @('wp_actionscheduler_logs'),
    [switch] $DatabaseOnly,
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

if ($Destination -eq 'Local' -and $PSBoundParameters.ContainsKey('BlobSasUri')) {
    throw 'BlobSasUri cannot be used when Destination is Local.'
}
if ($Destination -eq 'Blob' -and $PSBoundParameters.ContainsKey('LocalPath')) {
    throw 'LocalPath cannot be used when Destination is Blob.'
}

$ContainerUser = 'root'
$ContainerPass = 'Docker!'
$WorkingDirectory = '/home/site/wwwroot'

function Write-Step { param([string] $Message) Write-Host "`n$Message" -ForegroundColor Cyan }
function Write-Ok { param([string] $Message) Write-Host "  $Message" -ForegroundColor Green }
function Write-WarningMessage { param([string] $Message) Write-Host "  $Message" -ForegroundColor Yellow }

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

    # The remote-connection tunnel reaches the app through the SCM site, so SCM rules gate this backup.
    $effectiveScmRules = if ($scmUsesMain) { $mainRules } else { $scmRules }
    $effectiveScmDefault = if ($scmUsesMain) { $mainDefault } else { $scmDefault }

    Write-Ok "Main site: default action $mainDefault, $($mainRules.Count) rule(s). Not used by this backup."
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
        '--description', 'Temporary rule added by Backup-AzureWordpressv5',
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
        Write-Ok 'Downloaded artifacts with Posh-SSH SFTP.'
    }
    finally {
        if ($sftpSession) {
            Remove-SFTPSession -SessionId $sftpSession.SessionId -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

function Assert-LocalChecksums {
    param(
        [Parameter(Mandatory)] [string] $BackupDirectory,
        [Parameter(Mandatory)] [string[]] $ExpectedFileNames
    )

    $sumsPath = Join-Path $BackupDirectory 'SHA256SUMS'
    if (-not (Test-Path -LiteralPath $sumsPath -PathType Leaf)) {
        throw 'Downloaded backup is missing SHA256SUMS.'
    }

    $failures = [System.Collections.Generic.List[string]]::new()
    $expectedPayloadNames = @($ExpectedFileNames | Where-Object { $_ -ne 'SHA256SUMS' })
    $entries = @{}
    $lines = @(Get-Content -LiteralPath $sumsPath)
    if ($lines.Count -eq 0) {
        $failures.Add('checksum manifest is empty')
    }

    foreach ($line in $lines) {
        if ($line -notmatch '^(?<hash>[A-Fa-f0-9]{64})\s+\*?(?<name>.+)$') {
            $failures.Add("invalid checksum entry: $line")
            continue
        }

        $fileName = $Matches.name.Trim()
        if ([IO.Path]::IsPathRooted($fileName) -or $fileName.Contains('/') -or
            $fileName.Contains('\') -or $fileName -eq '..') {
            $failures.Add("invalid checksum file name: $fileName")
            continue
        }
        if ($entries.ContainsKey($fileName)) {
            $failures.Add("duplicate checksum entry: $fileName")
            continue
        }

        $entries[$fileName] = $Matches.hash
        if ($fileName -notin $expectedPayloadNames) {
            $failures.Add("unexpected checksum entry: $fileName")
            continue
        }

        $localFile = Join-Path $BackupDirectory $fileName
        if (-not (Test-Path -LiteralPath $localFile -PathType Leaf)) {
            $failures.Add("$fileName is missing")
            continue
        }

        $actual = (Get-FileHash -LiteralPath $localFile -Algorithm SHA256).Hash
        if ($actual -ine $Matches.hash) {
            $failures.Add("$fileName hash mismatch")
        }
    }

    foreach ($expectedFileName in $expectedPayloadNames) {
        if (-not $entries.ContainsKey($expectedFileName)) {
            $failures.Add("$expectedFileName is missing from SHA256SUMS")
        }
    }

    if ($failures.Count -gt 0) {
        throw "Local SHA256 verification failed: $($failures -join '; ')"
    }

    Write-Ok 'All downloaded SHA256 checksums match.'
}

function Get-FileContentMd5 {
    param([Parameter(Mandatory)] [string] $Path)

    $stream = [IO.File]::OpenRead($Path)
    try {
        $md5 = [Security.Cryptography.MD5]::Create()
        try {
            return [Convert]::ToBase64String($md5.ComputeHash($stream))
        }
        finally {
            $md5.Dispose()
        }
    }
    finally {
        $stream.Dispose()
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

function Send-BackupToBlob {
    param(
        [Parameter(Mandatory)] [string] $BackupDirectory,
        [Parameter(Mandatory)] [string[]] $FileNames,
        [Parameter(Mandatory)] [string] $BlobPrefix,
        [Parameter(Mandatory)] [string] $ContainerSasUri
    )

    $sas = ConvertFrom-BlobContainerSasUri -BlobSasUri $ContainerSasUri
    $previousSasToken = [Environment]::GetEnvironmentVariable('AZURE_STORAGE_SAS_TOKEN', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('AZURE_STORAGE_SAS_TOKEN', $sas.SasToken, 'Process')
        $orderedFileNames = @($FileNames | Where-Object { $_ -ne 'SHA256SUMS' }) + 'SHA256SUMS'

        foreach ($fileName in $orderedFileNames) {
            $localFile = Join-Path $BackupDirectory $fileName
            $blobName = "$BlobPrefix/$fileName"
            $contentMd5 = Get-FileContentMd5 -Path $localFile
            $expectedLength = (Get-Item -LiteralPath $localFile).Length

            $uploadArguments = @(
                'storage', 'blob', 'upload',
                '--blob-endpoint', $sas.BlobEndpoint,
                '--container-name', $sas.ContainerName,
                '--name', $blobName,
                '--file', $localFile,
                '--blob-type', 'BlockBlob',
                '--overwrite', 'false',
                '--if-none-match', '*',
                '--validate-content',
                '--content-md5', $contentMd5,
                '--only-show-errors',
                '--output', 'none'
            )
            Invoke-AzStorage -Arguments $uploadArguments -OriginalUri $ContainerSasUri `
                -SasToken $sas.SasToken | Out-Null

            $showArguments = @(
                'storage', 'blob', 'show',
                '--blob-endpoint', $sas.BlobEndpoint,
                '--container-name', $sas.ContainerName,
                '--name', $blobName,
                '--query', '{length:properties.contentLength,md5:properties.contentSettings.contentMd5}',
                '--only-show-errors',
                '--output', 'json'
            )
            $propertiesJson = Invoke-AzStorage -Arguments $showArguments -OriginalUri $ContainerSasUri `
                -SasToken $sas.SasToken
            $properties = ($propertiesJson -join [Environment]::NewLine) | ConvertFrom-Json
            if ([long] $properties.length -ne $expectedLength -or [string] $properties.md5 -ne $contentMd5) {
                throw "Blob verification failed for $($sas.ContainerUri)/$blobName."
            }

            Write-Ok "Uploaded and verified $blobName."
        }

        return $sas.ContainerUri
    }
    catch {
        $safeMessage = Protect-SasText -Text $_.Exception.Message -OriginalUri $ContainerSasUri `
            -SasToken $sas.SasToken
        throw "Blob upload failed for incomplete prefix $($sas.ContainerUri)/$BlobPrefix. $safeMessage"
    }
    finally {
        [Environment]::SetEnvironmentVariable('AZURE_STORAGE_SAS_TOKEN', $previousSasToken, 'Process')
    }
}

$tunnel = $null
$tunnelListenerProcessId = $null
$sshSession = $null
$outputLog = $null
$errorLog = $null
$remoteDirectory = $null
$remoteCreated = $false
$localBackupDirectory = $null
$temporaryBackupDirectory = $null
$destinationVerified = $false
$blobPrefix = $null
$accessRestrictions = $null
$temporaryScmRuleName = $null
$restoreScmBasicAuthDisabled = $false

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

                $candidateRuleName = "wpbackup-temp-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
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

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff')
    $remoteDirectory = "/home/backups/$stamp"
    $backupName = "$AppName-$stamp"
    if ($Destination -eq 'Local') {
        $localBackupDirectory = Join-Path $LocalPath $backupName
    }
    else {
        $temporaryBackupDirectory = Join-Path ([IO.Path]::GetTempPath()) "wordpress-backup-$([guid]::NewGuid().ToString('N'))"
        $localBackupDirectory = $temporaryBackupDirectory
        $blobPrefix = $backupName
    }
    $excludedTables = @($ExcludeTables | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $excludeOption = if ($excludedTables.Count -gt 0) { "--exclude_tables=$($excludedTables -join ',')" } else { '' }
    $fileArchiveStep = if ($DatabaseOnly) {
        'printf "database-only backup; files archive omitted\\n"'
    }
    else {
        @'
for attempt in 1 2 3; do
    if tar -czf "$backup_dir/files.tar.gz" \
        --exclude='wp-content/cache' \
        --exclude='wp-content/cache/**' \
        --exclude='wp-content/upgrade' \
        --exclude='wp-content/upgrade/**' \
        --exclude='*.log' \
        wp-content wp-config.php; then
        break
    else
        tar_status=$?
        rm -f "$backup_dir/files.tar.gz"
        if [ "$tar_status" -ne 1 ] || [ "$attempt" -eq 3 ]; then
            exit "$tar_status"
        fi
        printf 'Files changed during archive attempt %s; retrying...\n' "$attempt" >&2
        sleep 2
    fi
done
'@
    }

    $remoteScript = @'
set -euo pipefail
umask 077
backup_dir=__REMOTE_DIRECTORY__
mkdir -p "$backup_dir"
cd /home/site/wwwroot

wp db check --allow-root --skip-plugins --skip-themes > /dev/null
wp db export "$backup_dir/db.sql" --allow-root --add-drop-table --single-transaction --quick __EXCLUDE_OPTION__
gzip -9 "$backup_dir/db.sql"

__FILE_ARCHIVE_STEP__

{
  printf 'app=%s\n' __APP_NAME__
  printf 'timestamp_utc=%s\n' __STAMP__
  printf 'wp_version=%s\n' "$(wp core version --allow-root)"
  printf 'php_version=%s\n' "$(php -r 'echo PHP_VERSION;')"
  printf 'siteurl=%s\n' "$(wp option get siteurl --allow-root)"
  printf 'home=%s\n' "$(wp option get home --allow-root)"
  printf 'db_size=%s\n' "$(wp db size --size_format=mb --allow-root)"
} > "$backup_dir/manifest.txt"

wp plugin list --format=csv --allow-root > "$backup_dir/plugins.csv"
wp theme list --format=csv --allow-root > "$backup_dir/themes.csv"

cd "$backup_dir"
sha256sum db.sql.gz manifest.txt plugins.csv themes.csv__FILES_ARCHIVE_SUM__ > SHA256SUMS
'@
    $remoteScript = $remoteScript.Replace('__REMOTE_DIRECTORY__', (ConvertTo-BashLiteral $remoteDirectory))
    $remoteScript = $remoteScript.Replace('__EXCLUDE_OPTION__', $excludeOption)
    $remoteScript = $remoteScript.Replace('__FILE_ARCHIVE_STEP__', $fileArchiveStep.Trim())
    $remoteScript = $remoteScript.Replace('__APP_NAME__', (ConvertTo-BashLiteral $AppName))
    $remoteScript = $remoteScript.Replace('__STAMP__', (ConvertTo-BashLiteral $stamp))
    $remoteScript = $remoteScript.Replace('__FILES_ARCHIVE_SUM__', $(if ($DatabaseOnly) { '' } else { ' files.tar.gz' }))

    Write-Step "Creating remote backup artifacts in $remoteDirectory"
    Invoke-RemoteScript -SessionId $sshSession.SessionId -Script $remoteScript -TimeoutSeconds $CommandTimeoutSeconds | Out-Null
    $remoteCreated = $true
    Write-Ok 'Remote database, inventory, manifest, and checksum artifacts created.'

    $artifactNames = @('db.sql.gz', 'manifest.txt', 'plugins.csv', 'themes.csv', 'SHA256SUMS')
    if (-not $DatabaseOnly) {
        $artifactNames += 'files.tar.gz'
    }

    New-Item -ItemType Directory -Path $localBackupDirectory -Force | Out-Null
    Write-Step "Downloading backup to $localBackupDirectory"
    Remove-SSHSession -SessionId $sshSession.SessionId -ErrorAction SilentlyContinue | Out-Null
    $sshSession = $null
    Get-RemoteFiles -FileNames $artifactNames -RemoteDirectory $remoteDirectory `
        -DestinationDirectory $localBackupDirectory -Credential $credential -TunnelPort $Port `
        -TimeoutSeconds $TransferTimeoutSeconds

    Write-Step 'Validating local SHA256 checksums'
    Assert-LocalChecksums -BackupDirectory $localBackupDirectory -ExpectedFileNames $artifactNames

    $totalBytes = (Get-ChildItem -LiteralPath $localBackupDirectory -File | Measure-Object -Property Length -Sum).Sum
    if ($Destination -eq 'Blob') {
        $safeContainer = (ConvertFrom-BlobContainerSasUri -BlobSasUri $BlobSasUri).ContainerUri
        Write-Step "Uploading backup to $safeContainer/$blobPrefix"
        $null = Send-BackupToBlob -BackupDirectory $localBackupDirectory -FileNames $artifactNames `
            -BlobPrefix $blobPrefix -ContainerSasUri $BlobSasUri
        Write-Ok "Backup completed: $safeContainer/$blobPrefix ($totalBytes bytes)."
    }
    else {
        Write-Ok "Backup completed: $localBackupDirectory ($totalBytes bytes)."
    }
    $destinationVerified = $true

    [pscustomobject]@{
        Destination = $Destination
        BackupPath = $(if ($Destination -eq 'Local') { $localBackupDirectory } else { $null })
        BlobPrefix = $blobPrefix
        RemotePath = $remoteDirectory
        DatabaseOnly = [bool] $DatabaseOnly
        ChecksumVerified = $true
        AccessRestrictions = $accessRestrictions
    }
}
finally {
    if ($temporaryBackupDirectory) {
        Remove-Item -LiteralPath $temporaryBackupDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($remoteCreated -and $destinationVerified -and -not $KeepRemote) {
        try {
            if (-not $sshSession) {
                $sshSession = New-SSHSession -ComputerName '127.0.0.1' -Port $Port -Credential $credential `
                    -AcceptKey -Force -ConnectionTimeout $TunnelTimeoutSeconds
            }
            Write-Step "Cleaning remote staging directory $remoteDirectory"
            Invoke-RemoteCommand -SessionId $sshSession.SessionId -Script "rm -rf -- $(ConvertTo-BashLiteral $remoteDirectory)" `
                -TimeoutSeconds $CommandTimeoutSeconds | Out-Null
            Write-Ok 'Remote staging directory removed.'
        }
        catch {
            Write-WarningMessage "Could not remove remote staging directory: $($_.Exception.Message)"
        }
    }
    elseif ($remoteCreated) {
        Write-WarningMessage "Remote staging directory retained: $remoteDirectory"
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
            Remove-TemporaryScmAllowRule -ResourceGroup $ResourceGroup -AppName $AppName -Slot $Slot `
                -RuleName $temporaryScmRuleName
            Write-Ok 'Temporary SCM allow rule removed.'
        }
        catch {
            Write-WarningMessage "Could not remove temporary SCM allow rule $temporaryScmRuleName. Remove it manually. $($_.Exception.Message)"
        }
    }

    if ($restoreScmBasicAuthDisabled -and $accessRestrictions -and $accessRestrictions.AppId) {
        try {
            Write-Step 'Restoring SCM basic authentication publishing to disabled'
            Set-ScmBasicAuthPolicy -AppId $accessRestrictions.AppId -Allow $false
            Write-Ok 'SCM basic authentication publishing disabled again.'
        }
        catch {
            Write-WarningMessage "Could not restore SCM basic authentication publishing to disabled. Disable it manually. $($_.Exception.Message)"
        }
    }
}