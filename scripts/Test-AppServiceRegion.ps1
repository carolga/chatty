[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('eastus', 'eastus2', 'centralus', 'southcentralus', 'westus', 'westus2', 'westus3')]
    [string]$Location,
    [ValidateSet('P0v3', 'B1')]
    [string]$Sku = 'P0v3',
    [string]$SubscriptionId = '00000000-0000-0000-0000-000000000001',
    [string]$ResourceGroup = 'rg-chatty-westus3-demo'
)

$ErrorActionPreference = 'Stop'
$subscription = $SubscriptionId
$azPython = Join-Path (Split-Path (Split-Path (Get-Command az).Source -Parent) -Parent) 'python.exe'
$tokenResult = & $azPython -IBm azure.cli account get-access-token --subscription $subscription --resource 'https://management.azure.com/' --output json --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Unable to authenticate to ARM.' }
$token = ($tokenResult -join "`n" | ConvertFrom-Json).accessToken
try {
    $template = @{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
        contentVersion = '1.0.0.0'
        resources = @(@{
            type = 'Microsoft.Web/serverfarms'
            apiVersion = '2024-11-01'
            name = "asp-chatty-probe-$Location"
            location = $Location
            kind = 'linux'
            sku = @{ name = $Sku; tier = $(if ($Sku -eq 'B1') { 'Basic' } else { 'PremiumV3' }); capacity = 1 }
            properties = @{ reserved = $true }
        })
    }
    $body = @{ properties = @{ mode = 'Incremental'; template = $template } } | ConvertTo-Json -Depth 20
    $uri = "https://management.azure.com/subscriptions/$subscription/resourcegroups/$ResourceGroup/providers/Microsoft.Resources/deployments/probe-$Location-$Sku/validate?api-version=2025-04-01"
    $response = Invoke-WebRequest -Method Post -Uri $uri -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json' -Body $body -SkipHttpErrorCheck
    if ($response.StatusCode -eq 202) {
        $pollUri = [string]$response.Headers['Azure-AsyncOperation'][0]
        if (!$pollUri) { $pollUri = [string]$response.Headers.Location[0] }
        if (!$pollUri) { throw 'Validation returned no polling URI.' }
        $deadline = [DateTime]::UtcNow.AddMinutes(5)
        do {
            Start-Sleep -Seconds 10
            $result = Invoke-RestMethod -Uri $pollUri -Headers @{ Authorization = "Bearer $token" }
            if ([DateTime]::UtcNow -gt $deadline) { throw 'Regional validation timed out.' }
        } while ($result.status -in @('Running', 'Accepted'))
    } else {
        $result = $response.Content | ConvertFrom-Json
    }
    if ($result.error) {
        [pscustomobject]@{ SubscriptionId = $subscription; Location = $Location; Sku = $Sku; Validated = $false; Error = $result.error } | ConvertTo-Json -Depth 20
    } elseif ($response.StatusCode -notin @(200, 202)) {
        throw "Unexpected ARM validation status: $($response.StatusCode)"
    } elseif ($result.status -and $result.status -ne 'Succeeded') {
        throw "Unexpected ARM validation state: $($result.status)"
    } else {
        [pscustomobject]@{ SubscriptionId = $subscription; Location = $Location; Sku = $Sku; Validated = $true; Note = 'Read-only ARM preflight; not a capacity reservation or a deployed plan.' } | ConvertTo-Json
    }
} finally {
    $token = $null
    $tokenResult = $null
}
