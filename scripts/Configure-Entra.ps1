[CmdletBinding()]
param(
    [Parameter(Mandatory)][Guid]$WebPrincipalId,
    [string]$WebAppName = 'chatty-web-demo0001'
)

$ErrorActionPreference = 'Stop'
$subscription = '00000000-0000-0000-0000-000000000001'
$tenant = '00000000-0000-0000-0000-000000000002'
$root = Split-Path $PSScriptRoot -Parent
$recordPath = Join-Path $root 'artifacts\entra.json'
$azPython = Join-Path (Split-Path (Split-Path (Get-Command az).Source -Parent) -Parent) 'python.exe'
$accountJson = & $azPython -IBm azure.cli account show --subscription $subscription --output json --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Subscription lookup failed.' }
if (($accountJson -join "`n" | ConvertFrom-Json).tenantId -ne $tenant) { throw 'Unexpected tenant.' }
$tokenJson = & $azPython -IBm azure.cli account get-access-token --subscription $subscription --resource 'https://graph.microsoft.com/' --output json --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Microsoft Graph authentication failed.' }
$token = ($tokenJson -join "`n" | ConvertFrom-Json).accessToken
try {
    $headers = @{ Authorization = "Bearer $token" }
    function Invoke-Graph([string]$Path, [string]$Method = 'Get', $Body = $null) {
        $arguments = @{ Uri = "https://graph.microsoft.com/v1.0/$Path"; Method = $Method; Headers = $headers }
        if ($null -ne $Body) {
            $arguments.ContentType = 'application/json'
            $arguments.Body = $Body | ConvertTo-Json -Depth 20
        }
        Invoke-RestMethod @arguments
    }

    $me = Invoke-Graph 'me?$select=id,userType'
    if ($me.userType -ne 'Member') { throw 'Initial user must be a tenant member.' }
    $displayName = "Chatty private POC $WebAppName"
    if (Test-Path -LiteralPath $recordPath) {
        $record = Get-Content -Raw $recordPath | ConvertFrom-Json
        if ($record.tenantId -ne $tenant) { throw 'Existing registration record is for a different tenant.' }
        $application = Invoke-Graph "applications/$($record.applicationObjectId)"
        if ($application.displayName -ne $displayName) { throw 'Saved app does not match Chatty.' }
    } else {
        $filter = [Uri]::EscapeDataString("displayName eq '$displayName'")
        $matches = Invoke-Graph "applications?`$filter=$filter"
        if (@($matches.value).Count -ne 0) { throw 'A matching app exists without a local record; review ownership before adopting it.' }
        $roleId = [Guid]::NewGuid().ToString()
        $application = Invoke-Graph 'applications' 'Post' @{
            displayName = $displayName
            signInAudience = 'AzureADMyOrg'
            isFallbackPublicClient = $false
            'owners@odata.bind' = @("https://graph.microsoft.com/v1.0/directoryObjects/$($me.id)")
            web = @{
                redirectUris = @("https://$WebAppName.azurewebsites.net/signin-oidc")
                implicitGrantSettings = @{ enableIdTokenIssuance = $false; enableAccessTokenIssuance = $false }
            }
            optionalClaims = @{ idToken = @(@{ name = 'acct'; essential = $true }) }
            requiredResourceAccess = @()
            appRoles = @(@{
                id = $roleId
                allowedMemberTypes = @('User')
                displayName = 'Chatty user'
                description = 'Use the private Chatty application with mandatory PII screening.'
                value = 'Chatty.User'
                isEnabled = $true
            })
        }
        $record = [pscustomobject]@{
            tenantId = $tenant
            applicationObjectId = $application.id
            clientId = $application.appId
            servicePrincipalId = ''
        }
        $record | ConvertTo-Json | Set-Content $recordPath
    }
    if ($application.signInAudience -ne 'AzureADMyOrg') { throw 'The Chatty app must remain single-tenant.' }
    $chatRole = @($application.appRoles | Where-Object { $_.value -eq 'Chatty.User' -and $_.isEnabled })
    if ($chatRole.Count -ne 1) { throw 'Expected one enabled Chatty.User role.' }

    if (!$record.servicePrincipalId) {
        $servicePrincipal = Invoke-Graph 'servicePrincipals' 'Post' @{
            appId = $application.appId
            accountEnabled = $true
            appRoleAssignmentRequired = $true
        }
        $record.servicePrincipalId = $servicePrincipal.id
        $record | ConvertTo-Json | Set-Content $recordPath
    } else {
        $servicePrincipal = Invoke-Graph "servicePrincipals/$($record.servicePrincipalId)"
        if ($servicePrincipal.appId -ne $application.appId) { throw 'Service principal does not match the saved app.' }
        $null = Invoke-Graph "servicePrincipals/$($servicePrincipal.id)" 'Patch' @{ appRoleAssignmentRequired = $true }
    }
    $assignments = Invoke-Graph "servicePrincipals/$($servicePrincipal.id)/appRoleAssignedTo"
    if (@($assignments.value | Where-Object { $_.principalId -ne $me.id }).Count -ne 0) {
        throw 'Unexpected Chatty user assignments; review access instead of deleting existing assignments automatically.'
    }
    if (!($assignments.value | Where-Object { $_.principalId -eq $me.id -and $_.appRoleId -eq $chatRole[0].id })) {
        $null = Invoke-Graph "servicePrincipals/$($servicePrincipal.id)/appRoleAssignedTo" 'Post' @{
            principalId = $me.id
            resourceId = $servicePrincipal.id
            appRoleId = $chatRole[0].id
        }
    }
    $federationName = 'chatty-app-service'
    $federated = Invoke-Graph "applications/$($application.id)/federatedIdentityCredentials"
    $existing = @($federated.value | Where-Object name -eq $federationName)
    if ($existing.Count -gt 1) { throw 'Unexpected duplicate federation configuration.' }
    $trust = @{
        name = $federationName
        issuer = "https://login.microsoftonline.com/$tenant/v2.0"
        subject = $WebPrincipalId.ToString()
        audiences = @('api://AzureADTokenExchange')
        description = 'Trust only the private Chatty App Service system-assigned managed identity.'
    }
    if ($existing.Count -eq 0) {
        $null = Invoke-Graph "applications/$($application.id)/federatedIdentityCredentials" 'Post' $trust
    } elseif ($existing[0].subject -ne $trust.subject -or $existing[0].issuer -ne $trust.issuer) {
        throw 'Existing federation points to a different identity; explicit review required.'
    }
    Write-Output "Configured single-tenant Chatty app $($application.appId); only the current member is assigned."
    Write-Output 'App Service federates with its managed identity; no client secret was created.'
} finally {
    $token = $null
    $tokenJson = $null
    $headers = $null
}
