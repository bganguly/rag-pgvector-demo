data "aws_caller_identity" "current" {}

resource "aws_cloudwatch_log_group" "main" {
  name              = "/ecs/${var.name_prefix}"
  retention_in_days = 7
  tags              = { Name = "${var.name_prefix}-logs" }
}
