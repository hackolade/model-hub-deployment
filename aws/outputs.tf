output "alb_dns_name" {
  description = "DNS name of the load balancer. Point the hostname to it with a CNAME record, unless route53_zone_id is set."
  value       = aws_lb.hub.dns_name
}

output "instance_id" {
  description = "ID of the instance, to connect with: aws ssm start-session --target <instance_id>"
  value       = aws_instance.hub.id
}

output "db_endpoint" {
  description = "Endpoint of the RDS database."
  value       = aws_db_instance.hub.address
}

output "encryption_key_secret_arn" {
  description = "Secrets Manager secret that holds the Model Hub encryption key. Back it up with the database."
  value       = aws_secretsmanager_secret.encryption_key.arn
}
