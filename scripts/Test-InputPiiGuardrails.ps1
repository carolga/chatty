[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$subscription = '00000000-0000-0000-0000-000000000001'
$group = 'rg-chatty-westus3-demo'
$root = Split-Path $PSScriptRoot -Parent
$azPython = Join-Path (Split-Path (Split-Path (Get-Command az).Source -Parent) -Parent) 'python.exe'
$accountId = "/subscriptions/$subscription/resourceGroups/$group/providers/Microsoft.CognitiveServices/accounts/chatty-ai-demo0001"
$principalId = '00000000-0000-0000-0000-000000000005'
$deployment = Get-Content -Raw (Join-Path $root 'artifacts\deployment.json') | ConvertFrom-Json
if ($deployment.agentVersion -ne '1' -or $deployment.baselineAgentVersion -ne '1') {
    throw 'Review the explicitly pinned agent versions before running this bounded probe.'
}
function Invoke-AzJson([string[]]$Arguments) {
    $result = & $azPython -IBm azure.cli @Arguments --subscription $subscription --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Azure operation failed: $($Arguments[0..1] -join ' ')" }
    ($result -join "`n") | ConvertFrom-Json
}

$remote = {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $endpoint = 'https://chatty-ai-demo0001.services.ai.azure.com/api/projects/chatty'
    $addresses = [Net.Dns]::GetHostAddresses(([Uri]$endpoint).Host)
    if (!$addresses.Count -or @($addresses | Where-Object { !$_.ToString().StartsWith('10.243.1.') }).Count) {
        throw 'Foundry private DNS validation failed.'
    }
    $token = $null
    try {
        $token = (Invoke-RestMethod -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fai.azure.com' -Headers @{ Metadata = 'true' } -TimeoutSec 30).access_token
        $headers = @{ Authorization = "Bearer $token" }
        $results = @()
        $reference = 'Synthetic reference [S1]: Income documentation review checks whether submitted evidence covers the requested period and whether inconsistent amounts need human review. This is a fictional example, not real lending guidance.'
        $question = 'Explain the synthetic income documentation review.'
        foreach ($case in @(
            @{ name = 'guarded_clean'; agent = 'chatty'; question = $question }
            @{ name = 'guarded_email_input'; agent = 'chatty'; question = "$question My email is input-guardrail@example.com. Do not repeat my email." }
            @{ name = 'baseline_email_input'; agent = 'chatty-no-pii'; question = "$question My email is input-guardrail@example.com. Do not repeat my email." }
            @{ name = 'guarded_masked_input'; agent = 'chatty'; question = "$question My email is ***************************. Do not repeat my email." }
        )) {
            $body = @{
                agent_reference = @{ type = 'agent_reference'; name = $case.agent; version = '1' }
                input = @(
                    @{ role = 'user'; content = $reference }
                    @{ role = 'user'; content = $case.question }
                )
                store = $false
                stream = $false
                tools = @()
                tool_choice = 'none'
                max_output_tokens = 4096
            } | ConvertTo-Json -Depth 10
            $status = 200
            try {
                $response = Invoke-RestMethod -Uri "$endpoint/openai/v1/responses" -Method Post -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 120
            } catch [Net.WebException] {
                if ($null -eq $_.Exception.Response) { throw 'Private input guardrail probe failed before an HTTP response.' }
                $status = [int]$_.Exception.Response.StatusCode
                $errorBody = $_.ErrorDetails.Message
                if ([string]::IsNullOrWhiteSpace($errorBody)) {
                    $reader = [IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
                    try { $errorBody = $reader.ReadToEnd() } finally { $reader.Dispose() }
                }
                try { $response = $errorBody | ConvertFrom-Json }
                catch { throw 'Private input guardrail error response was not valid JSON.' }
            }
            $filters = @($response.content_filters) + @($response.error.content_filters)
            $promptFilters = @($filters | Where-Object { $_.source_type -in @('prompt', 'input', 'pre_run', 'prerun', 'user_input') })
            $pii = @($promptFilters | ForEach-Object { $_.content_filter_results.personally_identifiable_information })
            $pii += @($response.error.innererror.content_filter_result.personally_identifiable_information)
            $pii += @($response.error.innererror.content_filter_results.personally_identifiable_information)
            $inputDetected = @($pii | Where-Object detected).Count -gt 0
            $inputFiltered = @($pii | Where-Object filtered).Count -gt 0
            $textPresent = @($response.output | Where-Object type -eq 'message' | ForEach-Object {
                $_.content | Where-Object { $_.type -eq 'output_text' -and ![string]::IsNullOrWhiteSpace($_.text) }
            }).Count -gt 0
            $results += [pscustomobject]@{
                case = $case.name
                httpStatus = $status
                completed = $response.status -eq 'completed'
                inputPiiDetected = $inputDetected
                inputPiiFiltered = $inputFiltered
                inputBlocked = @($promptFilters | Where-Object blocked).Count -gt 0 -or
                    ($status -eq 400 -and $response.error.code -eq 'content_filter' -and $inputFiltered)
                outputPresent = $textPresent
                outputBlocked = @($filters | Where-Object { $_.source_type -eq 'completion' -and $_.blocked }).Count -gt 0
                contentFilterError = $response.error.code -in @('content_filter', 'content_policy_violation')
            }
        }
        Write-Output ('CHATTY_INPUT_PII_RUNTIME=' + (ConvertTo-Json -InputObject $results -Depth 8 -Compress))
        $work = Join-Path $env:ProgramData 'ChattyDeployment'
        $source = Get-ChildItem -LiteralPath $work -Directory -Filter 'source-*' |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        if ($null -eq $source) { throw 'No previously published private smoke harness was found.' }
        $smoke = Join-Path $source.FullName 'scripts\Smoke\bin\Release\net10.0\Smoke.dll'
        if (!(Test-Path -LiteralPath $smoke)) { throw 'The latest private smoke harness is unavailable.' }
        & (Join-Path $work 'dotnet\dotnet.exe') $smoke (Join-Path $source.FullName 'src\Chatty.Web') `
            'https://chatty-language-demo0001.cognitiveservices.azure.com/' $endpoint '1' '1'
        if ($LASTEXITCODE -ne 0) { throw 'Application redaction/comparison smoke failed with input guardrails configured.' }
        Write-Output 'CHATTY_INPUT_PII_APP_SMOKE=passed'
    } finally {
        $token = $null
        $headers = $null
    }
}.ToString()
$remotePath = Join-Path $root 'artifacts\test-input-pii-private.ps1'
$remote | Set-Content $remotePath
$temporary = [Collections.Generic.List[object]]::new()
try {
    foreach ($grant in @(
        @{ Scope = "$accountId/projects/chatty"; Role = '53ca6127-db72-4b80-b1b0-d745d6d5456d' }
        @{ Scope = "/subscriptions/$subscription/resourceGroups/$group/providers/Microsoft.CognitiveServices/accounts/chatty-language-demo0001"; Role = '7628b7b8-a8b2-4cdc-b46f-e9b35248918e' }
    )) {
        $prior = @(Invoke-AzJson @('role', 'assignment', 'list', '--scope', $grant.Scope,
            '--query', "[?principalId=='$principalId' && ends_with(roleDefinitionId, '$($grant.Role)')]"))
        if ($prior.Count) { throw 'Unexpected pre-existing jump-box test grant; review before changing it.' }
        $temporary.Add((Invoke-AzJson @('role', 'assignment', 'create', '--assignee-object-id', $principalId,
            '--assignee-principal-type', 'ServicePrincipal', '--role', $grant.Role, '--scope', $grant.Scope)))
    }
    Start-Sleep -Seconds 60
    $result = Invoke-AzJson @('vm', 'run-command', 'invoke', '--resource-group', $group, '--name', 'vm-chatty-jump',
        '--command-id', 'RunPowerShellScript', '--scripts', "@$remotePath")
    $messages = $result.value.message -join "`n"
    $messages | Set-Content (Join-Path $root 'artifacts\input-pii-runtime-result.txt')
    Write-Output $messages
    if ($messages -notmatch 'CHATTY_INPUT_PII_RUNTIME=(\[[^\r\n]*\])') {
        throw 'Private input guardrail checks did not return results.'
    }
    $checks = $Matches[1] | ConvertFrom-Json
    $raw = @($checks | Where-Object case -eq 'guarded_email_input')
    $clean = @($checks | Where-Object case -eq 'guarded_clean')
    $baseline = @($checks | Where-Object case -eq 'baseline_email_input')
    $masked = @($checks | Where-Object case -eq 'guarded_masked_input')
    $verified = $checks.Count -eq 4 -and $raw.Count -eq 1 -and $raw[0].inputPiiDetected -and
        $raw[0].inputBlocked -and !$raw[0].outputPresent -and
        $clean.Count -eq 1 -and $clean[0].completed -and $clean[0].outputPresent -and
        $baseline.Count -eq 1 -and $baseline[0].completed -and $baseline[0].outputPresent -and
        $masked.Count -eq 1 -and $masked[0].completed -and $masked[0].outputPresent -and
        $messages -match 'CHATTY_INPUT_PII_APP_SMOKE=passed'
    @{
        checkedAtUtc = [DateTime]::UtcNow.ToString('O')
        runtimeBehaviorVerified = $verified
        checks = $checks
        appSmokePassed = $messages -match 'CHATTY_INPUT_PII_APP_SMOKE=passed'
    } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $root 'artifacts\input-pii-runtime-verification.json')
    if (!$verified) { throw 'Input blocking is not proven. Inspect the content-free evidence before retaining this configuration.' }
    $configurationPath = Join-Path $root 'artifacts\input-pii-Prompt-verification.json'
    $configuration = Get-Content -Raw $configurationPath | ConvertFrom-Json
    $configuration.runtimeBehaviorVerified = $true
    $configuration | Add-Member -NotePropertyName runtimeCheckedAtUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('O')) -Force
    $configuration | ConvertTo-Json -Depth 10 | Set-Content $configurationPath
} finally {
    $cleanupFailures = [Collections.Generic.List[string]]::new()
    foreach ($assignment in $temporary) {
        & $azPython -IBm azure.cli role assignment delete --ids $assignment.id --subscription $subscription --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            $cleanupFailures.Add($assignment.id)
            continue
        }
        $remaining = @(Invoke-AzJson @('role', 'assignment', 'list', '--scope', $assignment.scope,
            '--query', "[?id=='$($assignment.id)']"))
        if ($remaining.Count) { $cleanupFailures.Add($assignment.id) }
    }
    if ($cleanupFailures.Count) { throw "Temporary test grants remain: $($cleanupFailures -join ', ')" }
}
