// Model Hub on an Azure virtual machine, as described in
// https://hackolade.com/help/ModelHubonanAzurevirtualmachine.html
// Comments give the step of the guide that each part follows.

@description('Azure region; defaults to the region of the resource group.')
param location string = resourceGroup().location

@description('Tag of the hackolade/model-hub image on Docker Hub, installed at first boot.')
param modelHubVersion string

@description('Versionless secret ID of the Key Vault certificate of the hostname, for example https://my-vault.vault.azure.net/secrets/hck-example-com')
#disable-next-line secure-secrets-in-params // a URI, not a secret
param certificateSecretId string

@description('Resource ID of a user-assigned managed identity that has the Key Vault Secrets User role on the vault of the certificate.')
param gatewayIdentityId string

@description('IP ranges allowed to reach the Application Gateway on ports 443 and 80.')
param allowedSourceAddressPrefixes array = ['0.0.0.0/0']

@description('Login of the virtual machine administrator, for Azure Bastion.')
param adminUsername string = 'azureuser'

@description('SSH public key of the virtual machine administrator, for Azure Bastion.')
param adminSshPublicKey string

@description('Virtual machine size, at least 4 vCPUs.')
param vmSize string = 'Standard_D4s_v5'

@description('Compute of the PostgreSQL flexible server.')
param postgresSku object = {
  name: 'Standard_B2ms'
  tier: 'Burstable'
}

@secure()
@description('Password of the PostgreSQL administrator login, used once at first boot to create the hck_hub user. Generated when not given.')
param postgresAdminPassword string = newGuid()

var postgresAdminLogin = 'hubadmin'
var suffix = uniqueString(resourceGroup().id)

// Step 1: virtual network with appgw-subnet, vm-subnet behind a NAT gateway, and db-subnet.
// Step 2: network security groups on the first two subnets.

resource appgwNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-hub-appgw'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowHttpsHttp'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefixes: allowedSourceAddressPrefixes
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: ['443', '80']
        }
      }
      {
        name: 'AllowGatewayManager'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '65200-65535'
        }
      }
    ]
  }
}

resource vmNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-hub-vm'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowModelHubFromGateway'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '10.0.0.0/24'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3000'
        }
      }
    ]
  }
}

resource natIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-hub-nat'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource nat 'Microsoft.Network/natGateways@2024-05-01' = {
  name: 'nat-hub'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIpAddresses: [{ id: natIp.id }]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-hub'
  location: location
  properties: {
    addressSpace: { addressPrefixes: ['10.0.0.0/16'] }
    subnets: [
      {
        name: 'appgw-subnet'
        properties: {
          addressPrefix: '10.0.0.0/24'
          networkSecurityGroup: { id: appgwNsg.id }
        }
      }
      {
        name: 'vm-subnet'
        properties: {
          addressPrefix: '10.0.1.0/24'
          networkSecurityGroup: { id: vmNsg.id }
          natGateway: { id: nat.id }
        }
      }
      {
        name: 'db-subnet'
        properties: {
          addressPrefix: '10.0.2.0/24'
          delegations: [
            {
              name: 'postgres'
              properties: { serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers' }
            }
          ]
        }
      }
    ]
  }

  resource appgwSubnet 'subnets' existing = { name: 'appgw-subnet' }
  resource vmSubnet 'subnets' existing = { name: 'vm-subnet' }
  resource dbSubnet 'subnets' existing = { name: 'db-subnet' }
}

// Step 3: PostgreSQL flexible server with private access, and its private DNS zone.

resource dbDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'hub-db.private.postgres.database.azure.com'
  location: 'global'
}

resource dbDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: dbDnsZone
  name: 'vnet-hub'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

resource postgres 'Microsoft.DBforPostgreSQL/flexibleServers@2025-08-01' = {
  name: 'psql-hub-${suffix}'
  location: location
  sku: postgresSku
  properties: {
    version: '17'
    administratorLogin: postgresAdminLogin
    administratorLoginPassword: postgresAdminPassword
    authConfig: {
      passwordAuth: 'Enabled'
      activeDirectoryAuth: 'Disabled'
    }
    storage: { storageSizeGB: 32 }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    network: {
      delegatedSubnetResourceId: vnet::dbSubnet.id
      privateDnsZoneArmResourceId: dbDnsZone.id
      publicNetworkAccess: 'Disabled'
    }
  }
  dependsOn: [dbDnsZoneLink]
}

// Secrets: the administrator password here; the virtual machine adds the hck_hub password
// and the encryption key at first boot (see cloud-init.sh).

resource vault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: 'kv-hub-${suffix}'
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
  }

  resource adminPassword 'secrets' = {
    name: 'postgres-admin-password'
    properties: { value: postgresAdminPassword }
  }
}

resource vmIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-hub-vm'
  location: location
}

var keyVaultSecretsOfficer = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'

resource vmVaultAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, vmIdentity.id, keyVaultSecretsOfficer)
  scope: vault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsOfficer)
    principalId: vmIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Step 4: the virtual machine, without a public IP address, reached with Azure Bastion.

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-hub-vm'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: { id: vnet::vmSubnet.id }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

