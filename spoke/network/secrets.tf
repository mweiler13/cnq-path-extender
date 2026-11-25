# Spoke admin password and EC2 key pair, generated here and stored in Secrets Manager.
# These values are also in the Terraform state file, so the state bucket must stay
# encrypted and access-restricted.
#
# recovery_window_in_days = 0 deletes secrets immediately on destroy, so a spoke can be
# re-created in the same region right away (spokes are transient).

resource "random_password" "admin" {
  length           = 24
  special          = true
  override_special = "!#%+-=_"
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
}

resource "aws_secretsmanager_secret" "admin" {
  name                    = "cnq-path-extender/${var.hub_name}/${var.region}/admin"
  description             = "Admin credentials for the ${var.region} spoke of hub ${var.hub_name}"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "admin" {
  secret_id = aws_secretsmanager_secret.admin.id
  secret_string = jsonencode({
    username = "admin"
    password = random_password.admin.result
  })
}

# Key pairs are per-region, so each spoke gets its own.
resource "tls_private_key" "node" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "node" {
  key_name   = local.name
  public_key = tls_private_key.node.public_key_openssh
}

resource "aws_secretsmanager_secret" "ssh_key" {
  name                    = "cnq-path-extender/${var.hub_name}/${var.region}/ssh-key"
  description             = "SSH private key for nodes in the ${var.region} spoke of hub ${var.hub_name}"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "ssh_key" {
  secret_id     = aws_secretsmanager_secret.ssh_key.id
  secret_string = tls_private_key.node.private_key_openssh
}
