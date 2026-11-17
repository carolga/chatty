targetScope = 'resourceGroup'

param location string = 'westus3'
param suffix string = 'demo0001'
param initialUserObjectId string
@allowed(['P0v3', 'B1'])
param appServiceSku string = 'P0v3'
@secure()
param jumpAdminPassword string

var tags = {
  workload: 'chatty'
  environment: 'poc'
  securitycontrol: 'ignore'
  costcontrol: 'ignore'
}
var vnetName = 'vnet-chatty-${suffix}'
var appName = 'chatty-web-${suffix}'
var accountName = 'chatty-ai-${suffix}'
var projectName = 'chatty'
var languageName = 'chatty-language-${suffix}'

resource jumpNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-chatty-jump'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowBastionRdp'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: '10.243.4.0/26'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'DenyOtherInbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource network 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: ['10.243.0.0/16'] }
    subnets: [
      {
        name: 'agents'
        properties: {
          addressPrefix: '10.243.0.0/24'
          natGateway: { id: nat.id }
          delegations: [{ name: 'agents', properties: { serviceName: 'Microsoft.App/environments' } }]
        }
      }
      {
        name: 'private-endpoints'
        properties: {
          addressPrefix: '10.243.1.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'web-integration'
        properties: {
          addressPrefix: '10.243.2.0/26'
          natGateway: { id: nat.id }
          delegations: [{ name: 'web', properties: { serviceName: 'Microsoft.Web/serverFarms' } }]
        }
      }
      {
        name: 'jump'
        properties: {
          addressPrefix: '10.243.3.0/27'
          networkSecurityGroup: { id: jumpNsg.id }
          defaultOutboundAccess: false
          natGateway: { id: nat.id }
        }
      }
      { name: 'AzureBastionSubnet', properties: { addressPrefix: '10.243.4.0/26' } }
    ]
  }
}

resource outboundIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-chatty-egress'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource nat 'Microsoft.Network/natGateways@2024-05-01' = {
  name: 'nat-chatty-jump'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIpAddresses: [{ id: outboundIp.id }]
    idleTimeoutInMinutes: 4
  }
}

module foundry 'foundry/modules-network-secured/ai-account-identity.bicep' = {
  name: 'foundry-account'
  params: {
    accountName: accountName
    location: location
    agentSubnetId: network.properties.subnets[0].id
    modelName: 'gpt-5-mini'
    modelFormat: 'OpenAI'
    modelVersion: '2025-08-07'
    modelSkuName: 'DataZoneStandard'
    modelCapacity: 10
  }
}

module foundryPrivateLink 'foundry/modules-network-secured/private-endpoint-and-dns.bicep' = {
  name: 'foundry-private-link'
  params: {
    aiAccountName: foundry.outputs.accountName
    vnetName: network.name
    peSubnetName: 'private-endpoints'
    suffix: suffix
    dnsZonesSubscriptionId: subscription().subscriptionId
  }
}

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = {
  parent: account
  name: projectName
  location: location
  identity: { type: 'SystemAssigned' }
  properties: { displayName: 'Chatty private POC', description: 'Screened synthetic mortgage reference chat.' }
  dependsOn: [foundry, foundryPrivateLink]
}

module capability 'foundry/modules-network-secured/add-project-capability-host.bicep' = {
  name: 'foundry-agent-capability'
  params: {
    accountName: accountName
    projectName: project.name
    projectCapHost: 'chatty-agents'
  }
}

resource language 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: languageName
  location: location
  tags: tags
  kind: 'TextAnalytics'
  sku: { name: 'S' }
  identity: { type: 'SystemAssigned' }
  properties: {
    customSubDomainName: languageName
    publicNetworkAccess: 'Disabled'
    disableLocalAuth: true
    networkAcls: { defaultAction: 'Deny', ipRules: [], virtualNetworkRules: [] }
  }
}

resource cognitiveDns 'Microsoft.Network/privateDnsZones@2020-06-01' existing = {
  name: 'privatelink.cognitiveservices.azure.com'
}

module languagePrivateLink 'private-endpoint.bicep' = {
  name: 'language-private-link'
  params: {
    location: location
    name: 'pe-chatty-language'
    subnetId: network.properties.subnets[1].id
    resourceId: language.id
    groupId: 'account'
    dnsZoneId: cognitiveDns.id
  }
  dependsOn: [foundryPrivateLink]
}

resource plan 'Microsoft.Web/serverfarms@2024-11-01' = {
  name: 'asp-chatty-${suffix}'
  location: location
  tags: tags
  kind: 'linux'
  sku: { name: appServiceSku, tier: appServiceSku == 'B1' ? 'Basic' : 'PremiumV3', capacity: 1 }
  properties: { reserved: true }
}

