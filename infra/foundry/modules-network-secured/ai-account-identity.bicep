param accountName string
param location string
param modelName string
param modelFormat string
param modelVersion string
param modelSkuName string
param modelCapacity int
param agentSubnetId string
param networkInjection string = 'true'

#disable-next-line BCP036
resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' = {
  name: accountName
  location: location
  sku: {
    name: 'S0'
  }
  kind: 'AIServices'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: accountName
    networkAcls: {
      defaultAction: 'Deny'
      virtualNetworkRules: []
      ipRules: []
      bypass:'None'
    }
    publicNetworkAccess: 'Disabled'
    networkInjections:((networkInjection == 'true') ? [
      {
        scenario: 'agent'
        subnetArmId: agentSubnetId
        useMicrosoftManagedNetwork: false
      }
      ] : null )
    disableLocalAuth: true
  }
}

var promptFilters = [for category in ['Hate', 'Sexual', 'Violence', 'SelfHarm']: {
  name: category
  source: 'Prompt'
  enabled: true
  blocking: true
  severityThreshold: 'Low'
}]
var completionFilters = [for category in ['Hate', 'Sexual', 'Violence', 'SelfHarm']: {
  name: category
  source: 'Completion'
  enabled: true
  blocking: true
  severityThreshold: 'Low'
}]
var piiFilters = [for filterName in loadJsonContent('../../pii-filter-names.json'): union({
  name: filterName
  source: 'Completion'
  enabled: true
  blocking: filterName != 'Name Protection'
}, filterName == 'Name Protection' ? { action: 'ANNOTATING' } : {})]
var inputPiiFilters = [for filterName in loadJsonContent('../../pii-filter-names.json'): {
  name: filterName
  source: 'Prompt'
  enabled: true
  blocking: true
  action: 'BLOCKING'
}]

resource safety 'Microsoft.CognitiveServices/accounts/raiPolicies@2026-09-01' = {
  parent: account
  name: 'ChattyStrict'
  properties: {
    basePolicyName: 'Microsoft.Default'
    mode: 'Blocking'
    contentFilters: concat(
      promptFilters,
      completionFilters,
      piiFilters,
      inputPiiFilters,
      [{ name: 'Jailbreak', source: 'Prompt', enabled: true, blocking: true }]
    )
  }
}

resource baselineSafety 'Microsoft.CognitiveServices/accounts/raiPolicies@2026-03-01' = {
  parent: account
  name: 'ChattyWithoutPii'
  tags: { workload: 'chatty', environment: 'poc', securitycontrol: 'ignore', costcontrol: 'ignore' }
  properties: {
    basePolicyName: 'Microsoft.Default'
    mode: 'Blocking'
    contentFilters: concat(
      promptFilters,
      completionFilters,
      [{ name: 'Jailbreak', source: 'Prompt', enabled: true, blocking: true }]
    )
  }
}

#disable-next-line BCP081
resource baselineDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview' = {
  parent: account
  name: '${modelName}-no-pii'
  tags: { workload: 'chatty', environment: 'poc', securitycontrol: 'ignore', costcontrol: 'ignore' }
  sku: { capacity: modelCapacity, name: modelSkuName }
  properties: {
    raiPolicyName: baselineSafety.name
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
    model: { name: modelName, format: modelFormat, version: modelVersion }
  }
}

#disable-next-line BCP081
resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview'=  {
  parent: account
  name: modelName
  sku : {
    capacity: modelCapacity
    name: modelSkuName
  }
  properties: {
    raiPolicyName: safety.name
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
    model:{
      name: modelName
      format: modelFormat
      version: modelVersion
    }
  }
}

output accountName string = account.name
output accountID string = account.id
output accountTarget string = account.properties.endpoint
output accountPrincipalId string = account.identity.principalId
