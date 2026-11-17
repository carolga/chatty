param(
    [ValidateSet('true', 'false')][string]$InspectOnly = 'false',
    [ValidateSet('true', 'false')][string]$RetryFailedEvaluator = 'false'
)

$ErrorActionPreference = 'Stop'
$work = Join-Path $env:ProgramData 'ChattyDeployment\evaluation'
$azd = Join-Path $work 'azd.exe'
$endpoint = 'https://chatty-ai-demo0001.services.ai.azure.com/api/projects/chatty'
$env:PATH = "$work;$env:PATH"
$env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'
Set-Location $work

function Invoke-EvaluationCli([string[]]$Arguments, [string]$OutputPath) {
    $preference = $ErrorActionPreference
    try {
        # Windows PowerShell otherwise treats a native stderr warning as a terminating error.
        $ErrorActionPreference = 'Continue'
        & $azd @Arguments 1> $OutputPath 2> "$OutputPath.errors.log"
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $preference
    }
    if ($code -ne 0) { throw "Evaluation CLI failed; inspect private output $OutputPath and $OutputPath.errors.log" }
    Get-Content -Raw -LiteralPath $OutputPath | ConvertFrom-Json
}

function Find-Job($Node, [string]$Type) {
    if ($Node -is [Array]) {
        foreach ($item in $Node) { Find-Job $item $Type }
    } elseif ($Node -is [pscustomobject]) {
        foreach ($property in $Node.PSObject.Properties) {
            if ($property.Value -is [string] -and
                $property.Value -match '^(datagen|evaluatorgen)[-_][A-Za-z0-9_-]{1,180}$') {
                $status = "$($Node.status)".ToLowerInvariant()
                if ($status -notmatch '^(succeeded|completed|failed|cancelled|canceled|in_progress|queued|pending|running|notstarted|not_started|inprogress)$') {
                    $status = 'unknown'
                }
                [pscustomobject]@{ type = $Type; id = $property.Value; status = $status }
            } elseif ($property.Value -isnot [string]) {
                Find-Job $property.Value $Type
            }
        }
    }
}

$jobs = @()
foreach ($type in @('dataset', 'evaluator')) {
    $listed = Invoke-EvaluationCli @('ai', 'eval', 'job', 'list', "--$type",
        '--project-endpoint', $endpoint, '--no-prompt', '--output', 'json') (Join-Path $work "$type-job-list.json")
    $found = @(Find-Job $listed $type | Sort-Object id -Unique)
    if ($found.Count -gt 1) {
        $nonFailed = @($found | Where-Object status -NotMatch '^(failed|canceled|cancelled)$')
        if ($nonFailed.Count -eq 1) { $found = $nonFailed }
    }
    if ($found.Count -gt 1) { throw "Multiple $type generation jobs exist; review rather than submitting duplicates." }
    if ($type -eq 'evaluator' -and $RetryFailedEvaluator -eq 'true') {
        $allEvaluators = @(Find-Job $listed $type | Sort-Object id -Unique)
        if ($allEvaluators.Count -ne 1 -or $allEvaluators[0].status -ne 'failed') {
            throw 'Automatic evaluator retry is limited to one verified terminal failure.'
        }
        $found = @()
    }
    if ($found.Count -eq 0) {
        if ($InspectOnly -eq 'true') { throw "No $type generation job found; inspection never submits a new job." }
        $generate = @('ai', 'eval', 'generate', "--$type",
            '--project-endpoint', $endpoint, '--target', 'chatty',
            '--agent-instruction-file', (Join-Path $work 'generation-instructions.txt'),
            '--generation-model', 'gpt-5-mini', '--trace-days', '0',
            '--no-wait', '--no-prompt', '--output', 'json')
        if ($type -eq 'dataset') {
            $generate += @('--from', 'agent', '--max-samples', '15', '--dataset-name', 'chatty-synthetic-smoke')
        } else {
            $generate += @('--evaluator-name', 'chatty-synthetic-rubric')
        }
        $generated = Invoke-EvaluationCli $generate (Join-Path $work "$type-resumed-submission.json")
        $found = @(Find-Job $generated $type | Sort-Object id -Unique)
        if ($found.Count -ne 1) { throw "Could not recover the submitted $type job reference; inspect the saved private output." }
    }
    $jobs += $found
}
Write-Output ("CHATTY_EVAL_JOBS=" + (ConvertTo-Json -InputObject $jobs -Compress))
Write-Output 'CHATTY_EVAL_GENERATION_SUBMITTED'
