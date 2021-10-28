provider "aws" {
}

resource "random_id" "id" {
  byte_length = 8
}

resource "aws_iam_role" "appsync" {
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "appsync.amazonaws.com"
      },
      "Effect": "Allow"
    }
  ]
}
EOF
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "/tmp/${random_id.id.hex}-lambda.zip"
  source {
    content  = <<EOF
exports.handler = async (event, context) => {
	const {arguments, prev, stash, identity, source} = event;
	return JSON.stringify({arguments, prev, stash, identity, source});
};
EOF
    filename = "index.js"
  }
}

resource "aws_lambda_function" "function" {
  function_name = "function-${random_id.id.hex}"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  handler = "index.handler"
  runtime = "nodejs14.x"
  role    = aws_iam_role.lambda_exec.arn
}

resource "aws_cloudwatch_log_group" "loggroup" {
  name              = "/aws/lambda/${aws_lambda_function.function.function_name}"
  retention_in_days = 14
}

data "aws_iam_policy_document" "lambda_exec_policy" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = [
      "arn:aws:logs:*:*:*"
    ]
  }
}

resource "aws_iam_role_policy" "lambda_exec_policy" {
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.lambda_exec_policy.json
}

resource "aws_iam_role" "lambda_exec" {
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
	{
	  "Action": "sts:AssumeRole",
	  "Principal": {
		"Service": "lambda.amazonaws.com"
	  },
	  "Effect": "Allow"
	}
  ]
}
EOF
}

data "aws_iam_policy_document" "appsync" {
  statement {
    actions = [
      "lambda:InvokeFunction",
    ]
    resources = [
			aws_lambda_function.function.arn,
    ]
  }
}

resource "aws_iam_role_policy" "appsync" {
  role   = aws_iam_role.appsync.id
  policy = data.aws_iam_policy_document.appsync.json
}

resource "aws_appsync_graphql_api" "appsync" {
  name                = "appsync_test"
  schema              = file("schema.graphql")
  authentication_type = "AWS_IAM"
}

resource "aws_appsync_datasource" "lambda" {
  api_id           = aws_appsync_graphql_api.appsync.id
  name             = "lambda"
  service_role_arn = aws_iam_role.appsync.arn
  type             = "AWS_LAMBDA"
	lambda_config {
		function_arn = aws_lambda_function.function.arn
	}
}

# resolvers
resource "aws_appsync_resolver" "Query_item" {
  api_id      = aws_appsync_graphql_api.appsync.id
  type        = "Query"
  field       = "item"
  data_source = aws_appsync_datasource.lambda.name
  response_template = <<EOF
{
	"field1": "test",
	"field2": "another test",
	"arguments": $util.toJson($ctx.arguments)
}
EOF
}

resource "aws_appsync_resolver" "Query_test" {
  api_id      = aws_appsync_graphql_api.appsync.id
  type        = "Query"
  field       = "test"
  data_source = aws_appsync_datasource.lambda.name
  response_template = <<EOF
"test response"
EOF
}

resource "aws_appsync_resolver" "Item_field1" {
  api_id      = aws_appsync_graphql_api.appsync.id
  type        = "Item"
  field       = "field1"
  data_source = aws_appsync_datasource.lambda.name
}
resource "aws_appsync_resolver" "Item_field2" {
  api_id      = aws_appsync_graphql_api.appsync.id
  type        = "Item"
  field       = "field2"
  data_source = aws_appsync_datasource.lambda.name
}

resource "aws_appsync_function" "func1" {
  api_id                   = aws_appsync_graphql_api.appsync.id
  data_source              = aws_appsync_datasource.lambda.name
  name                     = "func1"
  request_mapping_template = <<EOF
{
	"version": "2018-05-29",
	"operation": "Invoke",
	"payload": $util.toJson($ctx)
}
EOF

  response_mapping_template = <<EOF
$util.qr($ctx.stash.put("test", "test data"))
$util.toJson($ctx.result)
EOF
}

resource "aws_appsync_function" "func2" {
  api_id                   = aws_appsync_graphql_api.appsync.id
  data_source              = aws_appsync_datasource.lambda.name
  name                     = "func2"
  request_mapping_template = <<EOF
{
	"version": "2018-05-29",
	"operation": "Invoke",
	"payload": $util.toJson($ctx)
}
EOF

  response_mapping_template = <<EOF
$util.toJson($ctx.result)
EOF
}

resource "aws_appsync_resolver" "Item_pipelineField" {
  api_id      = aws_appsync_graphql_api.appsync.id
  type        = "Item"
  field       = "pipelinefield"
  request_template  = "{}"
  response_template = "$util.toJson($ctx.result)"
  kind              = "PIPELINE"
  pipeline_config {
    functions = [
      aws_appsync_function.func1.function_id,
      aws_appsync_function.func2.function_id,
    ]
  }
}

