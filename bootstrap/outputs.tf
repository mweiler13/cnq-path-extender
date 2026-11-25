output "cdf_security_group_id" {
  description = "Add this to the hub's additional_security_group_ids (one-time, in-place change)."
  value       = aws_security_group.cdf.id
}

output "deploy_spoke_state_machine_arn" {
  description = "Start this to launch a spoke."
  value       = aws_sfn_state_machine.deploy.arn
}

output "destroy_spoke_state_machine_arn" {
  description = "Start this to remove a spoke."
  value       = aws_sfn_state_machine.destroy.arn
}

output "refresh_hub_state_machine_arn" {
  description = "Start this after the hub's nodes are replaced, to point every spoke portal at their new IPs."
  value       = aws_sfn_state_machine.refresh_hub.arn
}

output "hub" {
  description = "What bootstrap discovered about the hub."
  value = {
    deployment_unique_name = local.hub
    cluster_uuid           = local.hub_probe.cluster_uuid
    version                = local.hub_probe.version
    vpc_id                 = data.aws_vpc.hub.id
    vpc_cidr               = data.aws_vpc.hub.cidr_block
    node_ips               = local.hub_ips
    subnet_ids             = local.hub_subnet_ids
    route_table_ids        = local.hub_route_table_ids
  }
}

# JSON can't hold comments, so optional fields are marked in their placeholder values.
# Replace each <...> or delete its line (and the compute or pcs block as a whole when
# not wanted); leave no trailing comma before a closing brace.
output "launch_example" {
  description = "Launch command to fill in. Required: path (a directory on the hub), vpc_cidr (IPv4, /16 to /24, a range reserved for this spoke), and region (or replace it with \"placement\": {} to let the tool choose one; see the deployment guide). Placeholders left as is mean the default."
  value = join("", [
    "aws stepfunctions start-execution --region ${var.hub_region} --state-machine-arn ${aws_sfn_state_machine.deploy.arn} --input '{",
    "\"region\": \"<REQUIRED unless placement is given: spoke region>\", ",
    "\"path\": \"<REQUIRED: directory on the hub>\", ",
    "\"vpc_cidr\": \"<REQUIRED: spoke VPC CIDR>\", ",
    "\"instance_type\": \"<OPTIONAL: node instance type, default ${var.default_instance_type}>\", ",
    "\"node_count\": \"<OPTIONAL: 1 or 3-24, default ${var.default_node_count}>\", ",
    "\"availability_zone\": \"<OPTIONAL: AZ name, default chosen by the tool>\", ",
    "\"client_resources\": \"<OPTIONAL: true for a client security group and Session Manager role in the spoke VPC, for instances you launch yourself>\", ",
    "\"compute\": {",
    "\"instance_types\": [\"<OPTIONAL: compute instance types in order of preference, e.g. g5.48xlarge; no compute instance if left as is>\"], ",
    "\"ami_id\": \"<OPTIONAL: custom AMI in the spoke region (needs region); default Amazon Linux 2023, or the Deep Learning AMI for GPU types>\", ",
    "\"application\": \"<OPTIONAL: an application to set up, on the default or custom AMI, e.g. parabricks>\", ",
    "\"application_options\": {\"version\": \"<OPTIONAL: e.g. 4.8.0-1>\"}, ",
    "\"retry_minutes\": \"<OPTIONAL: default 5>\", ",
    "\"give_up_after_hours\": \"<OPTIONAL: default 24>\"",
    "}, ",
    "\"pcs\": {",
    "\"pipeline\": \"<OPTIONAL: xoos or sarek for a PCS (Slurm) cluster with that pipeline (needs region); no PCS cluster if this block is left as is>\", ",
    "\"compute_instance_type\": \"<OPTIONAL: default c6i.4xlarge>\", ",
    "\"max_nodes\": \"<OPTIONAL: default 4>\"",
    "}}'",
  ])
}
