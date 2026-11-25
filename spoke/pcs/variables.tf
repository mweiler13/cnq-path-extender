# -----------------------------------------------------------------------------
# Where the other stacks' state lives (set by the buildspec)
# -----------------------------------------------------------------------------

variable "state_bucket" {
  description = "S3 bucket holding the spoke's state."
  type        = string
}

variable "state_region" {
  description = "Region of the state bucket."
  type        = string
}

variable "network_state_key" {
  description = "S3 key of the network stack's state."
  type        = string
}

variable "cluster_state_key" {
  description = "S3 key of the cluster stack's state (the spoke's node IPs, for the NFS mount)."
  type        = string
}

# -----------------------------------------------------------------------------
# Launch inputs (region is always set by the buildspec; the rest have defaults).
# -----------------------------------------------------------------------------

variable "region" {
  description = "AWS region of the spoke."
  type        = string
}

variable "path" {
  description = "The portal path; its data is at <mount root><path> on every node."
  type        = string
  default     = ""
}

# The "pcs" launch input, as checked by the Lambda (extra attributes are dropped).
variable "pcs" {
  description = "PCS settings: pipeline, pipeline_options, instance types, max_nodes, root_volume_gb, idle_minutes."
  type = object({
    pipeline              = optional(string, "")
    pipeline_options      = optional(map(string), {})
    compute_instance_type = optional(string, "c6i.4xlarge")
    login_instance_type   = optional(string, "c6i.xlarge")
    max_nodes             = optional(number, 4)
    root_volume_gb        = optional(number, 100)
    # Idle compute nodes stop after this; longer than a pipeline's longest single task.
    idle_minutes = optional(number, 20)
  })
  default = {}

  validation {
    condition     = contains(["", "sarek", "xoos"], var.pcs.pipeline)
    error_message = "pcs.pipeline must be sarek, xoos, or empty (one script per pipeline in spoke/pcs/pipelines/)."
  }

  # The same limits the Lambda checks at launch.
  validation {
    condition     = var.pcs.max_nodes >= 1 && var.pcs.max_nodes <= 64
    error_message = "pcs.max_nodes must be 1 to 64."
  }

  validation {
    condition     = var.pcs.idle_minutes >= 1 && var.pcs.idle_minutes <= 1440
    error_message = "pcs.idle_minutes must be 1 to 1440."
  }

  validation {
    condition     = var.pcs.root_volume_gb >= 30 && var.pcs.root_volume_gb <= 16384
    error_message = "pcs.root_volume_gb must be 30 to 16384."
  }
}

# -----------------------------------------------------------------------------
# Fixed choices
# -----------------------------------------------------------------------------

variable "slurm_version" {
  description = "Slurm version for the PCS cluster; also picks the PCS sample AMI."
  type        = string
  default     = "25.11"
}

variable "nextflow_version" {
  description = "Nextflow installed on the shared storage (the Xoos pipeline, xoosnf, needs 25.10.4 or later)."
  type        = string
  default     = "25.10.4"
}

variable "apptainer_version" {
  description = "Apptainer on every node (1.4 or later: 1.3.x images don't mount on the Amazon Linux 2023 kernel)."
  type        = string
  default     = "1.4.1"
}

# -----------------------------------------------------------------------------
# Local mode (spoke/local/): the PCS cluster in the hub's VPC, mounting the hub
# -----------------------------------------------------------------------------

variable "site" {
  description = "Local mode: \"local\", used in names and the spoke-region tag instead of the region."
  type        = string
  default     = ""
}

variable "network" {
  description = "Local mode: the VPC, subnet and NFS hosts to use instead of the spoke's state."
  type = object({
    vpc_id    = string
    subnet_id = string
    nfs_hosts = list(string)
  })
  default = null
}

# -----------------------------------------------------------------------------
# Hub facts (set on the CodeBuild project)
# -----------------------------------------------------------------------------

variable "hub_name" {
  description = "Hub deployment unique name. Used for naming and tagging."
  type        = string
}

variable "extra_tags" {
  description = "Tags added to every resource (from bootstrap's extra_tags)."
  type        = map(string)
  default     = {}
}
