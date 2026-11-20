# Model Hub on Amazon EC2, as described in
# https://hackolade.com/help/ModelHubonAmazonEC2.html
# Comments give the step of the guide that each part follows.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs                 = slice(data.aws_availability_zones.available.names, 0, 2)
  request_certificate = var.certificate_arn == ""
  certificate_arn     = local.request_certificate ? aws_acm_certificate_validation.hub[0].certificate_arn : var.certificate_arn
  db_master_username  = "hubadmin"
}

# Step 1: VPC with public and private subnets in two Availability Zones,
# and a NAT gateway for the outbound traffic of the instance.

resource "aws_vpc" "hub" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true

  tags = { Name = "hub-vpc" }
}

resource "aws_internet_gateway" "hub" {
  vpc_id = aws_vpc.hub.id
}

resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.hub.id
  availability_zone = local.azs[count.index]
  cidr_block        = "10.0.${count.index}.0/24"

  tags = { Name = "hub-public-${local.azs[count.index]}" }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.hub.id
  availability_zone = local.azs[count.index]
  cidr_block        = "10.0.${count.index + 10}.0/24"

  tags = { Name = "hub-private-${local.azs[count.index]}" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "hub" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  depends_on = [aws_internet_gateway.hub]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.hub.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.hub.id
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.hub.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.hub.id
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Step 2: security groups, each one open only to the previous one in the chain.

resource "aws_security_group" "alb" {
  name        = "hub-alb"
  description = "Model Hub load balancer"
  vpc_id      = aws_vpc.hub.id

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  ingress {
    description = "HTTP, redirected to HTTPS"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ec2" {
  name        = "hub-ec2"
  description = "Model Hub instance"
  vpc_id      = aws_vpc.hub.id

  ingress {
    description     = "Model Hub, from the load balancer"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db" {
  name        = "hub-db"
  description = "Model Hub database"
  vpc_id      = aws_vpc.hub.id

  ingress {
    description     = "PostgreSQL, from the instance"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Secrets: generated here and kept in Secrets Manager, where the instance reads
# them at first boot. Letters and digits only, so they need no quoting in SQL or shell.

resource "random_password" "db_master" {
  length  = 32
  special = false
}

resource "random_password" "db_hck_hub" {
  length  = 32
  special = false
}

# 32 random bytes, used as 64 hex characters: the same as `openssl rand -hex 32`.
resource "random_bytes" "encryption_key" {
  length = 32
}

resource "aws_secretsmanager_secret" "db_master_password" {
  name_prefix = "model-hub/db-master-password-"
}

resource "aws_secretsmanager_secret_version" "db_master_password" {
  secret_id     = aws_secretsmanager_secret.db_master_password.id
  secret_string = random_password.db_master.result
}

resource "aws_secretsmanager_secret" "db_password" {
  name_prefix = "model-hub/db-password-"
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = random_password.db_hck_hub.result
}

# Without this key, the Model Hub cannot read the configuration it stores in the database.
resource "aws_secretsmanager_secret" "encryption_key" {
  name_prefix = "model-hub/encryption-key-"
}

resource "aws_secretsmanager_secret_version" "encryption_key" {
  secret_id     = aws_secretsmanager_secret.encryption_key.id
  secret_string = random_bytes.encryption_key.hex
}

# Step 3: RDS for PostgreSQL in the private subnets.

resource "aws_db_subnet_group" "hub" {
  name       = "hub-db"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_instance" "hub" {
  identifier              = "hub-db"
  engine                  = "postgres"
  engine_version          = "17"
  instance_class          = var.db_instance_class
  allocated_storage       = 20
  storage_type            = "gp3"
  storage_encrypted       = true
  username                = local.db_master_username
  password                = random_password.db_master.result
  db_subnet_group_name    = aws_db_subnet_group.hub.name
  vpc_security_group_ids  = [aws_security_group.db.id]
  publicly_accessible     = false
  backup_retention_period = 7
  # `terraform destroy` deletes the database without a final snapshot: see the README.
  skip_final_snapshot = true
}

# Step 4: the instance, in a private subnet, reached with Session Manager.

resource "aws_iam_role" "ec2" {
  name = "hub-ec2"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "read_secrets" {
  name = "read-model-hub-secrets"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "secretsmanager:GetSecretValue"
      Resource = [
        aws_secretsmanager_secret.db_master_password.arn,
        aws_secretsmanager_secret.db_password.arn,
        aws_secretsmanager_secret.encryption_key.arn,
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "hub-ec2"
  role = aws_iam_role.ec2.name
}

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_instance" "hub" {
  ami                    = data.aws_ssm_parameter.ubuntu.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private[0].id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  metadata_options {
    http_tokens = "required"
    # Keeps the containers from reading the instance role's credentials.
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
    encrypted   = true
  }

  # Steps 4 to 6 of the guide: install Docker, create the database user, start the Model Hub.
  user_data = join("\n", [
    "#!/bin/bash",
    "AWS_REGION='${var.region}'",
    "MODEL_HUB_VERSION='${var.model_hub_version}'",
    "DB_HOST='${aws_db_instance.hub.address}'",
    "DB_MASTER_USERNAME='${local.db_master_username}'",
    "DB_MASTER_PASSWORD_SECRET='${aws_secretsmanager_secret.db_master_password.arn}'",
    "DB_PASSWORD_SECRET='${aws_secretsmanager_secret.db_password.arn}'",
    "ENCRYPTION_KEY_SECRET='${aws_secretsmanager_secret.encryption_key.arn}'",
    file("${path.module}/user-data.sh"),
  ])

  tags = { Name = "hub-ec2" }

  lifecycle {
    # User data runs only at first boot, and a newer Ubuntu image must not replace the instance.
    # Upgrade the Model Hub on the instance, as described in the README.
    ignore_changes = [ami, user_data]
  }

  # The first boot needs the NAT gateway and the secrets.
  depends_on = [
    aws_route_table_association.private,
    aws_secretsmanager_secret_version.db_master_password,
    aws_secretsmanager_secret_version.db_password,
    aws_secretsmanager_secret_version.encryption_key,
  ]
}

# Step 7: the certificate, either given or requested from ACM and validated in Route 53.

resource "aws_acm_certificate" "hub" {
  count             = local.request_certificate ? 1 : 0
  domain_name       = var.hostname
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "certificate_validation" {
  count           = local.request_certificate ? 1 : 0
  zone_id         = var.route53_zone_id
  name            = tolist(aws_acm_certificate.hub[0].domain_validation_options)[0].resource_record_name
  type            = tolist(aws_acm_certificate.hub[0].domain_validation_options)[0].resource_record_type
  records         = [tolist(aws_acm_certificate.hub[0].domain_validation_options)[0].resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "hub" {
  count                   = local.request_certificate ? 1 : 0
  certificate_arn         = aws_acm_certificate.hub[0].arn
  validation_record_fqdns = [aws_route53_record.certificate_validation[0].fqdn]
}

# Step 8: the internet-facing load balancer, the only way in.

resource "aws_lb_target_group" "hub" {
  name     = "hub-tg"
  port     = 3000
  protocol = "HTTP"
  vpc_id   = aws_vpc.hub.id

  health_check {
    path    = "/ready"
    matcher = "200"
  }
}

resource "aws_lb_target_group_attachment" "hub" {
  target_group_arn = aws_lb_target_group.hub.arn
  target_id        = aws_instance.hub.id
  port             = 3000
}

resource "aws_lb" "hub" {
  name                       = "hub-alb"
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [aws_security_group.alb.id]
  subnets                    = aws_subnet.public[*].id
  drop_invalid_header_fields = true
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.hub.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.hub.arn
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.hub.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      protocol    = "HTTPS"
      port        = "443"
      status_code = "HTTP_301"
    }
  }
}

# Step 9: the hostname, when its zone is in Route 53. Otherwise, create a CNAME to the alb_dns_name output.

resource "aws_route53_record" "hub" {
  count   = var.route53_zone_id == "" ? 0 : 1
  zone_id = var.route53_zone_id
  name    = var.hostname
  type    = "A"

  alias {
    name                   = aws_lb.hub.dns_name
    zone_id                = aws_lb.hub.zone_id
    evaluate_target_health = false
  }
}
