output "cluster_uuid" {
  description = "Spoke cluster UUID."
  value       = qumulo_filesystem_aws.spoke.cluster_uuid
}

output "deployment_unique_name" {
  description = "Spoke deployment unique name."
  value       = qumulo_filesystem_aws.spoke.deployment_unique_name
}

output "primary_ips" {
  description = "Per-node primary IPs."
  value       = qumulo_filesystem_aws.spoke.primary_ips
}

output "api_endpoint" {
  description = "Spoke REST API base URL, used by the portal Lambda."
  value       = "https://${qumulo_filesystem_aws.spoke.primary_ips[0]}:8000"
}
