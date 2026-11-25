output "cluster_id" {
  description = "PCS cluster ID."
  value       = awscc_pcs_cluster.this.cluster_id
}

output "cluster_name" {
  description = "PCS cluster name."
  value       = awscc_pcs_cluster.this.name
}

output "login_node_group_id" {
  description = "Login node group; its instance is tagged cnq-path-extender:role = pcs-login."
  value       = awscc_pcs_compute_node_group.node["login"].compute_node_group_id
}

output "node_cpus" {
  description = "CPUs Slurm sees per compute node (physical cores)."
  value       = local.node_cpus
}

output "pipeline" {
  description = "Pipeline set up on the login node, if any."
  value       = var.pcs.pipeline
}
