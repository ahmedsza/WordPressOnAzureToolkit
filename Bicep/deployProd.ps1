$ErrorActionPreference = 'Stop'
$resourceGroupName = 'ahms-wg-prod-rg'
$parameterFileName = 'wordpress-deployment-arm-template.prod.parameters.json'
$bicepMain = 'wordpress-deployment-arm-template.bicep'
$bicepParamsFile = $parameterFileName
$deploymentName = "wordpress-$(Get-Date -Format 'yyyyMMddHHmmss')"
$location = 'southafricanorth'

$deploymentParameters = "@$bicepParamsFile"

az group create `
    --name $resourceGroupName `
    --location $location




az deployment group create `
    --resource-group $resourceGroupName `
    --name $deploymentName `
    --template-file $bicepMain `
    --parameters $deploymentParameters

Write-Host 'Resource group creation and deployment completed.'

$keyVaultName = az deployment group show `
    --resource-group $resourceGroupName `
    --name $deploymentName `
    --query properties.outputs.keyVaultNameOutput.value `
    --output tsv


az group delete  --name $resourceGroupName --yes

# The vault name is now stable, so the soft-deleted vault must be purged before the next run.
if ($keyVaultName) {
    az keyvault purge --name $keyVaultName --location $location
}