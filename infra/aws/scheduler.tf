resource "aws_iam_role" "scheduler_lambda" {
  name = "${var.name_prefix}-scheduler-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "scheduler_lambda" {
  name = "${var.name_prefix}-scheduler-lambda"
  role = aws_iam_role.scheduler_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.backend.arn
    }]
  })
}

resource "aws_scheduler_schedule" "keep_warm" {
  name = "${var.name_prefix}-keep-warm"

  flexible_time_window { mode = "OFF" }
  schedule_expression = "rate(5 minutes)"

  target {
    arn      = aws_lambda_function.backend.arn
    role_arn = aws_iam_role.scheduler_lambda.arn

    input = jsonencode({
      version        = "2.0"
      routeKey       = "GET /health"
      rawPath        = "/health"
      rawQueryString = ""
      cookies        = []
      headers        = { "content-type" = "application/json" }
      requestContext = {
        accountId    = "000000000000"
        apiId        = "keep-warm"
        domainName   = "keep-warm.internal"
        domainPrefix = "keep-warm"
        http = {
          method    = "GET"
          path      = "/health"
          protocol  = "HTTP/1.1"
          sourceIp  = "127.0.0.1"
          userAgent = "aws-scheduler/keep-warm"
        }
        requestId = "keep-warm"
        routeKey  = "GET /health"
        stage     = "$default"
        time      = "01/Jan/2024:00:00:00 +0000"
        timeEpoch = 1704067200000
      }
      isBase64Encoded = false
    })
  }
}
