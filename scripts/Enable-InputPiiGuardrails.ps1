[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$source = 'Prompt'
$subscription = '00000000-0000-0000-0000-000000000001'
$root = Split-Path $PSScriptRoot -Parent
$azPython = Join-Path (Split-Path (Split-Path (Get-Command az).Source -Parent) -Parent) 'python.exe'
$accountId = "/subscriptions/$subscription/resourceGroups/rg-chatty-westus3-demo/providers/Microsoft.CognitiveServices/accounts/chatty-ai-demo0001"
$base = "https://management.azure.com$accountId"
$api = '2026-09-01'
$policyUrl = "$base/raiPolicies/ChattyStrict?api-version=$api"
$prefix = Join-Path $root "artifacts\input-pii-$Source"

function Invoke-AzJson([string[]]$Arguments) {
    $result = & $azPython -IBm azure.cli @Arguments --subscription $subscription --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Azure operation failed: $($Arguments[0..1] -join ' ')" }
    ($result -join "`n") | ConvertFrom-Json
}
function Filter-Keys($Policy) {
    @($Policy.properties.contentFilters | ForEach-Object {
        $action = if ($_.action -ieq 'NONE') { '' } else { $_.action }
        "$($_.name)|$($_.source)|$($_.enabled)|$($_.blocking)|$($_.severityThreshold)|$action"
    } | Sort-Object)
}

$account = Invoke-AzJson @('rest', '--method', 'get', '--url', "${base}?api-version=$api")
if ($account.location -ne 'westus3' -or $account.properties.publicNetworkAccess -ne 'Disabled') {
    throw 'Input PII setup must stay in the approved private West US 3 account.'
}
foreach ($binding in @(
    @{ Model = 'gpt-5-mini'; Policy = 'ChattyStrict' }
    @{ Model = 'gpt-5-mini-no-pii'; Policy = 'ChattyWithoutPii' }
)) {
    $model = Invoke-AzJson @('rest', '--method', 'get', '--url', "$base/deployments/$($binding.Model)?api-version=$api")
    if ($model.properties.raiPolicyName -ne $binding.Policy) { throw 'Unexpected model policy binding.' }
}
$original = Invoke-AzJson @('rest', '--method', 'get', '--url', $policyUrl)
$baselineUrl = "$base/raiPolicies/ChattyWithoutPii?api-version=$api"
$baseline = Invoke-AzJson @('rest', '--method', 'get', '--url', $baselineUrl)
$names = @(Get-Content -Raw (Join-Path $root 'infra\pii-filter-names.json') | ConvertFrom-Json)
$existingInputs = @($original.properties.contentFilters | Where-Object { $_.name -cin $names -and $_.source -ne 'Completion' })
if ($existingInputs.Count) {
    if ($existingInputs.Count -eq $names.Count -and
        @($existingInputs.name | Select-Object -Unique).Count -eq $names.Count -and
        @($existingInputs | Where-Object { $_.source -ne 'Prompt' -or !$_.enabled -or !$_.blocking -or $_.action -ine 'BLOCKING' }).Count -eq 0) {
        Write-Output 'All 46 Prompt PII controls are already configured; no policy was changed. Runtime verification is separate.'
        return
    }
    throw 'PII input controls already exist; review them rather than overwrite them.'
}
$backup = "$prefix-before-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff')).json"
$original | ConvertTo-Json -Depth 40 | Set-Content $backup
$properties = $original.properties | ConvertTo-Json -Depth 40 | ConvertFrom-Json
foreach ($filter in $properties.contentFilters) {
    if ($filter.action -ieq 'NONE') { $filter.PSObject.Properties.Remove('action') }
}
$properties.contentFilters += @($names | ForEach-Object {
    @{ name = $_; source = $Source; enabled = $true; blocking = $true; action = 'BLOCKING' }
})
$body = @{ properties = $properties }
if ($null -ne $original.tags) { $body.tags = $original.tags }
$body | ConvertTo-Json -Depth 40 | Set-Content "$prefix-request.json"
$headers = @{ 'If-Match' = $original.etag } | ConvertTo-Json -Compress
$output = & $azPython -IBm azure.cli rest --method put --url $policyUrl --headers $headers `
    --body "@$prefix-request.json" --subscription $subscription --output json --only-show-errors 2>&1
$accepted = $LASTEXITCODE -eq 0
if (!$accepted) { $output | Set-Content "$prefix-error.txt" }
$actual = Invoke-AzJson @('rest', '--method', 'get', '--url', $policyUrl)
$baselineAfter = Invoke-AzJson @('rest', '--method', 'get', '--url', $baselineUrl)
$baselineUnchanged = @(Compare-Object (Filter-Keys $baseline) (Filter-Keys $baselineAfter)).Count -eq 0 -and
    $baseline.etag -ceq $baselineAfter.etag
if (!$baselineUnchanged) { throw 'The baseline policy changed during the input-control attempt.' }
$originalKeys = Filter-Keys $original
$actualKeys = Filter-Keys $actual
$originalPreserved = @($originalKeys | Where-Object { $_ -cnotin $actualKeys }).Count -eq 0 -and
    $actual.properties.mode -ceq $original.properties.mode -and
    $actual.properties.basePolicyName -ceq $original.properties.basePolicyName
$inputs = @($actual.properties.contentFilters | Where-Object { $_.name -cin $names -and $_.source -eq $Source })
$verified = $accepted -and $originalPreserved -and $inputs.Count -eq $names.Count -and
    @($inputs | Where-Object { !$_.enabled -or !$_.blocking -or $_.action -ine 'BLOCKING' }).Count -eq 0
@{
    checkedAtUtc = [DateTime]::UtcNow.ToString('O')
    source = $Source
    requestAccepted = $accepted
    inputControlsVerified = $verified
    inputControlCount = $inputs.Count
    existingControlsPreserved = $originalPreserved
    guardedPolicyUnchanged = $original.etag -ceq $actual.etag
    baselineUnchanged = $baselineUnchanged
    beforeFile = $backup
    runtimeBehaviorVerified = $false
} | ConvertTo-Json | Set-Content "$prefix-verification.json"
if (!$accepted) {
    Write-Output ($output -join "`n")
    if ($original.etag -cne $actual.etag) { throw 'Rejected request changed the guarded policy; inspect the saved snapshot immediately.' }
    throw "Azure rejected PII input source $Source. Guarded and baseline policies are unchanged."
}
if (!$verified) { throw 'Azure accepted the request but input-control readback is not verified. Do not claim input blocking works.' }
Write-Output "Configured $($inputs.Count) PII controls at $Source; existing output and baseline controls preserved. Runtime verification is still required."
