resource "aws_sns_topic" "notify" {
  name = "cnq-path-extender-${local.hub}"
}

# AWS emails a confirmation link; notifications start once it's clicked.
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.notify.arn
  protocol  = "email"
  endpoint  = var.notification_email
}