resource web 'Microsoft.Web/sites@2024-11-01' = {
  name: appName
  location: location
  tags: tags
  kind: 'app,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
    virtualNetworkSubnetId: network.properties.subnets[2].id
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|10.0'
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      http20Enabled: true
      remoteDebuggingEnabled: false
      vnetRouteAllEnabled: true
      detailedErrorLoggingEnabled: false
      requestTracingEnabled: false
      appSettings: [
        { name: 'ASPNETCORE_ENVIRONMENT', value: 'Production' }
        { name: 'ASPNETCORE_FORWARDEDHEADERS_ENABLED', value: 'false' }
        { name: 'WEBSITE_RUN_FROM_PACKAGE', value: '1' }
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'false' }
        { name: 'AllowedHosts', value: '${appName}.azurewebsites.net' }
        { name: 'AzureAd__TenantId', value: subscription().tenantId }
        { name: 'AzureAd__ClientCredentials__0__SourceType', value: 'SignedAssertionFromManagedIdentity' }
        { name: 'Chatty__LanguageEndpoint', value: 'https://${language.name}.cognitiveservices.azure.com/' }
        { name: 'Chatty__ProjectEndpoint', value: 'https://${accountName}.services.ai.azure.com/api/projects/${projectName}' }
        { name: 'Chatty__AgentName', value: 'chatty' }
        { name: 'Chatty__BaselineAgentName', value: 'chatty-no-pii' }
        { name: 'Chatty__TrustedProxyNetwork', value: '169.254.0.0/16' }
      ]
    }
  }
}

resource applicationLogs 'Microsoft.Web/sites/config@2024-11-01' = {
  parent: web
  name: 'logs'
  properties: {
    applicationLogs: {
      fileSystem: { level: 'Information' }
    }
    httpLogs: {
      // On Linux this switch also enables container stdout/stderr capture.
      fileSystem: { enabled: true, retentionInDays: 3, retentionInMb: 100 }
    }
    detailedErrorMessages: { enabled: false }
    failedRequestsTracing: { enabled: false }
  }
}

resource scmBasicAuth 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-11-01' = {
  parent: web
  name: 'scm'
  properties: { allow: false }
}

resource ftpBasicAuth 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-11-01' = {
  parent: web
  name: 'ftp'
  properties: { allow: false }
}

resource webDns 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.azurewebsites.net'
  location: 'global'
}

resource webDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: webDns
  name: 'chatty'
  location: 'global'
  properties: { virtualNetwork: { id: network.id }, registrationEnabled: false }
}

module webPrivateLink 'private-endpoint.bicep' = {
  name: 'web-private-link'
  params: {
    location: location
    name: 'pe-chatty-web'
    subnetId: network.properties.subnets[1].id
    resourceId: web.id
    groupId: 'sites'
    dnsZoneId: webDns.id
  }
  dependsOn: [webDnsLink]
}

resource bastionIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-chatty-bastion'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource bastion 'Microsoft.Network/bastionHosts@2024-05-01' = {
  name: 'bas-chatty-${suffix}'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    enableTunneling: true
    enableShareableLink: false
    scaleUnits: 2
    ipConfigurations: [{
      name: 'bastion'
      properties: {
        publicIPAddress: { id: bastionIp.id }
        subnet: { id: network.properties.subnets[4].id }
        privateIPAllocationMethod: 'Dynamic'
      }
    }]
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-chatty-jump'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [{
      name: 'private'
      properties: { subnet: { id: network.properties.subnets[3].id }, privateIPAllocationMethod: 'Dynamic' }
    }]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: 'vm-chatty-jump'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: 'Standard_D2s_v4' }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: { createOption: 'FromImage', managedDisk: { storageAccountType: 'StandardSSD_LRS' } }
    }
    osProfile: {
      computerName: 'chatty-jump'
      adminUsername: 'chatty-local'
      adminPassword: jumpAdminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
        patchSettings: { patchMode: 'AutomaticByPlatform', assessmentMode: 'AutomaticByPlatform' }
      }
    }
    networkProfile: { networkInterfaces: [{ id: nic.id }] }
    securityProfile: { securityType: 'TrustedLaunch', uefiSettings: { secureBootEnabled: true, vTpmEnabled: true } }
    diagnosticsProfile: { bootDiagnostics: { enabled: false } }
  }
}

resource entraLogin 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: vm
  name: 'AADLoginForWindows'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '2.0'
    autoUpgradeMinorVersion: true
  }
}

resource vmLogin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vm.id, initialUserObjectId, 'vm-login')
  scope: vm
  properties: {
    principalId: initialUserObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1c0163c0-47e6-4577-8991-ea5c82e286e4')
  }
}

resource appFoundryRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(project.id, web.id, 'foundry')
  scope: project
  properties: {
    principalId: web.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '53ca6127-db72-4b80-b1b0-d745d6d5456d')
  }
}

resource appLanguageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(language.id, web.id, 'language')
  scope: language
  properties: {
    principalId: web.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7628b7b8-a8b2-4cdc-b46f-e9b35248918e')
  }
}

output webAppName string = web.name
output webAppId string = web.id
output webPrincipalId string = web.identity.principalId
output webUrl string = 'https://${appName}.azurewebsites.net'
output projectId string = project.id
output projectEndpoint string = 'https://${accountName}.services.ai.azure.com/api/projects/${projectName}'
output languageId string = language.id
output languageEndpoint string = 'https://${language.name}.cognitiveservices.azure.com/'
output vmName string = vm.name
output vmId string = vm.id
output vmPrincipalId string = vm.identity.principalId
output bastionName string = bastion.name
