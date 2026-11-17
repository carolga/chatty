[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$subscription = '00000000-0000-0000-0000-000000000001'
$group = 'rg-chatty-westus3-demo'
$root = Split-Path $PSScriptRoot -Parent
$azPython = Join-Path (Split-Path (Split-Path (Get-Command az).Source -Parent) -Parent) 'python.exe'
function Invoke-AzJson([string[]]$Arguments) {
    $result = & $azPython -IBm azure.cli @Arguments --subscription $subscription --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: $($Arguments[0..1] -join ' ')" }
    ($result -join "`n") | ConvertFrom-Json
}
$rg = Invoke-AzJson @('group', 'show', '--name', $group)
if ($rg.location -ne 'westus3' -or $rg.tags.workload -ne 'chatty') { throw 'Unexpected deployment scope.' }
$base = "$($rg.id)/providers/Microsoft.CognitiveServices/accounts"
$project = Invoke-AzJson @('resource', 'show', '--ids', "$base/chatty-ai-demo0001/projects/chatty", '--api-version', '2025-04-01-preview')
$language = Invoke-AzJson @('resource', 'show', '--ids', "$base/chatty-language-demo0001", '--api-version', '2025-06-01')
$web = Invoke-AzJson @('webapp', 'show', '--name', 'chatty-web-demo0001', '--resource-group', $group)
$vm = Invoke-AzJson @('vm', 'show', '--name', 'vm-chatty-jump', '--resource-group', $group)
if ($web.location.Replace(' ', '') -ine 'westus3') { throw 'Unexpected web region.' }
$entra = Get-Content -Raw (Join-Path $root 'artifacts\entra.json') | ConvertFrom-Json
if ($entra.tenantId -ne '00000000-0000-0000-0000-000000000002') { throw 'Unexpected app tenant.' }

$sourceZip = Join-Path $root 'artifacts\deployment-source.zip'
$zip = [IO.Compression.ZipArchive]::new([IO.File]::Create($sourceZip), [IO.Compression.ZipArchiveMode]::Create)
try {
    $files = @(
        Get-Item (Join-Path $root 'Directory.Build.props'), (Join-Path $root 'NuGet.config')
        Get-ChildItem (Join-Path $root 'src\Chatty.Web'), (Join-Path $root 'scripts\Smoke') -Recurse -File |
            Where-Object FullName -NotMatch '\\(bin|obj)\\'
    )
    foreach ($file in $files) {
        $relative = [IO.Path]::GetRelativePath($root, $file.FullName).Replace('\', '/')
        $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $relative, [IO.Compression.CompressionLevel]::Optimal)
    }
} finally {
    $zip.Dispose()
}
$projectEndpoint = 'https://chatty-ai-demo0001.services.ai.azure.com/api/projects/chatty'
$languageEndpoint = 'https://chatty-language-demo0001.cognitiveservices.azure.com/'
$remote = (Get-Content -Raw (Join-Path $PSScriptRoot 'Deploy-FromJumpBox.ps1')).
    Replace('CHATTY_SOURCE_ARCHIVE', [Convert]::ToBase64String([IO.File]::ReadAllBytes($sourceZip))).
    Replace('CHATTY_PROJECT_ENDPOINT', $projectEndpoint).
    Replace('CHATTY_LANGUAGE_ENDPOINT', $languageEndpoint).
    Replace('CHATTY_CLIENT_ID', $entra.clientId)
$scriptPath = Join-Path $root 'artifacts\run-private-deployment.ps1'
$remote | Set-Content $scriptPath

$temporary = [Collections.Generic.List[object]]::new()
try {
    foreach ($grant in @(
        @{ Scope = $project.id; Role = '53ca6127-db72-4b80-b1b0-d745d6d5456d' }
        @{ Scope = $language.id; Role = '7628b7b8-a8b2-4cdc-b46f-e9b35248918e' }
        @{ Scope = $web.id; Role = 'de139f84-1756-47ae-9be6-808fbbe84772' }
    )) {
        $prior = @(Invoke-AzJson @('role', 'assignment', 'list', '--scope', $grant.Scope,
            '--query', "[?principalId=='$($vm.identity.principalId)' && ends_with(roleDefinitionId, '$($grant.Role)')]"))
        if ($prior.Count -ne 0) { throw 'Unexpected pre-existing jump-box deployment grant; review before changing it.' }
        $assignment = Invoke-AzJson @('role', 'assignment', 'create', '--assignee-object-id', $vm.identity.principalId,
            '--assignee-principal-type', 'ServicePrincipal', '--role', $grant.Role, '--scope', $grant.Scope)
        $temporary.Add($assignment)
    }
    Start-Sleep -Seconds 60
    $result = Invoke-AzJson @('vm', 'run-command', 'invoke', '--resource-group', $group, '--name', $vm.name,
        '--command-id', 'RunPowerShellScript', '--scripts', "@$scriptPath")
    $messages = ($result.value.message -join "`n")
    $messages | Set-Content (Join-Path $root 'artifacts\private-deployment-result.txt')
    Write-Output $messages
    if ($messages -notmatch 'CHATTY_DEPLOYMENT_SUCCEEDED') { throw 'Private deployment did not report success; inspect the saved result and jump-box logs.' }
    if ($messages -notmatch 'CHATTY_AGENT_VERSION=(\d+)') { throw 'Successful deployment did not report its pinned version.' }
    $guardedVersion = $Matches[1]
    if ($messages -notmatch 'CHATTY_BASELINE_AGENT_VERSION=(\d+)') { throw 'Successful deployment did not report its baseline pinned version.' }
    @{ subscriptionId = $subscription; resourceGroup = $group; region = 'westus3'; agentName = 'chatty'; agentVersion = $guardedVersion; baselineAgentName = 'chatty-no-pii'; baselineAgentVersion = $Matches[1]; webUrl = "https://$($web.defaultHostName)"; projectEndpoint = $projectEndpoint } |
        ConvertTo-Json | Set-Content (Join-Path $root 'artifacts\deployment.json')
} finally {
    $cleanupFailures = [Collections.Generic.List[string]]::new()
    foreach ($assignment in $temporary) {
        & $azPython -IBm azure.cli role assignment delete --ids $assignment.id --subscription $subscription --only-show-errors
        if ($LASTEXITCODE -ne 0) { $cleanupFailures.Add($assignment.id) }
    }
    if ($cleanupFailures.Count -ne 0) { throw "Temporary grant removal failed: $($cleanupFailures -join ', ')" }
}
