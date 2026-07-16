resource "aws_lambda_function" "backend" {
  function_name = "${var.name_prefix}-backend"
  role          = aws_iam_role.lambda.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.backend.repository_url}:latest"
  timeout       = 900
  memory_size   = 1024

  environment {
    variables = {
      CORS_ORIGINS = "*"
    }
  }

  tags = { Name = "${var.name_prefix}-backend" }

  lifecycle { ignore_changes = [image_uri, environment] }
}

resource "aws_lambda_function_url" "backend" {
  function_name      = aws_lambda_function.backend.function_name
  authorization_type = "NONE"

  cors {
    allow_credentials = false
    allow_origins     = ["*"]
    allow_methods     = ["*"]
    allow_headers     = ["content-type", "authorization", "x-provider"]
    max_age           = 86400
  }
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name_prefix}-backend"
  retention_in_days = 7
  tags              = { Name = "${var.name_prefix}-lambda-logs" }
}
