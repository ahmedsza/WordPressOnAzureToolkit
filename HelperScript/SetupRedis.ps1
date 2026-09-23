<#
.SYNOPSIS
    Points the W3 Total Cache plugin at an Azure Cache for Redis instance.

.DESCRIPTION
    Looks up the Redis hostname and primary access key via Azure CLI, then runs WP-CLI
    commands over the same SSH tunnel used by Invoke-WpCommand.ps1 to install/activate
    W3 Total Cache and configure its Page, Database, and Object cache modules to use
    that Redis Enterprise instance over TLS (port 10000), matching the setup described at
    https://techcommunity.microsoft.com/blog/appsonazureblog/distributed-caching-with-azure-redis-to-boost-your-wordpress-sites-performance/3974605

.EXAMPLE
    ./setupredis.ps1 -ResourceGroup rg-wp -AppName my-wp-site -RedisName my-redis-cache
#>

param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $AppName,
    [Parameter(Mandatory)] [string] $RedisName,
    [string] $RedisResourceGroup,
    [string] $Slot,
    [string] $SubscriptionId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step { param([string] $Message) Write-Host "`n$Message" -ForegroundColor Cyan }
function Write-Ok { param([string] $Message) Write-Host "  $Message" -ForegroundColor Green }

function ConvertTo-BashLiteral {
    param([string] $Value)
    return "'" + $Value.Replace("'", "'`"'`"'") + "'"
}

if (-not $RedisResourceGroup) { $RedisResourceGroup = $ResourceGroup }

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI not found. Install: https://aka.ms/installazurecli'
}
if ($SubscriptionId) {
    az account set --subscription $SubscriptionId
}

Write-Step "Looking up Azure Cache for Redis '$RedisName'"
$redisInfo = az redisenterprise show --name $RedisName --resource-group $RedisResourceGroup -o json 2>$null | ConvertFrom-Json
if (-not $redisInfo) {
    throw "Could not find Redis cache '$RedisName' in resource group '$RedisResourceGroup'."
}

$redisKeys =  az redisenterprise database  list-keys  --cluster-name $RedisName --resource-group $RedisResourceGroup -o json 2>$null | ConvertFrom-Json
if (-not $redisKeys -or -not $redisKeys.primaryKey) {
    throw "Could not retrieve access keys for '$RedisName'."
}

$redisDatabase = $redisInfo.databases | Where-Object { $_.name -eq 'default' } | Select-Object -First 1
if (-not $redisDatabase -or -not $redisDatabase.port) {
    throw "Could not determine the port for the default database on '$RedisName'."
}

$redisPort = $redisDatabase.port
$serverAddress = "tls://$($redisInfo.hostName):$redisPort"
Write-Ok "Host: $($redisInfo.hostName):$redisPort (TLS)"

$serverLiteral = ConvertTo-BashLiteral $serverAddress
$keyLiteral = ConvertTo-BashLiteral $redisKeys.primaryKey

$commands = [System.Collections.Generic.List[string]]::new()
$commands.Add('wp plugin is-installed w3-total-cache --allow-root || wp plugin install w3-total-cache --allow-root')
$commands.Add('wp plugin activate w3-total-cache --allow-root')

foreach ($module in @('pgcache', 'dbcache', 'objectcache')) {
    $commands.Add("wp w3-total-cache option set $module.engine redis --allow-root")
    $commands.Add("wp w3-total-cache option set $module.redis.servers $serverLiteral --type=array --allow-root")
    $commands.Add("wp w3-total-cache option set $module.redis.password $keyLiteral --allow-root")
    $commands.Add("wp w3-total-cache option set $module.redis.dbid 0 --type=integer --allow-root")
    $commands.Add("wp w3-total-cache option set $module.redis.persistent true --type=boolean --allow-root")
    $commands.Add("wp w3-total-cache option set $module.redis.verify_tls_certificates true --type=boolean --allow-root")
    $commands.Add("wp w3-total-cache option set $module.enabled true --type=boolean --allow-root")
}

$commands.Add('wp w3-total-cache fix_environment nginx --allow-root')
$commands.Add('wp w3-total-cache flush all --allow-root')

$invokeScript = Join-Path $PSScriptRoot 'Invoke-WpCommand.ps1'
if (-not (Test-Path $invokeScript)) {
    throw "Cannot find Invoke-WpCommand.ps1 next to this script."
}

$invokeParams = @{
    ResourceGroup = $ResourceGroup
    AppName       = $AppName
    Command       = $commands.ToArray()
    SensitiveValue = $redisKeys.primaryKey
}
if ($Slot) { $invokeParams.Slot = $Slot }
if ($SubscriptionId) { $invokeParams.SubscriptionId = $SubscriptionId }

Write-Step 'Configuring W3 Total Cache over the App Service SSH tunnel'
$results = & $invokeScript @invokeParams

$failed = $results | Where-Object { -not $_.Success }
if ($failed) {
    throw "$($failed.Count) WP-CLI command(s) failed. Review the output above."
}

Write-Ok 'W3 Total Cache is now using Redis for Page, Database, and Object cache.'
