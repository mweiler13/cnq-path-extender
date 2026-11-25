# -----------------------------------------------------------------------------
# Hub
# -----------------------------------------------------------------------------

variable "hub_region" {
  description = "AWS region of the hub cluster. The control plane is deployed here."
  type        = string
}

variable "hub_deployment_unique_name" {
  description = "The hub's deployment_unique_name (output of its Terraform). Selects exactly one CNQ cluster by its Qumulo-Cluster tag."
  type        = string
}

variable "hub_admin_secret_arn" {
  description = "Secrets Manager ARN of the hub admin password (plain text, or JSON with a password key)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+$", var.hub_admin_secret_arn))
    error_message = "hub_admin_secret_arn must be a Secrets Manager secret ARN."
  }
}

# -----------------------------------------------------------------------------
# Control plane
# -----------------------------------------------------------------------------

variable "state_bucket" {
  description = "Existing S3 bucket, in hub_region, for Terraform state and the spoke code bundle."
  type        = string
}

variable "notification_email" {
  description = "Email address for success and failure notifications."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.notification_email))
    error_message = "notification_email must be an email address."
  }
}

variable "extra_tags" {
  description = "OPTIONAL: Tags added to every resource the control plane and its spokes create, e.g. tags your AWS organization requires. Set them in terraform.tfvars (not committed)."
  type        = map(string)
  default     = {}
}

variable "terraform_version" {
  description = "Terraform version CodeBuild uses to run the spoke stack."
  type        = string
  default     = "1.16.5"
}

# -----------------------------------------------------------------------------
# Spoke defaults
# -----------------------------------------------------------------------------

variable "default_instance_type" {
  description = "Spoke instance type when a launch doesn't specify one."
  type        = string
  default     = "i7i.8xlarge"
}

variable "default_node_count" {
  description = "Spoke node count when a launch doesn't specify one: 1, or 3 to 24."
  type        = number
  default     = 3

  validation {
    condition     = var.default_node_count == 1 || (var.default_node_count >= 3 && var.default_node_count <= 24 && floor(var.default_node_count) == var.default_node_count)
    error_message = "default_node_count must be 1, or a whole number from 3 to 24."
  }
}

variable "spoke_capacity_tb" {
  description = "Soft capacity limit for every spoke, in TB."
  type        = number
  default     = 100
}

variable "spoke_product_type" {
  description = "HOT or COLD for every spoke."
  type        = string
  default     = "HOT"

  validation {
    condition     = contains(["HOT", "COLD"], var.spoke_product_type)
    error_message = "spoke_product_type must be HOT or COLD."
  }
}

variable "portal_type" {
  description = "Portal access from the spoke: PORTAL_READ_WRITE or PORTAL_READ_ONLY."
  type        = string
  default     = "PORTAL_READ_WRITE"

  validation {
    condition     = contains(["PORTAL_READ_WRITE", "PORTAL_READ_ONLY"], var.portal_type)
    error_message = "portal_type must be PORTAL_READ_WRITE or PORTAL_READ_ONLY."
  }
}
