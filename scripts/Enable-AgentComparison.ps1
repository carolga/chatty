[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$subscription = '00000000-0000-0000-0000-000000000001'
$group = 'rg-chatty-westus3-demo'
$root = Split-Path $PSScriptRoot -Parent
$azPython = Join-Path (Split-Path (Split-Path (Get-Command az).Source -Parent) -Parent) 'python.exe'
$accountId = "/subscriptions/$subscription/resourceGroups/$group/providers/Microsoft.CognitiveServices/accounts/chatty-ai-demo0001"
$baseUrl = "https://management.azure.com$accountId"

function Invoke-AzJson([string[]]$Arguments) {
    $result = & $azPython -IBm azure.cli @Arguments --subscription $subscription --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Azure operation failed: $($Arguments[0..1] -join ' ')" }
    ($result -join "`n") | ConvertFrom-Json
}
function Filter-Key($Filter) {
    "$($Filter.name)|$($Filter.source)|$($Filter.enabled)|$($Filter.blocking)|$($Filter.severityThreshold)|$($Filter.action)"
}

$account = Invoke-AzJson @('rest', '--method', 'get', '--url', "${baseUrl}?api-version=2025-06-01")
if ($account.location -ne 'westus3' -or $account.properties.publicNetworkAccess -ne 'Disabled') {
    throw 'Comparison must stay in the approved private West US 3 account.'
}
$guarded = Invoke-AzJson @('rest', '--method', 'get', '--url', "$baseUrl/deployments/gpt-5-mini?api-version=2025-06-01")
if ($guarded.properties.raiPolicyName -ne 'ChattyStrict' -or $guarded.sku.capacity -ne 10 -or
    $guarded.sku.name -ne 'DataZoneStandard' -or $guarded.properties.model.version -ne '2025-08-07') {
    throw 'Guarded deployment differs from the approved comparison setup.'
}
$policy = Invoke-AzJson @('rest', '--method', 'get', '--url', "$baseUrl/raiPolicies/ChattyStrict?api-version=2026-03-01")
$piiNames = @(Get-Content -Raw (Join-Path $root 'infra\pii-filter-names.json') | ConvertFrom-Json)
$properties = $policy.properties | ConvertTo-Json -Depth 30 | ConvertFrom-Json
$properties.contentFilters = @($properties.contentFilters | Where-Object { $_.name -cnotin $piiNames })
if ($properties.contentFilters.Count -ne 9) { throw 'Expected exactly the original nine non-PII safety controls.' }
$originalKeys = @($policy.properties.contentFilters | ForEach-Object { Filter-Key $_ } | Sort-Object)
foreach ($filter in $properties.contentFilters) {
    if ($filter.action -eq 'NONE') { $filter.PSObject.Properties.Remove('action') }
}
$tags = @{ workload = 'chatty'; environment = 'poc'; securitycontrol = 'ignore'; costcontrol = 'ignore' }
$policyPath = Join-Path $root 'artifacts\comparison-policy-request.json'
@{ properties = $properties; tags = $tags } | ConvertTo-Json -Depth 30 | Set-Content $policyPath
$null = Invoke-AzJson @('rest', '--method', 'put', '--url',
    "$baseUrl/raiPolicies/ChattyWithoutPii?api-version=2026-03-01", '--body', "@$policyPath")
$baselinePolicy = Invoke-AzJson @('rest', '--method', 'get', '--url',
    "$baseUrl/raiPolicies/ChattyWithoutPii?api-version=2026-03-01")
$expected = @($policy.properties.contentFilters | Where-Object { $_.name -cnotin $piiNames } | ForEach-Object { Filter-Key $_ } | Sort-Object)
$actual = @($baselinePolicy.properties.contentFilters | ForEach-Object { Filter-Key $_ } | Sort-Object)
if (@(Compare-Object $expected $actual).Count -ne 0 -or
    $baselinePolicy.properties.mode -ne $policy.properties.mode -or
    $baselinePolicy.properties.basePolicyName -ne $policy.properties.basePolicyName) {
    throw 'Comparison safety policy readback did not match all non-PII controls.'
}

$deployments = Invoke-AzJson @('rest', '--method', 'get', '--url', "$baseUrl/deployments?api-version=2025-06-01")
$baseline = @($deployments.value | Where-Object name -eq 'gpt-5-mini-no-pii')
if (!$baseline.Count) {
    $capacities = Invoke-AzJson @('rest', '--method', 'get', '--url',
        "https://management.azure.com/subscriptions/$subscription/providers/Microsoft.CognitiveServices/locations/westus3/modelCapacities?api-version=2024-10-01&modelFormat=OpenAI&modelName=gpt-5-mini&modelVersion=2025-08-07")
    $capacity = @($capacities.value | Where-Object { $_.properties.skuName -eq $guarded.sku.name })
    if (!$capacity.Count -or ($capacity.properties.availableCapacity | Measure-Object -Maximum).Maximum -lt 10) {
        throw 'Same-region comparison capacity is unavailable; no region or SKU fallback is allowed.'
    }
    $modelPath = Join-Path $root 'artifacts\comparison-model-request.json'
    @{
        sku = $guarded.sku
        tags = $tags
        properties = @{
            model = $guarded.properties.model
            raiPolicyName = 'ChattyWithoutPii'
            versionUpgradeOption = $guarded.properties.versionUpgradeOption
        }
    } | ConvertTo-Json -Depth 20 | Set-Content $modelPath
    $null = Invoke-AzJson @('rest', '--method', 'put', '--url',
        "$baseUrl/deployments/gpt-5-mini-no-pii?api-version=2025-06-01", '--body', "@$modelPath")
}
$deadline = [DateTime]::UtcNow.AddMinutes(5)
do {
    $baseline = Invoke-AzJson @('rest', '--method', 'get', '--url',
        "$baseUrl/deployments/gpt-5-mini-no-pii?api-version=2025-06-01")
    if ($baseline.properties.provisioningState -eq 'Succeeded') { break }
    if ($baseline.properties.provisioningState -in @('Failed', 'Canceled') -or [DateTime]::UtcNow -gt $deadline) {
        throw 'Comparison model deployment did not become ready.'
    }
    Start-Sleep -Seconds 10
} while ($true)
if ($baseline.properties.raiPolicyName -ne 'ChattyWithoutPii' -or
    $baseline.sku.name -ne $guarded.sku.name -or $baseline.sku.capacity -ne $guarded.sku.capacity -or
    $baseline.properties.versionUpgradeOption -ne $guarded.properties.versionUpgradeOption -or
    $baseline.properties.model.format -ne $guarded.properties.model.format -or
    $baseline.properties.model.name -ne $guarded.properties.model.name -or
    $baseline.properties.model.version -ne $guarded.properties.model.version) {
    throw 'Comparison model settings differ from the guarded model.'
}
$unchanged = Invoke-AzJson @('rest', '--method', 'get', '--url', "$baseUrl/raiPolicies/ChattyStrict?api-version=2026-03-01")
if (@(Compare-Object $originalKeys @($unchanged.properties.contentFilters | ForEach-Object { Filter-Key $_ } | Sort-Object)).Count) {
    throw 'Guarded policy changed during comparison setup.'
}
@{
    checkedAtUtc = [DateTime]::UtcNow.ToString('O')
    guardedPolicy = 'ChattyStrict'
    baselinePolicy = 'ChattyWithoutPii'
    baselineDeployment = $baseline.id
    identicalNonPiiControls = $true
    nonPiiControlCount = $actual.Count
    baselinePiiControls = 0
    runtimeBehaviorVerified = $false
} | ConvertTo-Json | Set-Content (Join-Path $root 'artifacts\comparison-verification.json')
Write-Output 'Comparison configured: identical model/version/SKU/capacity; nine non-PII controls preserved; zero custom PII controls on baseline. Runtime verification is separate.'
