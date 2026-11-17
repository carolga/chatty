param([switch]$Resume, [switch]$Inspect, [switch]$RetryFailedEvaluator)

$ErrorActionPreference = 'Stop'
if ($Inspect -and $RetryFailedEvaluator) { throw 'Inspection cannot submit a retry.' }
$subscription = '00000000-0000-0000-0000-000000000001'
$group = 'rg-chatty-westus3-demo'
$root = Split-Path $PSScriptRoot -Parent
$az = Join-Path (Split-Path (Split-Path (Get-Command az).Source -Parent) -Parent) 'python.exe'
function Invoke-AzJson([string[]]$Arguments) {
    $output = & $az -IBm azure.cli @Arguments --subscription $subscription --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: $($Arguments[0..1] -join ' ')" }
    ($output -join "`n") | ConvertFrom-Json
}
$deployment = Get-Content -Raw (Join-Path $root 'artifacts\deployment.json') | ConvertFrom-Json
if ($deployment.subscriptionId -ne $subscription -or $deployment.region -ne 'westus3' -or
    $deployment.agentName -ne 'chatty' -or $deployment.agentVersion -ne '1') {
    throw 'The verified deployment does not match the approved evaluation target.'
}
$recordPath = Join-Path $root 'artifacts\evaluation-generation.json'
$previous = if (Test-Path -LiteralPath $recordPath) { Get-Content -Raw -LiteralPath $recordPath | ConvertFrom-Json } else { $null }
if ((Test-Path -LiteralPath $recordPath) -and !$Inspect -and !$RetryFailedEvaluator) {
    throw 'Evaluation generation is already recorded; do not submit duplicates.'
}
if ($RetryFailedEvaluator) {
    if (@($previous.jobs | Where-Object { $_.type -eq 'evaluator' -and $_.status -eq 'failed' }).Count -ne 1) {
        throw 'Retry requires one verified failed evaluator job.'
    }
}
$scope = "/subscriptions/$subscription/resourceGroups/$group/providers/Microsoft.CognitiveServices/accounts/chatty-ai-demo0001/projects/chatty"
$vm = Invoke-AzJson @('vm', 'show', '--resource-group', $group, '--name', 'vm-chatty-jump')
$role = '53ca6127-db72-4b80-b1b0-d745d6d5456d'
$prior = @(Invoke-AzJson @('role', 'assignment', 'list', '--scope', $scope,
    '--query', "[?principalId=='$($vm.identity.principalId)' && ends_with(roleDefinitionId, '$role')]"))
if ($prior.Count -ne 0) { throw 'A prior jump-box grant exists; review it instead of adopting it.' }
$assignment = Invoke-AzJson @('role', 'assignment', 'create', '--assignee-object-id', $vm.identity.principalId,
    '--assignee-principal-type', 'ServicePrincipal', '--role', $role, '--scope', $scope)
try {
    Start-Sleep -Seconds 60
    $scriptName = if ($Resume -or $Inspect -or $RetryFailedEvaluator) { 'Resume-EvaluationsFromJumpBox.ps1' } else { 'Generate-EvaluationsFromJumpBox.ps1' }
    $script = Join-Path $PSScriptRoot $scriptName
    $arguments = @('vm', 'run-command', 'invoke', '--resource-group', $group, '--name', $vm.name,
        '--command-id', 'RunPowerShellScript', '--scripts', "@$script")
    if ($Inspect) { $arguments += @('--parameters', 'InspectOnly=true') }
    if ($RetryFailedEvaluator) { $arguments += @('--parameters', 'RetryFailedEvaluator=true') }
    $result = Invoke-AzJson $arguments
    $messages = $result.value.message -join "`n"
    $messages | Set-Content (Join-Path $root 'artifacts\evaluation-generation-result.txt')
    Write-Output $messages
    if ($messages -notmatch 'CHATTY_EVAL_GENERATION_SUBMITTED' -or $messages -notmatch 'CHATTY_EVAL_JOBS=(.+)') {
        throw 'Evaluation generation did not return both job references; inspect the saved private result.'
    }
    $jobs = $Matches[1] | ConvertFrom-Json
    $status = if (@($jobs | Where-Object status -Match '^(failed|canceled|cancelled)$').Count -ne 0) { 'failed' }
        elseif (@($jobs | Where-Object status -Match '^(completed|succeeded)$').Count -eq 2) { 'generated' }
        else { 'submitted' }
    $previousJobs = @($previous.previousJobs | Where-Object { $null -ne $_ })
    if ($RetryFailedEvaluator) { $previousJobs += @($previous.jobs) }
    [ordered]@{
        projectEndpoint = $deployment.projectEndpoint
        agentName = $deployment.agentName
        agentVersion = $deployment.agentVersion
        generationSource = 'synthetic'
        generationModel = 'gpt-5-mini'
        requestedSamples = 15
        status = $status
        jobs = $jobs
        previousJobs = $previousJobs
    } | ConvertTo-Json -Depth 10 | Set-Content $recordPath
} finally {
    & $az -IBm azure.cli role assignment delete --ids $assignment.id --subscription $subscription --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Temporary evaluation grant removal failed: $($assignment.id)" }
}
