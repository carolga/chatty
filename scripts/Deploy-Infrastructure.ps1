[CmdletBinding()]
param(
    [Parameter(Mandatory)][Guid]$SubscriptionId,
    [Parameter(Mandatory)][Guid]$TenantId,
    [string]$ResourceGroup = 'rg-chatty-westus3-demo',
    [string]$Location = 'westus3',
    [ValidateSet('P0v3', 'B1')]
    [string]$AppServiceSku = 'P0v3',
    [switch]$ResumeEmptyResourceGroup
)

$ErrorActionPreference = 'Stop'
if ($SubscriptionId -eq '00000000-0000-0000-0000-000000000001' -or
    $TenantId -eq '00000000-0000-0000-0000-000000000002') {
    throw 'Configure the public sample with your approved subscription, tenant, and resource names before deploying. See README.md.'
}
$root = Split-Path $PSScriptRoot -Parent
$null = New-Item -ItemType Directory -Path (Join-Path $root 'artifacts') -Force
$azPython = Join-Path (Split-Path (Split-Path (Get-Command az).Source -Parent) -Parent) 'python.exe'
function Invoke-AzJson([string[]]$Arguments) {
    $result = & $azPython -IBm azure.cli @Arguments --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: $($Arguments[0..1] -join ' ')" }
    return ($result -join "`n") | ConvertFrom-Json
}

$account = Invoke-AzJson @('account', 'show', '--subscription', $SubscriptionId)
if ($account.tenantId -ne $TenantId) { throw 'Unexpected deployment tenant.' }
$graphToken = (Invoke-AzJson @('account', 'get-access-token', '--subscription', $SubscriptionId, '--resource', 'https://graph.microsoft.com/')).accessToken
try {
    $identity = Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/me?$select=id,userType' -Headers @{ Authorization = "Bearer $graphToken" }
} finally {
    $graphToken = $null
}
if ($identity.userType -ne 'Member') { throw 'Deployment requires an approved member user in the target tenant.' }
$exists = Invoke-AzJson @('group', 'exists', '--name', $ResourceGroup, '--subscription', $SubscriptionId)
if ($exists) {
    $group = Invoke-AzJson @('group', 'show', '--name', $ResourceGroup, '--subscription', $SubscriptionId)
    $resources = @(Invoke-AzJson @('resource', 'list', '--resource-group', $ResourceGroup, '--subscription', $SubscriptionId))
    if (!$ResumeEmptyResourceGroup -or $group.tags.workload -ne 'chatty' -or $resources.Count -ne 0) {
        throw 'Resource group is not an explicitly approved empty Chatty group. Inspect before recovery; do not blindly retry capability-host creation.'
    }
}

$scope = "/subscriptions/$SubscriptionId" + $(if ($exists) { "/resourceGroups/$ResourceGroup" } else { '' })
$roles = @(Invoke-AzJson @('role', 'assignment', 'list', '--assignee', $identity.id,
    '--scope', $scope, '--include-inherited', '--include-groups', '--subscription', $SubscriptionId))
if (!($roles | Where-Object roleDefinitionName -in @('Owner', 'User Access Administrator', 'Role Based Access Control Administrator'))) {
    throw "Required role-assignment authority is not verified at $scope. Contributor plus Foundry Project Manager cannot grant Language Reader or VM Login. Activate an approved RBAC administrator role, or have an administrator perform the reviewed role assignments."
}

& $azPython -IBm azure.cli bicep build --file (Join-Path $root 'infra\main.bicep') --outfile (Join-Path $root 'artifacts\infra.json') --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Bicep compilation failed.' }
$null = Invoke-AzJson @('group', 'create', '--name', $ResourceGroup, '--location', $Location, '--subscription', $SubscriptionId, '--tags', 'workload=chatty', 'environment=poc', 'securitycontrol=ignore', 'costcontrol=ignore')
$token = (Invoke-AzJson @('account', 'get-access-token', '--subscription', $SubscriptionId, '--resource', 'https://management.azure.com/')).accessToken
try {
    $headers = @{ Authorization = "Bearer $token" }
    $password = 'Ch!8' + [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(36))
    $properties = @{
        mode = 'Incremental'
        template = Get-Content -Raw (Join-Path $root 'artifacts\infra.json') | ConvertFrom-Json -AsHashtable
        parameters = @{
            initialUserObjectId = @{ value = $identity.id }
            jumpAdminPassword = @{ value = $password }
            appServiceSku = @{ value = $AppServiceSku }
            location = @{ value = $Location }
        }
    }
    $body = @{ properties = $properties } | ConvertTo-Json -Depth 100 -Compress
    $deploymentUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourcegroups/$ResourceGroup/providers/Microsoft.Resources/deployments/chatty-private"
    $validation = Invoke-RestMethod -Uri "$deploymentUri/validate?api-version=2025-04-01" -Method Post -Headers $headers -ContentType 'application/json' -Body $body
    if ($validation.error) { throw ($validation.error | ConvertTo-Json -Depth 20) }
    $whatIf = Invoke-WebRequest -Uri "$deploymentUri/whatIf?api-version=2025-04-01" -Method Post -Headers $headers -ContentType 'application/json' -Body $body
    if ($whatIf.StatusCode -eq 202) {
        $pollUri = [string]$whatIf.Headers.Location[0]
        if (!$pollUri) { throw 'ARM did not return a what-if polling URI.' }
        $deadline = [DateTime]::UtcNow.AddMinutes(10)
        do {
            Start-Sleep -Seconds 10
            $preview = Invoke-RestMethod -Uri $pollUri -Headers $headers
            if ([DateTime]::UtcNow -gt $deadline) { throw 'What-if timed out; no infrastructure deployment was started.' }
        } while ($preview.status -in @('Running', 'Accepted'))
    } else {
        $preview = $whatIf.Content | ConvertFrom-Json
    }
    if ($preview.status -ne 'Succeeded') { throw ($preview | ConvertTo-Json -Depth 30) }
    if ($preview.error) { throw ($preview.error | ConvertTo-Json -Depth 20) }
    if ($null -eq $preview.properties.changes) { throw 'ARM returned no what-if change list; provisioning was not submitted.' }
    $preview | ConvertTo-Json -Depth 60 | Set-Content (Join-Path $root 'artifacts\what-if.json')
    $preview.properties.changes | Select-Object changeType, resourceId | Format-Table -AutoSize
    if (@($preview.properties.changes | Where-Object changeType -in @('Delete', 'Modify')).Count -ne 0) {
        throw 'Unexpected changes to existing resources; inspect the what-if before proceeding.'
    }
    $null = Invoke-RestMethod -Uri "$deploymentUri`?api-version=2025-04-01" -Method Put -Headers $headers -ContentType 'application/json' -Body $body
    Write-Output "Infrastructure deployment submitted: $ResourceGroup / chatty-private"
    Write-Output 'The generated local VM password was discarded; use Entra sign-in through Bastion.'
} finally {
    $token = $null
    $headers = $null
    $password = $null
    $body = $null
    $properties = $null
}
