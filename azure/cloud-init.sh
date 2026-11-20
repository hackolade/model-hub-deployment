# Runs once, at the first boot of the virtual machine, as root. main.bicep prepends the variables it uses.
# Output: /var/log/cloud-init-output.log
set -euo pipefail

# Step 4: Docker Engine and the Compose plugin, from Docker's repository
# (https://docs.docker.com/engine/install/ubuntu/), and jq to read Key Vault answers.
apt-get update
apt-get install -y ca-certificates curl jq
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Key Vault access with the managed identity of the virtual machine.
vault_token() {
  curl -fsS -H Metadata:true \
    "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net&client_id=$IDENTITY_CLIENT_ID" \
    | jq -r .access_token
}

get_secret() {
  curl -fsS -H "Authorization: Bearer $(vault_token)" "${VAULT_URI}secrets/$1?api-version=7.4" | jq -r .value
}

put_secret() {
  jq -n --arg value "$2" '{value: $value}' \
    | curl -fsS -X PUT -H "Authorization: Bearer $(vault_token)" -H "Content-Type: application/json" \
      --data-binary @- "${VAULT_URI}secrets/$1?api-version=7.4" > /dev/null
}

# The role assignment on Key Vault can take a few minutes to apply.
DB_ADMIN_PASSWORD=""
for attempt in $(seq 30); do
  DB_ADMIN_PASSWORD="$(get_secret postgres-admin-password)" && break
  echo "Waiting for access to Key Vault ($attempt/30)"
  sleep 20
done
[ -n "$DB_ADMIN_PASSWORD" ] || { echo "Cannot read Key Vault $VAULT_URI" >&2; exit 1; }

# The hck_hub password and the encryption key are generated once, and kept in Key Vault.
# A new virtual machine reuses them: a new key could not read the data already in the database.
if ! DB_PASSWORD="$(get_secret model-hub-db-password)"; then
  DB_PASSWORD="$(openssl rand -hex 24)"
  put_secret model-hub-db-password "$DB_PASSWORD"
fi
if ! ENCRYPTION_KEY="$(get_secret model-hub-encryption-key)"; then
  ENCRYPTION_KEY="$(openssl rand -hex 32)"
  put_secret model-hub-encryption-key "$ENCRYPTION_KEY"
fi

# Step 5: the hck_hub user and its database, created with the administrator login.
# PGPASSWORD is passed by name, so that it does not show in the process list.
export PGPASSWORD="$DB_ADMIN_PASSWORD"
docker run --rm -i -e PGPASSWORD postgres:18-alpine \
  psql "host=$DB_HOST port=5432 dbname=postgres user=$DB_ADMIN_USERNAME sslmode=require" <<SQL
CREATE ROLE hck_hub WITH LOGIN PASSWORD '$DB_PASSWORD';
GRANT hck_hub TO CURRENT_USER;
CREATE DATABASE hck_hub OWNER hck_hub;
SQL
unset PGPASSWORD

# Step 6: the folder of the Model Hub, its secrets, and the Compose file.
mkdir -p /opt/model-hub/secrets
cd /opt/model-hub
printf '%s' "$DB_PASSWORD" > secrets/db_password
echo "$ENCRYPTION_KEY" > secrets/model_hub_encryption_key
chmod 700 secrets
chmod 644 secrets/*

echo "MODEL_HUB_VERSION=$MODEL_HUB_VERSION" > .env

cat > docker-compose.yml <<YAML
services:
  model-hub:
    image: hackolade/model-hub:\${MODEL_HUB_VERSION}
    deploy:
      restart_policy:
        condition: always
        delay: 5s
        window: 30s
    ports:
      - "3000:3000"
    environment:
      DB_TYPE: pg
      DB_CONNECTION: pg://$DB_HOST:5432/hck_hub?sslmode=require
      DB_USERNAME: hck_hub
      DB_PASSWORD_FILE: /run/secrets/db_password
      CURRENT_ENCRYPTION_KEY_FILE: /run/secrets/model_hub_encryption_key
    secrets:
      - db_password
      - model_hub_encryption_key
secrets:
  db_password:
    file: ./secrets/db_password
  model_hub_encryption_key:
    file: ./secrets/model_hub_encryption_key
YAML

docker compose up -d
