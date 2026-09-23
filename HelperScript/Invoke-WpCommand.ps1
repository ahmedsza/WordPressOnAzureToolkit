<#
.SYNOPSIS
    Opens an SSH tunnel to an Azure Linux App Service and runs WP-CLI commands over it.

.DESCRIPTION
    Implements the flow documented at
    https://learn.microsoft.com/en-us/azure/app-service/configure-linux-open-ssh-session

    1. Starts `az webapp create-remote-connection` as a background process.
    2. Waits for the local TCP tunnel port to accept connections.
    3. Authenticates over SSH as root / "Docker!" (the fixed credentials baked into
       the App Service Linux base images).
    4. Executes one or more WP-CLI commands in /home/site/wwwroot and returns output.
    5. Tears the tunnel down.

.NOTES
    Requires: PowerShell 7+, Azure CLI (logged in), Posh-SSH module.
    Install-Module Posh-SSH -Scope CurrentUser

.EXAMPLE
    ./Invoke-WpCommand.ps1 -ResourceGroup rg-wp -AppName my-wp-site -Command 'wp plugin list'

.EXAMPLE
    ./Invoke-WpCommand.ps1 -ResourceGroup rg-wp -AppName my-wp-site -Command @(
        'wp core version',
        'wp db size --tables',
        'wp option get siteurl'
    )

.EXAMPLE
    ./Invoke-WpCommand.ps1 -ResourceGroup rg-wp -AppName my-wp-site -Interactive
#>

[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $AppName,
    [string] $Slot,
    [string] $SubscriptionId,

    [Parameter(ParameterSetName = 'Run')]
    [string[]] $Command,

    # Drop into a live shell instead of running commands
    [Parameter(ParameterSetName = 'Shell')]
    [switch] $Interactive,

    [int] $Port = 2222,
    [string] $WorkingDirectory = '/home/site/wwwroot',
    [int] $TunnelTimeoutSeconds = 60,
    [int] $CommandTimeoutSeconds = 3600,
    [string[]] $SensitiveValue
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# App Service Linux containers ship with these fixed SSH credentials.
# They are only reachable through the authenticated Azure tunnel, never publicly.
$ContainerUser = 'root'
$ContainerPass = 'Docker!'

function Write-Step { param($m) Write-Host "`n▶ $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "  ✓ $m"  -ForegroundColor Green }

function ConvertTo-BashLiteral {
    param([AllowEmptyString()][string] $Value)

    return "'" + $Value.Replace("'", "'`"'`"'") + "'"
}

function New-LoginShellCommand {
    param([string] $Command)

    $directory = ConvertTo-BashLiteral $WorkingDirectory
    $loginCommand = ConvertTo-BashLiteral $Command
    return "cd -- $directory && bash -lc $loginCommand"
}

function Protect-CommandDisplay {
    param([string] $Value)

    foreach ($secret in $SensitiveValue) {
        if ($secret) { $Value = $Value.Replace($secret, '[REDACTED]') }
    }
    return $Value
}

#region --- prerequisites ---

Write-Step 'Checking prerequisites'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7+ required (found $($PSVersionTable.PSVersion))."
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI not found. Install: https://aka.ms/installazurecli'
}
if (-not (az account show 2>$null)) {
    throw 'Not signed in. Run: az login'
}

if (-not $Interactive) {
    if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
        Write-Host '  Installing Posh-SSH...' -ForegroundColor Yellow
        Install-Module Posh-SSH -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module Posh-SSH -ErrorAction Stop
}

Write-Ok 'Prerequisites OK'

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId
    Write-Ok "Subscription: $SubscriptionId"
}

#endregion

#region --- find a free local port ---

function Test-PortFree {
    param([int]$P)
    try {
        $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $P)
        $l.Start(); $l.Stop(); return $true
    } catch { return $false }
}

while (-not (Test-PortFree $Port)) {
    Write-Host "  Port $Port in use, trying $($Port + 1)" -ForegroundColor Yellow
    $Port++
}

#endregion

#region --- start the tunnel ---

Write-Step "Opening remote connection tunnel on localhost:$Port"

$azArgs = @(
    'webapp', 'create-remote-connection',
    '--resource-group', $ResourceGroup,
    '--name', $AppName,
    '--port', $Port
)
if ($Slot) { $azArgs += @('--slot', $Slot) }

$outLog = [System.IO.Path]::GetTempFileName()
$errLog = [System.IO.Path]::GetTempFileName()