// Steps 4 to 6 of the guide: install Docker, create the database user, start the Model Hub.
var customData = join(
  [
    '#!/bin/bash'
    'MODEL_HUB_VERSION=\'${modelHubVersion}\''
    'DB_HOST=\'${postgres.properties.fullyQualifiedDomainName}\''
    'DB_ADMIN_USERNAME=\'${postgresAdminLogin}\''
    'VAULT_URI=\'${vault.properties.vaultUri}\''
    'IDENTITY_CLIENT_ID=\'${vmIdentity.properties.clientId}\''
    loadTextContent('cloud-init.sh')
  ],
  '\n'
)

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: 'vm-hub'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${vmIdentity.id}': {} }
  }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 64
        managedDisk: { storageAccountType: 'Premium_LRS' }
        deleteOption: 'Delete'
      }
    }
    osProfile: {
      computerName: 'vm-hub'
      adminUsername: adminUsername
      customData: base64(customData)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: { deleteOption: 'Delete' }
        }
      ]
    }
  }
  // The first boot reads the administrator password from Key Vault.
  dependsOn: [vmVaultAccess, vault::adminPassword]
}

// Step 8: Application Gateway v2, the only way in, with the certificate from Key Vault.

resource gatewayIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-hub-appgw'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

var gatewayName = 'agw-hub'
var gatewayId = resourceId('Microsoft.Network/applicationGateways', gatewayName)

resource gateway 'Microsoft.Network/applicationGateways@2024-05-01' = {
  name: gatewayName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${gatewayIdentityId}': {} }
  }
  properties: {
    sku: { name: 'Standard_v2', tier: 'Standard_v2', capacity: 1 }
    sslPolicy: { policyType: 'Predefined', policyName: 'AppGwSslPolicy20220101' }
    gatewayIPConfigurations: [
      {
        name: 'gateway-ip'
        properties: { subnet: { id: vnet::appgwSubnet.id } }
      }
    ]
    sslCertificates: [
      {
        name: 'hub-certificate'
        properties: { keyVaultSecretId: certificateSecretId }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'public'
        properties: { publicIPAddress: { id: gatewayIp.id } }
      }
    ]
    frontendPorts: [
      { name: 'port-443', properties: { port: 443 } }
      { name: 'port-80', properties: { port: 80 } }
    ]
    backendAddressPools: [
      {
        name: 'hub-vm'
        properties: {
          backendAddresses: [{ ipAddress: nic.properties.ipConfigurations[0].properties.privateIPAddress }]
        }
      }
    ]
    probes: [
      {
        name: 'ready'
        properties: {
          protocol: 'Http'
          host: '127.0.0.1'
          path: '/ready'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'hub-3000'
        properties: {
          protocol: 'Http'
          port: 3000
          pickHostNameFromBackendAddress: false
          requestTimeout: 60
          probe: { id: '${gatewayId}/probes/ready' }
        }
      }
    ]
    httpListeners: [
      {
        name: 'https'
        properties: {
          protocol: 'Https'
          frontendIPConfiguration: { id: '${gatewayId}/frontendIPConfigurations/public' }
          frontendPort: { id: '${gatewayId}/frontendPorts/port-443' }
          sslCertificate: { id: '${gatewayId}/sslCertificates/hub-certificate' }
        }
      }
      {
        name: 'http'
        properties: {
          protocol: 'Http'
          frontendIPConfiguration: { id: '${gatewayId}/frontendIPConfigurations/public' }
          frontendPort: { id: '${gatewayId}/frontendPorts/port-80' }
        }
      }
    ]
    redirectConfigurations: [
      {
        name: 'http-to-https'
        properties: {
          redirectType: 'Permanent'
          targetListener: { id: '${gatewayId}/httpListeners/https' }
          includePath: true
          includeQueryString: true
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'https-to-hub'
        properties: {
          priority: 100
          ruleType: 'Basic'
          httpListener: { id: '${gatewayId}/httpListeners/https' }
          backendAddressPool: { id: '${gatewayId}/backendAddressPools/hub-vm' }
          backendHttpSettings: { id: '${gatewayId}/backendHttpSettingsCollection/hub-3000' }
        }
      }
      {
        name: 'http-redirect'
        properties: {
          priority: 200
          ruleType: 'Basic'
          httpListener: { id: '${gatewayId}/httpListeners/http' }
          redirectConfiguration: { id: '${gatewayId}/redirectConfigurations/http-to-https' }
        }
      }
    ]
  }
}

@description('Point the hostname to this address with an A record.')
output gatewayPublicIpAddress string = gatewayIp.properties.ipAddress

@description('Virtual machine to connect to with Azure Bastion.')
output vmName string = vm.name

@description('Server name of the PostgreSQL flexible server.')
output postgresServerName string = postgres.properties.fullyQualifiedDomainName

@description('Key Vault that holds the Model Hub encryption key. Back it up with the database.')
output keyVaultName string = vault.name
