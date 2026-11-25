# Read by the cluster stack (terraform_remote_state) and by the portal Lambda.

output "vpc_id" {
  description = "Spoke VPC ID."
  value       = aws_vpc.spoke.id
}

output "private_subnet_id" {
  description = "Subnet for the cluster nodes."
  value       = aws_subnet.private.id
}

output "availability_zone" {
  description = "AZ the spoke is placed in."
  value       = local.az
}

output "key_pair_name" {
  description = "EC2 key pair for spoke nodes."
  value       = aws_key_pair.node.key_name
}

output "admin_password" {
  description = "Generated spoke admin password (also in Secrets Manager)."
  value       = random_password.admin.result
  sensitive   = true
}

output "admin_secret_arn" {
  description = "Secrets Manager ARN holding the spoke admin credentials."
  value       = aws_secretsmanager_secret.admin.arn
}

output "ssh_key_secret_arn" {
  description = "Secrets Manager ARN holding the node SSH private key."
  value       = aws_secretsmanager_secret.ssh_key.arn
}

output "client_security_group_id" {
  description = "Security group for clients in the spoke VPC, such as the compute instance (null unless client_resources)."
  value       = one(aws_security_group.client[*].id)
}

output "client_instance_profile_name" {
  description = "Instance profile for clients in the spoke VPC, for Session Manager access (null unless client_resources)."
  value       = one(aws_iam_instance_profile.client[*].name)
}

output "peering_connection_id" {
  description = "Spoke-to-hub VPC peering connection ID."
  value       = aws_vpc_peering_connection.to_hub.id
}

# Launch inputs, read back by destroy-spoke (terraform destroy needs the same variables).
output "launch" {
  description = "Inputs this spoke was launched with."
  value = {
    vpc_cidr         = var.vpc_cidr
    instance_type    = var.instance_type
    node_count       = var.node_count
    cluster_version  = var.cluster_version
    client_resources = var.client_resources
  }
}