# Resolve the Azure CLI command file so Start-Process preserves its full path.
$azExe = (Get-Command az).Source
$tunnel = Start-Process -FilePath $azExe -ArgumentList $azArgs `
                        -NoNewWindow -PassThru `
                        -RedirectStandardOutput $outLog -RedirectStandardError $errLog

function Stop-Tunnel {
    if ($tunnel -and -not $tunnel.HasExited) {
        Write-Step 'Closing tunnel'
        Stop-Process -Id $tunnel.Id -Force -ErrorAction SilentlyContinue
        Write-Ok 'Tunnel closed'
    }
    Remove-Item $outLog, $errLog -ErrorAction SilentlyContinue
}

try {
    # Wait for the tunnel to start listening
    $deadline = (Get-Date).AddSeconds($TunnelTimeoutSeconds)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        if ($tunnel.HasExited) {
            $err = (Get-Content $errLog -Raw), (Get-Content $outLog -Raw) -join "`n"
            throw "Tunnel process exited early:`n$err"
        }
        try {
            $c = [System.Net.Sockets.TcpClient]::new()
            $c.Connect('127.0.0.1', $Port)
            $c.Close()
            $ready = $true
            break
        } catch {
            Start-Sleep -Milliseconds 750
        }
    }
    if (-not $ready) { throw "Tunnel did not become ready within $TunnelTimeoutSeconds seconds." }

    Start-Sleep -Seconds 2   # let the SSH daemon settle behind the tunnel
    Write-Ok "Tunnel ready on 127.0.0.1:$Port"

    #endregion

    #region --- interactive mode ---

    if ($Interactive) {
        Write-Host ''
        Write-Host '  Connecting with your system ssh client.' -ForegroundColor Cyan
        Write-Host "  Password when prompted: $ContainerPass" -ForegroundColor Yellow
        Write-Host ''
        ssh "$ContainerUser@127.0.0.1" -p $Port `
            -o StrictHostKeyChecking=no `
            -o UserKnownHostsFile=/dev/null `
            -o LogLevel=ERROR
        return
    }

    #endregion

    #region --- scripted mode ---

    Write-Step 'Authenticating to the container'

    $secure = ConvertTo-SecureString $ContainerPass -AsPlainText -Force
    $cred   = [pscredential]::new($ContainerUser, $secure)

    $session = New-SSHSession -ComputerName '127.0.0.1' -Port $Port `
                              -Credential $cred -AcceptKey -Force `
                              -ConnectionTimeout 30
    Write-Ok "SSH session $($session.SessionId) established"

    try {
        # Confirm WP-CLI is present before doing anything else
        $probe = Invoke-SSHCommand -SessionId $session.SessionId `
                    -Command (New-LoginShellCommand 'wp core version --allow-root') `
                    -TimeOut 60
        if ($probe.ExitStatus -ne 0) {
            throw "WP-CLI unavailable in $WorkingDirectory`n$($probe.Error -join "`n")"
        }
        Write-Ok "WordPress $($probe.Output -join '')"

        if (-not $Command) {
            Write-Host "`n  No -Command supplied. Use -Interactive for a shell." -ForegroundColor Yellow
            return
        }

        $results = foreach ($c in $Command) {
            # Ensure --allow-root, since the container runs as root
            $full = if ($c -match '^\s*wp\b' -and $c -notmatch '--allow-root') {
                "$c --allow-root"
            } else { $c }

            $displayCommand = Protect-CommandDisplay $full
            Write-Step $displayCommand

            $r = Invoke-SSHCommand -SessionId $session.SessionId `
            -Command (New-LoginShellCommand $full) `
                    -TimeOut $CommandTimeoutSeconds

            if ($r.Output)          { $r.Output | ForEach-Object { Write-Host "    $_" } }
            if ($r.ExitStatus -ne 0) {
                Write-Host "    exit $($r.ExitStatus)" -ForegroundColor Red
                $r.Error | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
            }

            [pscustomobject]@{
                Command  = $displayCommand
                ExitCode = $r.ExitStatus
                Output   = ($r.Output -join "`n")
                Error    = ($r.Error  -join "`n")
                Success  = ($r.ExitStatus -eq 0)
            }
        }

        Write-Host ''
        $results | Format-Table Command, ExitCode, Success -AutoSize | Out-Host
        return $results
    }
    finally {
        Remove-SSHSession -SessionId $session.SessionId -ErrorAction SilentlyContinue | Out-Null
    }

    #endregion
}
finally {
    Stop-Tunnel
}