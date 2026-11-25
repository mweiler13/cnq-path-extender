# -----------------------------------------------------------------------------
# Launch inputs (from the Step Functions execution input)
# -----------------------------------------------------------------------------

variable "region" {
  description = "AWS region for the new spoke."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR for the new spoke VPC. Must not overlap the hub VPC or any other spoke."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && tonumber(split("/", var.vpc_cidr)[1]) >= 16 && tonumber(split("/", var.vpc_cidr)[1]) <= 24
    error_message = "vpc_cidr must be a valid IPv4 CIDR between /16 and /24."
  }
}

variable "instance_type" {
  description = "EC2 instance type for spoke nodes. Used here to pick an AZ that offers it."
  type        = string

  validation {
    condition     = can(regex("^(m6idn|m6i|m7i|i3en|i4i|i7i|i7ie)\\.", var.instance_type))
    error_message = "instance_type must be in a CNQ-supported family: m6idn, m6i, m7i, i3en, i4i, i7i, i7ie."
  }
}

variable "client_resources" {
  description = "Create a security group and Session Manager instance role for clients in the spoke VPC (the compute instance, or instances launched by hand)."
  type        = bool
  default     = false
}

variable "availability_zone" {
  description = "AZ for the spoke. Empty: the first standard AZ that offers instance_type."
  type        = string
  default     = ""
}

# Not used by this stack's resources. Recorded in the "launch" output so destroy-spoke
# can pass the same values back to both stacks.
variable "node_count" {
  description = "Number of spoke nodes: 1, or 3 to 24."
  type        = number

  validation {
    condition     = var.node_count == 1 || (var.node_count >= 3 && var.node_count <= 24 && floor(var.node_count) == var.node_count)
    error_message = "node_count must be 1, or a whole number from 3 to 24."
  }
}

variable "cluster_version" {
  description = "Qumulo Core version, four-part (e.g. 7.10.1.1). Always the hub's version."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$", var.cluster_version))
    error_message = "cluster_version must be four-part, e.g. 7.10.1.1."
  }
}

# -----------------------------------------------------------------------------
# Hub facts (discovered at bootstrap, set on the CodeBuild project)
# -----------------------------------------------------------------------------

variable "hub_name" {
  description = "Hub deployment unique name. Used for naming and tagging."
  type        = string
}

variable "hub_region" {
  description = "AWS region of the hub cluster."
  type        = string
}

variable "hub_vpc_id" {
  description = "Hub VPC ID."
  type        = string
}

variable "hub_vpc_cidr" {
  description = "Hub VPC CIDR."
  type        = string
}

variable "hub_route_table_ids" {
  description = "Hub route tables that need a route to the spoke CIDR (those serving the hub cluster's subnets)."
  type        = list(string)
}

variable "extra_tags" {
  description = "Tags added to every resource (from bootstrap's extra_tags)."
  type        = map(string)
  default     = {}
}

variable "cdf_security_group_id" {
  description = "Control plane's CDF security group in the hub VPC. The spoke adds an inbound 3713 rule to it."
  type        = string
}
