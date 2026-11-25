# -----------------------------------------------------------------------------
# Where the network stack's state lives (set by the buildspec)
# -----------------------------------------------------------------------------

variable "state_bucket" {
  description = "S3 bucket holding the network stack's state."
  type        = string
}

variable "state_region" {
  description = "Region of the state bucket."
  type        = string
}

variable "network_state_key" {
  description = "S3 key of the network stack's state: <hub>/spokes/<region>/network.tfstate."
  type        = string
}

# -----------------------------------------------------------------------------
# Launch inputs
# -----------------------------------------------------------------------------

variable "region" {
  description = "AWS region for the spoke."
  type        = string
}

# The same checks as the network stack, so this stack is safe to run on its own.
variable "instance_type" {
  description = "EC2 instance type for spoke nodes."
  type        = string

  validation {
    condition     = can(regex("^(m6idn|m6i|m7i|i3en|i4i|i7i|i7ie)\\.", var.instance_type))
    error_message = "instance_type must be in a CNQ-supported family: m6idn, m6i, m7i, i3en, i4i, i7i, i7ie."
  }
}

variable "node_count" {
  description = "Number of spoke nodes: 1, or 3 to 24."
  type        = number

  validation {
    condition     = var.node_count == 1 || (var.node_count >= 3 && var.node_count <= 24 && floor(var.node_count) == var.node_count)
    error_message = "node_count must be 1, or a whole number from 3 to 24."
  }
}

variable "cluster_version" {
  description = "Qumulo Core version, four-part (e.g. 7.10.1.1). Always the hub's version; never defaulted."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$", var.cluster_version))
    error_message = "cluster_version must be four-part, e.g. 7.10.1.1."
  }
}

# -----------------------------------------------------------------------------
# Hub facts and spoke defaults (set on the CodeBuild project)
# -----------------------------------------------------------------------------

variable "hub_name" {
  description = "Hub deployment unique name. Used for tagging."
  type        = string
}

# Must arrive as one whole list variable. Qumulo provider <= 1.4.22 fails with "Value
# Conversion Error" if allow_cidrs is a list built in config (e.g. [var.a, var.b]) while
# its elements are unknown, which they are during the validation pass of every plan.
# The buildspec sets it to [spoke VPC CIDR, hub VPC CIDR].
variable "allow_cidrs" {
  description = "CIDRs allowed into the spoke cluster: its own VPC, and the hub VPC (so the portal Lambda can reach its API)."
  type        = list(string)
}

variable "extra_tags" {
  description = "Tags added to every resource the cluster creates (from bootstrap's extra_tags)."
  type        = map(string)
  default     = {}
}

variable "soft_capacity_limit_tb" {
  description = "Soft capacity limit for the spoke cluster, in TB."
  type        = number
}

variable "cluster_product_type" {
  description = "HOT or COLD."
  type        = string

  validation {
    condition     = contains(["HOT", "COLD"], var.cluster_product_type)
    error_message = "cluster_product_type must be HOT or COLD."
  }
}

variable "deployment_name" {
  description = "OPTIONAL: CNQ deployment name (2-15 alphanumeric). Defaults to 'spk' + the region without dashes."
  type        = string
  default     = null

  validation {
    condition     = var.deployment_name == null || can(regex("^[a-zA-Z0-9]{2,15}$", var.deployment_name))
    error_message = "deployment_name must be 2-15 alphanumeric characters."
  }
}

variable "provider_timeout_minutes" {
  description = "Timeout for cluster create/update/delete."
  type        = number
  default     = 90
}
