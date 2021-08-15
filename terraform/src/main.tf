terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 3.48.0"
    }
    random = {
      source = "hashicorp/random"
      version = "~> 3.1.0"
    }
    archive = {
      source = "hashicorp/archive"
      version = "~> 2.2.0"
    }
  }

  required_version = "~> 1.0"
}

provider "aws" {
  region = var.aws_region
}

resource "random_pet" "lambda_bucket_name" {
  prefix = "error-helper"
  length = 4
}

resource "aws_s3_bucket" "lambda_bucket" {
  bucket = random_pet.lambda_bucket_name.id

  acl = "private"
  force_destroy = true
}

data "local_file" "dotenv" {
  filename = "${path.root}/../../.env"
}

data "local_file" "main" {
  filename = "${path.module}/../../main"
}


data "archive_file" "zip" {
  type = "zip"
  output_path = "main.zip"

//  source {
//    content = data.local_file.main.content
//    filename = "main"
//  }

  source {
    content = data.local_file.dotenv.content
    filename = ".env"
  }
}

resource "aws_s3_bucket_object" "lambda" {
  bucket = aws_s3_bucket.lambda_bucket.id

  key = "main.zip"
  source = data.archive_file.zip.output_path

  etag = filemd5(data.archive_file.zip.output_path)
}

resource "aws_lambda_function" "error-helper" {
  function_name = "error-helper"

  s3_bucket = aws_s3_bucket.lambda_bucket.id
  s3_key = aws_s3_bucket_object.lambda.key

  runtime = "go1.x"
  handler = "main"
  memory_size = 128

  source_code_hash = data.archive_file.zip.output_base64sha256

  role = aws_iam_role.lambda_exec.arn
}

resource "aws_cloudwatch_log_group" "error-helper" {
  name = "/aws/lambda/${aws_lambda_function.error-helper.function_name}"

  retention_in_days = 30
}

resource "aws_iam_role" "lambda_exec" {
  name = "serverless_lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid = ""
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_policy" {
  role = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_apigatewayv2_api" "lambda" {
  name = "serverless_lambda_gw"
  protocol_type = "HTTP"

  cors_configuration {
    allow_headers = ["Content-Type"]
    allow_methods = ["POST", "OPTIONS"]
    allow_origins = [
      "https://ttbkk.com",
      "https://www.ttbkk.com",
      "http://localhost:3000",
    ]
  }
}

resource "aws_apigatewayv2_stage" "lambda" {
  api_id = aws_apigatewayv2_api.lambda.id
  name = "serverless_lambda_stage"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gw.arn

    format = jsonencode({
      requestId = "$context.requestId"
      sourceIp = "$context.identity.sourceIp"
      requestTime = "$context.requestTime"
      protocol = "$context.protocol"
      httpMethod = "$context.httpMethod"
      resourcePath = "$context.resourcePath"
      routeKey = "$context.routeKey"
      status = "$context.status"
      responseLength = "$context.responseLength"
      integrationErrorMessage = "$context.integrationErrorMessage"
    })
  }
}

resource "aws_apigatewayv2_integration" "error-helper" {
  api_id = aws_apigatewayv2_api.lambda.id

  integration_uri = aws_lambda_function.error-helper.invoke_arn
  integration_type = "AWS_PROXY"
  integration_method = "POST"
}

resource "aws_apigatewayv2_route" "error-helper" {
  api_id = aws_apigatewayv2_api.lambda.id

  route_key = "POST /send"
  target = "integrations/${aws_apigatewayv2_integration.error-helper.id}"
}

resource "aws_cloudwatch_log_group" "api_gw" {
  name = "/aws/api_gw/${aws_apigatewayv2_api.lambda.name}"

  retention_in_days = 30
}

resource "aws_lambda_permission" "api_gw" {
  statement_id = "AllowExecutionFromAPIGateway"
  action = "lambda:InvokeFunction"
  function_name = aws_lambda_function.error-helper.function_name
  principal = "apigateway.amazonaws.com"

  source_arn = "${aws_apigatewayv2_api.lambda.execution_arn}/*/*"
}
