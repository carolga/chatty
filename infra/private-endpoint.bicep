param location string
param name string
param subnetId string
param resourceId string
param groupId string
param dnsZoneId string

resource endpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: name
  location: location
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [{
      name: name
      properties: { privateLinkServiceId: resourceId, groupIds: [groupId] }
    }]
  }
}

resource dns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: endpoint
  name: 'default'
  properties: { privateDnsZoneConfigs: [{ name: 'default', properties: { privateDnsZoneId: dnsZoneId } }] }
}
