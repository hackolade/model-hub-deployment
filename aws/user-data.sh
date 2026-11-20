# Runs once, at the first boot of the instance, as root. main.tf prepends the variables it uses.
# Output: /var/log/cloud-init-output.log
set -euo pipefail

# Step 4: Docker Engine and the Compose plugin, from Docker's repository
# (https://docs.docker.com/engine/install/ubuntu/), and the AWS CLI to read the secrets.
apt-get update
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
snap install aws-cli --classic

secret() {
  aws secretsmanager get-secret-value --region "$AWS_REGION" --secret-id "$1" --query SecretString --output text
}

DB_PASSWORD="$(secret "$DB_PASSWORD_SECRET")"

# Step 5: the hck_hub user and its database, created with the master user.
# PGPASSWORD is passed by name, so that it does not show in the process list.
PGPASSWORD="$(secret "$DB_MASTER_PASSWORD_SECRET")"
export PGPASSWORD
docker run --rm -i -e PGPASSWORD postgres:18-alpine \
  psql "host=$DB_HOST port=5432 dbname=postgres user=$DB_MASTER_USERNAME sslmode=require" <<SQL
CREATE ROLE hck_hub WITH LOGIN PASSWORD '$DB_PASSWORD';
GRANT hck_hub TO CURRENT_USER;
CREATE DATABASE hck_hub OWNER hck_hub;
SQL
unset PGPASSWORD

# Step 6: the folder of the Model Hub, its secrets, the RDS certificate bundle, and the Compose file.
mkdir -p /opt/model-hub/secrets
cd /opt/model-hub
printf '%s' "$DB_PASSWORD" > secrets/db_password
secret "$ENCRYPTION_KEY_SECRET" > secrets/model_hub_encryption_key
chmod 700 secrets
chmod 644 secrets/*
curl -fsSL -o rds-ca-bundle.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem

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
      NODE_EXTRA_CA_CERTS: /etc/ssl/rds-ca-bundle.pem
    volumes:
      - ./rds-ca-bundle.pem:/etc/ssl/rds-ca-bundle.pem:ro
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
