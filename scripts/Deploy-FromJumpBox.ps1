$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$work = Join-Path $env:ProgramData 'ChattyDeployment'
New-Item -ItemType Directory -Path $work -Force | Out-Null
$source = Join-Path $work ('source-' + [Guid]::NewGuid().ToString('N'))
$archive = Join-Path $work 'source.zip'
$sdk = Join-Path $work 'dotnet'
$projectEndpoint = 'CHATTY_PROJECT_ENDPOINT'
$languageEndpoint = 'CHATTY_LANGUAGE_ENDPOINT'
$appHost = 'chatty-web-demo0001.azurewebsites.net'
$webId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-chatty-westus3-demo/providers/Microsoft.Web/sites/chatty-web-demo0001'
$clientId = 'CHATTY_CLIENT_ID'

function Get-ManagedToken([string]$Resource) {
    $encoded = [Uri]::EscapeDataString($Resource)
    (Invoke-RestMethod -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$encoded" -Headers @{ Metadata = 'true' } -TimeoutSec 30).access_token
}

$armToken = $null
$aiToken = $null
try {
    Write-Output 'CHATTY_STAGE=private_dns'
    foreach ($hostName in @(([Uri]$projectEndpoint).Host, ([Uri]$languageEndpoint).Host, $appHost, "chatty-web-demo0001.scm.azurewebsites.net")) {
        $addresses = [Net.Dns]::GetHostAddresses($hostName)
        if ($addresses.Count -eq 0 -or @($addresses | Where-Object { !$_.ToString().StartsWith('10.243.1.') }).Count -ne 0) {
            throw 'Private endpoint DNS validation failed.'
        }
        Write-Output "Private DNS confirmed: $hostName"
    }

    Write-Output 'CHATTY_STAGE=build'
    [IO.File]::WriteAllBytes($archive, [Convert]::FromBase64String('CHATTY_SOURCE_ARCHIVE'))
    Expand-Archive -LiteralPath $archive -DestinationPath $source -Force
    if (!(Test-Path -LiteralPath (Join-Path $sdk 'dotnet.exe'))) {
        $installer = Join-Path $work 'dotnet-install.ps1'
        Invoke-WebRequest -UseBasicParsing -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $installer
        & $installer -Version '10.0.403' -Architecture x64 -InstallDir $sdk -NoPath *> (Join-Path $work 'sdk-install.log')
        if (!(Test-Path -LiteralPath (Join-Path $sdk 'dotnet.exe'))) { throw 'SDK installation failed.' }
    }
    $dotnet = Join-Path $sdk 'dotnet.exe'
    $env:DOTNET_ROOT = $sdk
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_NOLOGO = '1'
    $publish = Join-Path $work 'publish'
    # ZIP timestamps are local-time based; do not reuse outputs from an older source archive.
    & $dotnet clean (Join-Path $source 'scripts\Smoke\Smoke.csproj') -c Release *> (Join-Path $work 'clean.log')
    if ($LASTEXITCODE -ne 0) { throw 'Cleaning prior build outputs failed; see private clean.log.' }
    & $dotnet publish (Join-Path $source 'src\Chatty.Web\Chatty.Web.csproj') -c Release -o $publish -p:UseAppHost=false -p:RestoreLockedMode=true "-p:RestoreConfigFile=$(Join-Path $source 'NuGet.config')" *> (Join-Path $work 'publish.log')
    if ($LASTEXITCODE -ne 0) { throw 'Web application build failed; see private publish.log.' }
    $expectedApplicationHash = (Get-FileHash -LiteralPath (Join-Path $publish 'Chatty.Web.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedUiAssets = @{}
    foreach ($name in @('index.html', 'app.js', 'app.css')) {
        $file = Join-Path (Join-Path $publish 'wwwroot') $name
        if (!(Test-Path -LiteralPath $file -PathType Leaf) -or (Get-Item -LiteralPath $file).Length -eq 0) {
            throw "Published UI asset is missing or empty: $name"
        }
        $expectedUiAssets[$name] = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    & $dotnet build (Join-Path $source 'scripts\Smoke\Smoke.csproj') -c Release -p:RestoreLockedMode=true "-p:RestoreConfigFile=$(Join-Path $source 'NuGet.config')" *> (Join-Path $work 'smoke-build.log')
    if ($LASTEXITCODE -ne 0) { throw 'Smoke harness build failed; see private smoke-build.log.' }
    Write-Output 'Build completed on the private jump box.'

    Write-Output 'CHATTY_STAGE=agent'
    $aiToken = Get-ManagedToken 'https://ai.azure.com'
    $aiHeaders = @{ Authorization = "Bearer $aiToken" }
    $agentFolder = Join-Path $source 'src\Chatty.Web\Agent'
    $agentDefinition = Get-Content -Raw (Join-Path $agentFolder 'definition.json') | ConvertFrom-Json
    $instructions = (Get-Content -Raw (Join-Path $agentFolder 'instructions.md')).Replace("`r`n", "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($instructions)) { throw 'The prompt agent instructions are empty.' }
    $agentDefinition.definition | Add-Member -NotePropertyName instructions -NotePropertyValue $instructions
    $agentBody = $agentDefinition | ConvertTo-Json -Depth 10
    try {
        $agent = Invoke-RestMethod -Uri "$projectEndpoint/agents/chatty?api-version=v1" -Headers $aiHeaders -TimeoutSec 60
    } catch [Net.WebException] {
        if ([int]$_.Exception.Response.StatusCode -ne 404) { throw }
        $agent = Invoke-RestMethod -Uri "$projectEndpoint/agents?api-version=v1" -Method Post -Headers $aiHeaders -ContentType 'application/json' -Body $agentBody -TimeoutSec 90
    }
    $definition = ($agentBody | ConvertFrom-Json).definition
    $pinned = $agent.versions.latest
    $version = 0
    if ($agent.name -ne 'chatty' -or $pinned.definition.kind -ne 'prompt' -or
        $pinned.definition.model -ne $definition.model -or
        $pinned.definition.instructions.Replace("`r`n", "`n").Trim() -cne $definition.instructions -or $null -ne $pinned.definition.harness -or
        @($pinned.definition.PSObject.Properties.Name | Where-Object { $_ -notin @('kind', 'model', 'instructions', 'tools') }).Count -ne 0 -or
        ($null -ne $pinned.definition.tools -and @($pinned.definition.tools).Count -ne 0) -or
        ![int]::TryParse([string]$pinned.version, [ref]$version) -or $version -lt 1) {
        throw 'Foundry agent definition or pinned version differs from the approved configuration.'
    }
    Write-Output "CHATTY_AGENT_VERSION=$version"
    $baselineDefinition = Get-Content -Raw (Join-Path $agentFolder 'baseline-definition.json') | ConvertFrom-Json
    $baselineDefinition.definition | Add-Member -NotePropertyName instructions -NotePropertyValue $instructions
    $baselineBody = $baselineDefinition | ConvertTo-Json -Depth 10
    try {
        $baselineAgent = Invoke-RestMethod -Uri "$projectEndpoint/agents/chatty-no-pii?api-version=v1" -Headers $aiHeaders -TimeoutSec 60
    } catch [Net.WebException] {
        if ([int]$_.Exception.Response.StatusCode -ne 404) { throw }
        $baselineAgent = Invoke-RestMethod -Uri "$projectEndpoint/agents?api-version=v1" -Method Post -Headers $aiHeaders -ContentType 'application/json' -Body $baselineBody -TimeoutSec 90
    }
    $baselinePinned = $baselineAgent.versions.latest
    $baselineVersion = 0
    if ($baselineAgent.name -ne 'chatty-no-pii' -or $baselinePinned.definition.kind -ne 'prompt' -or
        $baselinePinned.definition.model -ne $baselineDefinition.definition.model -or
        $baselinePinned.definition.instructions.Replace("`r`n", "`n").Trim() -cne $instructions -or
        @($baselinePinned.definition.PSObject.Properties.Name | Where-Object { $_ -notin @('kind', 'model', 'instructions', 'tools') }).Count -ne 0 -or
        ($null -ne $baselinePinned.definition.tools -and @($baselinePinned.definition.tools).Count -ne 0) -or
        ![int]::TryParse([string]$baselinePinned.version, [ref]$baselineVersion) -or $baselineVersion -lt 1) {
        throw 'Baseline agent differs from the approved shared prompt, model deployment, or no-tools/no-override configuration.'
    }
    Write-Output "CHATTY_BASELINE_AGENT_VERSION=$baselineVersion"

    Write-Output 'CHATTY_STAGE=privacy_smoke'
    & $dotnet (Join-Path $source 'scripts\Smoke\bin\Release\net10.0\Smoke.dll') (Join-Path $source 'src\Chatty.Web') $languageEndpoint $projectEndpoint ([string]$version) ([string]$baselineVersion)
    if ($LASTEXITCODE -ne 0) { throw 'Private service privacy smoke checks failed.' }

    Write-Output 'CHATTY_STAGE=publish'
    $armToken = Get-ManagedToken 'https://management.azure.com/'
    $armHeaders = @{ Authorization = "Bearer $armToken" }
    $settings = Invoke-RestMethod -Uri "https://management.azure.com$webId/config/appsettings/list?api-version=2024-11-01" -Method Post -Headers $armHeaders -TimeoutSec 60
    $settings.properties | Add-Member -NotePropertyName 'AzureAd__ClientId' -NotePropertyValue $clientId -Force
    $settings.properties | Add-Member -NotePropertyName 'Chatty__AgentVersion' -NotePropertyValue ([string]$version) -Force
    $settings.properties | Add-Member -NotePropertyName 'Chatty__BaselineAgentName' -NotePropertyValue 'chatty-no-pii' -Force
    $settings.properties | Add-Member -NotePropertyName 'Chatty__BaselineAgentVersion' -NotePropertyValue ([string]$baselineVersion) -Force
    $settings.properties | Add-Member -NotePropertyName 'Chatty__TrustedProxyNetwork' -NotePropertyValue '169.254.0.0/16' -Force
    $null = Invoke-RestMethod -Uri "https://management.azure.com$webId/config/appsettings?api-version=2024-11-01" -Method Put -Headers $armHeaders -ContentType 'application/json' -Body (@{ properties = $settings.properties } | ConvertTo-Json -Depth 10) -TimeoutSec 60
    $package = Join-Path $work 'web.zip'
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipArchive]::new([IO.File]::Create($package), [IO.Compression.ZipArchiveMode]::Create)
    try {
        $prefix = [IO.Path]::GetFullPath($publish).TrimEnd('\') + '\'
        foreach ($file in Get-ChildItem -LiteralPath $publish -Recurse -File) {
            $relative = $file.FullName.Substring($prefix.Length).Replace('\', '/')
            $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $relative, [IO.Compression.CompressionLevel]::Optimal)
        }
    } finally {
        $zip.Dispose()
    }
    $zip = [IO.Compression.ZipFile]::OpenRead($package)
    try {
        if (@($zip.Entries | Where-Object { $_.FullName.Contains('\') }).Count -ne 0) {
            throw 'The Linux deployment ZIP contains Windows path separators.'
        }
        foreach ($name in $expectedUiAssets.Keys) {
            $entry = $zip.GetEntry("wwwroot/$name")
            if ($null -eq $entry -or $entry.Length -eq 0) { throw "The deployment ZIP is missing UI asset: $name" }
        }
        $knowledge = $zip.GetEntry('Knowledge/synthetic.json')
        if ($null -eq $knowledge -or $knowledge.Length -eq 0) { throw 'The deployment ZIP is missing synthetic knowledge.' }
    } finally {
        $zip.Dispose()
    }
    $scm = 'https://chatty-web-demo0001.scm.azurewebsites.net'
    $null = Invoke-WebRequest -UseBasicParsing -Uri "$scm/api/zipdeploy?isAsync=true" -Method Post -Headers $armHeaders -ContentType 'application/zip' -InFile $package -TimeoutSec 120
    $deadline = [DateTime]::UtcNow.AddMinutes(10)
    do {
        Start-Sleep -Seconds 15
        $deployment = Invoke-RestMethod -Uri "$scm/api/deployments/latest" -Headers $armHeaders -TimeoutSec 30
        if ($deployment.status -eq 3) { throw 'Private SCM deployment failed.' }
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Private SCM deployment timed out.' }
    } while ($deployment.status -ne 4)

    Write-Output 'CHATTY_STAGE=web_health'
    $deadline = [DateTime]::UtcNow.AddMinutes(5)
    do {
        try {
            $health = Invoke-RestMethod -Uri "https://$appHost/health/live" -TimeoutSec 30
            $ready = Invoke-RestMethod -Uri "https://$appHost/health/ready" -TimeoutSec 30
        } catch [Net.WebException] {
            $status = [int]$_.Exception.Response.StatusCode
            $transientHttp = $status -in @(404, 500, 502, 503, 504)
            $transientConnection = $_.Exception.Status -in @(
                [Net.WebExceptionStatus]::ConnectFailure,
                [Net.WebExceptionStatus]::ConnectionClosed,
                [Net.WebExceptionStatus]::Timeout,
                [Net.WebExceptionStatus]::ReceiveFailure,
                [Net.WebExceptionStatus]::SendFailure,
                [Net.WebExceptionStatus]::KeepAliveFailure
            )
            if ((!$transientHttp -and !$transientConnection) -or [DateTime]::UtcNow -gt $deadline) { throw }
            Start-Sleep -Seconds 15
            continue
        }
        if ($health.status -ne 'alive') { throw 'Unexpected web health response.' }
        $assetsMatch = $ready.status -eq 'ready' -and
            $ready.applicationHash -ceq $expectedApplicationHash -and
            @($ready.uiAssets.PSObject.Properties).Count -eq $expectedUiAssets.Count
        foreach ($name in $expectedUiAssets.Keys) {
            $assetsMatch = $assetsMatch -and $ready.uiAssets.$name -ceq $expectedUiAssets[$name]
        }
        if (!$assetsMatch) {
            if ([DateTime]::UtcNow -gt $deadline) { throw 'Live application/UI hashes do not match the published package.' }
            Start-Sleep -Seconds 15
            continue
        }
        break
    } while ($true)
    try {
        $null = Invoke-WebRequest -UseBasicParsing -Uri "https://$appHost/api/session" -TimeoutSec 30
        throw 'Anonymous API access was unexpectedly allowed.'
    } catch [Net.WebException] {
        if ([int]$_.Exception.Response.StatusCode -ne 401) { throw }
    }
    Add-Type -AssemblyName System.Net.Http
    Add-Type -AssemblyName System.Web
    $handler = New-Object Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $browser = New-Object Net.Http.HttpClient($handler)
    try {
        $signIn = $browser.GetAsync("https://$appHost/").GetAwaiter().GetResult()
        $location = $signIn.Headers.Location
        if ([int]$signIn.StatusCode -ne 302 -or !$location -or $location.Host -ne 'login.microsoftonline.com') {
            throw 'The private app did not challenge with Entra sign-in.'
        }
        $query = [Web.HttpUtility]::ParseQueryString($location.Query)
        if ($query['redirect_uri'] -ne "https://$appHost/signin-oidc") {
            throw 'The Entra callback is not the expected canonical HTTPS address.'
        }
        $denied = $browser.GetAsync("https://$appHost/MicrosoftIdentity/Account/AccessDenied").GetAwaiter().GetResult()
        if ([int]$denied.StatusCode -ne 302 -or !$denied.Headers.Location -or
            $denied.Headers.Location.Host -ne 'login.microsoftonline.com' -or
            $denied.Content.ReadAsStringAsync().GetAwaiter().GetResult() -match '"reasons"') {
            throw 'Access-denied diagnostics did not require Entra authentication.'
        }
    } finally {
        $browser.Dispose()
        $handler.Dispose()
    }
    Write-Output 'PASS: private readiness and exact live application/UI hashes, anonymous API/diagnostic denial, and canonical HTTPS Entra challenge.'
    Write-Output 'CHATTY_DEPLOYMENT_SUCCEEDED'
} finally {
    $armToken = $null
    $aiToken = $null
    $armHeaders = $null
    $aiHeaders = $null
}
