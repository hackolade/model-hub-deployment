# Model Hub on an Azure virtual machine, with Bicep

This Bicep template builds the deployment of the guide [Model Hub on an Azure virtual machine](https://hackolade.com/help/ModelHubonanAzurevirtualmachine.html): read the guide first. The template makes the same choices, and the comments in `main.bicep` name the step of the guide that each part follows.

**Before you start**, the Hackolade Helpdesk must have registered your hostname, as described in [Model Hub prerequisites](https://hackolade.com/help/ModelHubprerequisites.html). The license works only on that hostname, over HTTPS. This README uses `hck.example.com`; replace it with yours.

## What it creates

- A virtual network with `appgw-subnet`, `vm-subnet` behind a NAT gateway, and `db-subnet` delegated to PostgreSQL flexible servers.
- Network security groups: on `appgw-subnet`, 443 and 80 from `allowedSourceAddressPrefixes`, and 65200-65535 from `GatewayManager`; on `vm-subnet`, 3000 from `appgw-subnet`.
- An Azure Database for PostgreSQL 17 flexible server with private access, and its private DNS zone.
- An Ubuntu 24.04 virtual machine in `vm-subnet`, without a public IP address, with a 64 GiB disk and SSH key login for Azure Bastion.
- A Key Vault for the secrets of the Model Hub, and a managed identity that lets the virtual machine read and write them.
- An Application Gateway Standard v2 with a public IP address: HTTPS on port 443 with your Key Vault certificate, to port 3000 of the virtual machine with health probe `/ready`, and HTTP on port 80 redirected to HTTPS.

At first boot, [cloud-init.sh](cloud-init.sh) does steps 4 to 6 of the guide: it installs Docker, creates the `hck_hub` user and database, writes `/opt/model-hub` with its `.env`, secrets and `docker-compose.yml`, and starts the Model Hub.

The secrets are never written in the template or its parameters:

- The PostgreSQL administrator password is generated at each deployment and stored in Key Vault, where the virtual machine reads it once.
- The `hck_hub` password and the encryption key are generated on the virtual machine with `openssl rand`, and stored in Key Vault. A new virtual machine reuses them.

**Cost**: about USD 450 per month in West Europe, mostly the Application Gateway (190), the virtual machine (165), the database (60) and the NAT gateway (35), plus data transfer.

## Parameters

| Parameter | Default | Description |
| --- | --- | --- |
| `modelHubVersion` | (required) | Tag of [hackolade/model-hub](https://hub.docker.com/r/hackolade/model-hub/tags) installed at first boot |
| `certificateSecretId` | (required) | Versionless secret ID of the certificate of the hostname in Key Vault |
| `gatewayIdentityId` | (required) | Resource ID of a user-assigned identity with the Key Vault Secrets User role on the vault of the certificate |
| `adminSshPublicKey` | (required) | SSH public key to log in to the virtual machine through Azure Bastion |
| `allowedSourceAddressPrefixes` | `["0.0.0.0/0"]` | IP ranges allowed to reach the Application Gateway |
| `adminUsername` | `azureuser` | Login of the virtual machine administrator |
| `vmSize` | `Standard_D4s_v5` | Virtual machine size, at least 4 vCPUs |
| `postgresSku` | `Standard_B2ms`, Burstable | Compute of the flexible server |

## Deploy

You need the Azure CLI, and rights to create the resources above and role assignments in the resource group (Owner, or Contributor plus Role Based Access Control Administrator).

First, prepare the certificate as in step 7 of the guide: import the PFX file of `hck.example.com` into a Key Vault as a certificate. Then create the resource group, and an identity that the Application Gateway uses to read the certificate:

```bash
az group create --name rg-model-hub --location westeurope
az identity create --resource-group rg-model-hub --name id-hub-appgw
az role assignment create --role "Key Vault Secrets User" \
  --assignee-object-id "$(az identity show --resource-group rg-model-hub --name id-hub-appgw --query principalId --output tsv)" \
  --assignee-principal-type ServicePrincipal \
  --scope "$(az keyvault show --name <certificate-vault> --query id --output tsv)"
```

Deploy the template, with the secret ID of the certificate without its version, so that the gateway picks up renewed certificates:

```bash
az deployment group create --resource-group rg-model-hub --template-file main.bicep --parameters \
  modelHubVersion=<model-hub-version> \
  certificateSecretId=https://<certificate-vault>.vault.azure.net/secrets/<certificate-name> \
  gatewayIdentityId="$(az identity show --resource-group rg-model-hub --name id-hub-appgw --query id --output tsv)" \
  adminSshPublicKey="$(cat ~/.ssh/id_ed25519.pub)" \
  allowedSourceAddressPrefixes='["203.0.113.0/24"]'
```

Then create an A record from `hck.example.com` to the `gatewayPublicIpAddress` output.

The first boot takes a few minutes. To follow it, open the virtual machine in the Azure portal, click **Connect > Connect via Bastion**, log in with `azureuser` and your SSH private key, and read its log:

```bash
sudo tail -f /var/log/cloud-init-output.log
```

When `curl -f http://localhost:3000/ready` succeeds on the virtual machine, open `https://hck.example.com` and continue with the [Model Hub configuration](https://hackolade.com/help/ModelHubconfiguration.html).

## Keep it safe and up to date

- Back up the encryption key, the `model-hub-encryption-key` secret of the vault in the `keyVaultName` output, with the database: without it, the Model Hub cannot read the configuration it stores there.
- The virtual machine reads `modelHubVersion` only at first boot. To upgrade, follow [Upgrade to new Model Hub version](https://hackolade.com/help/Installandstarttheserver.html#8-upgrade-to-new-model-hub-version) in `/opt/model-hub` on the virtual machine.

## Destroy

```bash
az group delete --name rg-model-hub
```

This deletes the database with its backups. The Key Vault, with the encryption key, stays recoverable for 90 days. To delete it for good, or to deploy again in a resource group of the same name, purge it:

```bash
az keyvault purge --name <keyVaultName>
```
