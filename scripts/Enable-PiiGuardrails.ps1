[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$subscription = '00000000-0000-0000-0000-000000000001'
$group = 'rg-chatty-westus3-demo'
$root = Split-Path $PSScriptRoot -Parent
$azPython = Join-Path (Split-Path (Split-Path (Get-Command az).Source -Parent) -Parent) 'python.exe'
$accountId = "/subscriptions/$subscription/resourceGroups/$group/providers/Microsoft.CognitiveServices/accounts/chatty-ai-demo0001"
$policyUrl = "https://management.azure.com$accountId/raiPolicies/ChattyStrict?api-version=2026-03-01"

function Invoke-AzJson([string[]]$Arguments) {
    $result = & $azPython -IBm azure.cli @Arguments --subscription $subscription --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        @{
            checkedAtUtc = [DateTime]::UtcNow.ToString('O')
            policyId = "$accountId/raiPolicies/ChattyStrict"
            status = 'not_verified'
            runtimeBehaviorVerified = $false
            message = 'Azure operation failed. Inspect CLI error; do not claim PII guardrails are enabled.'
        } | ConvertTo-Json | Set-Content (Join-Path $root 'artifacts\pii-guardrails-verification.json')
        throw "Azure operation failed: $($Arguments[0..1] -join ' ')"
    }
    ($result -join "`n") | ConvertFrom-Json
}

$catalog = Invoke-AzJson @('rest', '--method', 'get', '--url',
    "https://management.azure.com/subscriptions/$subscription/providers/Microsoft.CognitiveServices/locations/westus3/raiContentFilters?api-version=2025-06-01")
$names = @(Get-Content -Raw (Join-Path $root 'infra\pii-filter-names.json') | ConvertFrom-Json)
foreach ($name in $names) {
    # Policies use properties.name (for example, "Name Protection"), not the catalog resource ID.
    if ($name -cnotin $catalog.value.properties.name) { throw "Required regional PII filter is unavailable: $name" }
}
$deployment = Invoke-AzJson @('rest', '--method', 'get', '--url',
    "https://management.azure.com$accountId/deployments/gpt-5-mini?api-version=2025-06-01")
if ($deployment.properties.raiPolicyName -ne 'ChattyStrict') { throw 'Unexpected active model guardrail.' }
$original = Invoke-AzJson @('rest', '--method', 'get', '--url', $policyUrl)
$original | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $root 'artifacts\pii-guardrails-before.json')
$tags = @{ workload = 'chatty'; environment = 'poc'; securitycontrol = 'ignore'; costcontrol = 'ignore' }
if ($null -ne $original.tags) {
    foreach ($tag in $original.tags.PSObject.Properties) {
        if (!$tags.ContainsKey($tag.Name)) { $tags[$tag.Name] = $tag.Value }
    }
}
$properties = $original.properties | ConvertTo-Json -Depth 30 | ConvertFrom-Json
$filters = @($properties.contentFilters | Where-Object { $_.name -cnotin $names -or $_.source -ne 'Completion' })
foreach ($filter in $filters) {
    if ($filter.action -eq 'NONE') { $filter.PSObject.Properties.Remove('action') }
}
$filters += @($names | ForEach-Object {
    $filter = @{ name = $_; source = 'Completion'; enabled = $true; blocking = ($_ -cne 'Name Protection') }
    if ($_ -ceq 'Name Protection') { $filter.action = 'ANNOTATING' }
    $filter
})
$properties.contentFilters = $filters
$properties.mode = 'Blocking'
$path = Join-Path $root 'artifacts\pii-guardrails-request.json'
@{ properties = $properties; tags = $tags } |
    ConvertTo-Json -Depth 30 | Set-Content $path
$null = Invoke-AzJson @('rest', '--method', 'put', '--url', $policyUrl, '--body', "@$path")
$actual = Invoke-AzJson @('rest', '--method', 'get', '--url', $policyUrl)
$deployment = Invoke-AzJson @('rest', '--method', 'get', '--url',
    "https://management.azure.com$accountId/deployments/gpt-5-mini?api-version=2025-06-01")
if ($deployment.properties.raiPolicyName -ne 'ChattyStrict') { throw 'Active model guardrail changed during the update.' }
if ($actual.properties.mode -ne 'Blocking') { throw 'The PII guardrail is not in blocking mode.' }
foreach ($name in $names) {
    $filter = @($actual.properties.contentFilters | Where-Object { $_.name -ceq $name -and $_.source -eq 'Completion' })
    if ($filter.Count -ne 1 -or !$filter[0].enabled -or $filter[0].blocking -ne ($name -cne 'Name Protection')) {
        throw "PII guardrail readback failed: $name"
    }
    if ($name -ceq 'Name Protection' -and $filter[0].action -ine 'ANNOTATING') {
        throw 'Name Protection must explicitly annotate without blocking.'
    }
}
foreach ($expected in $original.properties.contentFilters | Where-Object { $_.name -cnotin $names }) {
    $found = @($actual.properties.contentFilters | Where-Object { $_.name -eq $expected.name -and $_.source -eq $expected.source })
    if ($found.Count -ne 1 -or $found[0].enabled -ne $expected.enabled -or
        $found[0].blocking -ne $expected.blocking -or $found[0].severityThreshold -ne $expected.severityThreshold) {
        throw "An existing safety control changed: $($expected.name)"
    }
}
@{
    checkedAtUtc = [DateTime]::UtcNow.ToString('O')
    policyId = $actual.id
    modelDeploymentId = $deployment.id
    policyName = $actual.name
    status = 'configured'
    mode = $actual.properties.mode
    piiCompletionControls = $names.Count
    piiBlockingControls = $names.Count - 1
    piiDetectOnlyControls = @('Name Protection')
    contentFilters = $actual.properties.contentFilters
    runtimeBehaviorVerified = $false
} | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $root 'artifacts\pii-guardrails-verification.json')
Write-Output "Verified 45 blocking PII completion controls and detect-only Name Protection on ChattyStrict. Existing harm/prompt-attack controls preserved. Runtime verification is separate."
