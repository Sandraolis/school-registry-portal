terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

locals {
  entities = {
    student = {
      table_name    = "school-registry-students"
      response_key  = "StudentData"
      unique_fields = "nationalId,studentNumber"
      label         = "Student"
    }
    teacher = {
      table_name    = "school-registry-teachers"
      response_key  = "TeacherData"
      unique_fields = "nationalId,teacherNumber"
      label         = "Teacher"
    }
  }

  routes = {
    "GET /student"  = "student"
    "POST /student" = "student"
    "GET /teacher"  = "teacher"
    "POST /teacher" = "teacher"
  }
}

# ---------- DynamoDB ----------
resource "aws_dynamodb_table" "this" {
  for_each     = local.entities
  name         = each.value.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
}

# ---------- Lambda code package ----------
data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/../backend/handler.mjs"
  output_path = "${path.module}/handler.zip"
}

# ---------- IAM (least privilege) ----------
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  for_each           = local.entities
  name               = "school-registry-${each.key}-lambda"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "logs" {
  for_each   = local.entities
  role       = aws_iam_role.lambda[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "table_access" {
  for_each = local.entities
  name     = "table-access"
  role     = aws_iam_role.lambda[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:Scan", "dynamodb:PutItem"]
      Resource = aws_dynamodb_table.this[each.key].arn
    }]
  })
}

# ---------- Lambda functions ----------
resource "aws_lambda_function" "this" {
  for_each         = local.entities
  function_name    = "school-registry-${each.key}"
  role             = aws_iam_role.lambda[each.key].arn
  runtime          = "nodejs22.x"
  handler          = "handler.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  environment {
    variables = {
      TABLE_NAME    = aws_dynamodb_table.this[each.key].name
      RESPONSE_KEY  = each.value.response_key
      UNIQUE_FIELDS = each.value.unique_fields
      ENTITY_LABEL  = each.value.label
    }
  }
}

# ---------- API Gateway (HTTP API) ----------
resource "aws_apigatewayv2_api" "this" {
  name          = "school-registry-api-tf"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["content-type"]
  }
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_apigatewayv2_integration" "this" {
  for_each               = local.entities
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.this[each.key].invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "this" {
  for_each  = local.routes
  api_id    = aws_apigatewayv2_api.this.id
  route_key = each.key
  target    = "integrations/${aws_apigatewayv2_integration.this[each.value].id}"
}

resource "aws_lambda_permission" "apigw" {
  for_each      = local.entities
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this[each.key].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}

output "api_url" {
  value = aws_apigatewayv2_api.this.api_endpoint
}