variable "region" {
  description = "AWS region to deploy to."
  type        = string
  default     = "eu-west-1"
}

variable "hostname" {
  description = "Hostname of the Model Hub, as registered with the Hackolade Helpdesk."
  type        = string
  default     = "hck.example.com"
}

variable "model_hub_version" {
  description = "Tag of the hackolade/model-hub image on Docker Hub, installed at first boot."
  type        = string
}

variable "allowed_cidrs" {
  description = "IP ranges allowed to reach the load balancer on ports 443 and 80."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "certificate_arn" {
  description = "ARN of an issued ACM certificate for the hostname. Leave empty to request one, validated through route53_zone_id."
  type        = string
  default     = ""

  validation {
    condition     = var.certificate_arn != "" || var.route53_zone_id != ""
    error_message = "Set certificate_arn, or route53_zone_id so that the stack can request and validate a certificate."
  }
}

variable "route53_zone_id" {
  description = "Route 53 public hosted zone of the hostname. When set, the stack creates the certificate validation record and the hostname's alias record."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "EC2 instance type, at least 4 vCPUs."
  type        = string
  default     = "m7i.xlarge"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.medium"
}
