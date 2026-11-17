[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$subscription = '00000000-0000-0000-0000-000000000001'
$resourceGroup = 'rg-chatty-westus3-demo'
$scope = "/subscriptions/$subscription/resourceGroups/$resourceGroup"
$required = @{ securitycontrol = 'ignore'; costcontrol = 'ignore' }
$root = Split-Path $PSScriptRoot -Parent
$azPython = Join-Path (Split-Path (Split-Path (Get-Command az).Source -Parent) -Parent) 'python.exe'

function Invoke-AzJson([string[]]$Arguments) {
    $result = & $azPython -IBm azure.cli @Arguments --subscription $subscription --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Azure operation failed: $($Arguments[0..1] -join ' ')" }
    ($result -join "`n") | ConvertFrom-Json
}

function Get-Inventory {
    $group = Invoke-AzJson @('group', 'show', '--name', $resourceGroup)
    if ($group.id -ine $scope -or $group.location -ne 'westus3' -or $group.tags.workload -ne 'chatty') {
        throw 'Unexpected Chatty tagging scope.'
    }
    $group
    Invoke-AzJson @('resource', 'list', '--resource-group', $resourceGroup)
}

function Get-TagMap($Tags) {
    $map = @{}
    if ($null -ne $Tags) {
        foreach ($property in $Tags.PSObject.Properties) { $map[$property.Name] = $property.Value }
    }
    $map
}

$before = @{}
$updated = 0
foreach ($resource in @(Get-Inventory)) {
    if ($resource.id -ine $scope -and
        !$resource.id.StartsWith("$scope/providers/", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Resource inventory escaped the approved Chatty group.'
    }
    $tags = Get-TagMap $resource.tags
    $before[$resource.id] = $tags
    if ($tags['securitycontrol'] -cne 'ignore' -or $tags['costcontrol'] -cne 'ignore') {
        $null = Invoke-AzJson @('tag', 'update', '--resource-id', $resource.id,
            '--operation', 'Merge', '--tags', 'securitycontrol=ignore', 'costcontrol=ignore')
        $updated++
    }
}

$results = [Collections.Generic.List[object]]::new()
$failures = [Collections.Generic.List[string]]::new()
foreach ($resource in @(Get-Inventory)) {
    $tags = Get-TagMap $resource.tags
    if ($tags['securitycontrol'] -cne 'ignore' -or $tags['costcontrol'] -cne 'ignore') {
        $stored = Invoke-AzJson @('tag', 'list', '--resource-id', $resource.id)
        $tags = Get-TagMap $stored.properties.tags
    }
    $verified = $tags['securitycontrol'] -ceq 'ignore' -and $tags['costcontrol'] -ceq 'ignore'
    if ($before.ContainsKey($resource.id)) {
        foreach ($key in $before[$resource.id].Keys) {
            if (!$required.ContainsKey($key) -and $tags[$key] -cne $before[$resource.id][$key]) {
                $verified = $false
            }
        }
    }
    if (!$verified) { $failures.Add($resource.id) }
    $results.Add([pscustomobject]@{ id = $resource.id; tags = $tags; verified = $verified })
}
$evidence = [ordered]@{
    verifiedAtUtc = [DateTime]::UtcNow.ToString('O')
    scope = $scope
    requiredTags = $required
    updated = $updated
    checked = $results.Count
    failures = $failures.ToArray()
    resources = $results.ToArray()
}
$evidence | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $root 'artifacts\tags-verification.json')
if ($failures.Count -ne 0) { throw "Chatty tag verification failed for: $($failures -join ', ')" }
Write-Output "Verified both requested tags on $($results.Count) targets, including the resource group; updated $updated. Existing unrelated tags preserved."
