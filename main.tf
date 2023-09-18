terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

# reusing earlier snippets for vpc ids
data "aws_secretsmanager_secret_version" "vpcid" {
  secret_id = "vpc_id"
}

data "aws_secretsmanager_secret_version" "secrets_key" {
  secret_id = "secrets_key"
}

data "aws_subnet_ids" "az_subnet" {
  vpc_id = local.vpc_id
  filter {
    name   = "availabilityZone"
    values = ["us-west-2a", "us-west-2b"]
  }
}

locals {
  timestamp = formatdate("YYYY-MM-DD", timestamp())

  vpc_id = jsondecode(
    data.aws_secretsmanager_secret_version.vpcid.secret_string
  )

  gepiviz_key = jsondecode(
    data.aws_secretsmanager_secret_version.secrets_key.secret_string
  )
}

# route53 zone
data "aws_route53_zone" "app_zone" {
  private_zone = false
}

# create an efs filesystem ahead of time, this needs to have 
# a security policy that allows port 2049 (nfs - tcp/udp)
data "aws_efs_file_system" "pypi_cache" {
  file_system_id = "EFS ID"
}

# setting up security group
resource "aws_security_group" "pypi_sg" {
  name   = "pypi-sg"
  vpc_id = local.vpc_id

  # from_port needs to be 0, may be because awsvpc ENI controls this ?
  # for pypiserver
  ingress {
    from_port   = 0
    protocol    = "tcp"
    to_port     = 8080
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = [
      "0.0.0.0/0"
    ]
  }

  lifecycle {
    ignore_changes = [
      tags, tags_all
    ]
  }
}


# setup ECS cluster
resource "aws_ecs_cluster" "pypi" {
  name = "pypi"
  # capacity_providers = ["FARGATE"]

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# IAM roles
data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# task execution role
resource "aws_iam_role" "task_execution_role" {
  name               = "task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}

data "aws_iam_policy" "ecs_task_execution_role" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role" {
  role       = aws_iam_role.task_execution_role.name
  policy_arn = data.aws_iam_policy.ecs_task_execution_role.arn
  # policy = data.aws_iam_policy_document.ecs_task_policy_cloudwatch.json
}

# cloudwatch logs
resource "aws_iam_role" "ecs_task_role_cloudwatch" {
  name               = "cw-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}

data "aws_iam_policy_document" "ecs_task_policy_cloudwatch" {
  statement {
    effect = "Allow"

    actions = [
      "cloudwatch:Put*"
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ecs_task_role_cloudwatch_policy" {
  name   = "cw-role-policy"
  role   = aws_iam_role.ecs_task_role_cloudwatch.id
  policy = data.aws_iam_policy_document.ecs_task_policy_cloudwatch.json
}

# ecs task definition
resource "aws_ecs_task_definition" "pypi_task" {
  family = "pypi"

  # TODO: -P . -a. for no password access, check 
  # https://github.com/pypiserver/pypiserver#using-the-docker-image
  # for docker usage
  container_definitions = <<EOF
    [
        {
            "name": "pypi",
            "image": "186543171269.dkr.ecr.us-west-2.amazonaws.com/pypiserver:latest",
            "command": ["-P", ".", "-a", ".", "/data/packages"],
            "portMappings": [
                {
                    "containerPort": 8080,
                    "hostPort": 8080
                }
            ],
            "mountPoints": [
                {
                    "containerPath": "/data/packages",
                    "sourceVolume": "pypi_efs"
                }
            ],
            "environment": [],
            "cpu": 1024,
            "memory": 2048,
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-region": "us-west-2",
                    "awslogs-group": "/aws/ecs/fargate/pypi",
                    "awslogs-stream-prefix": "ecs"
                }
            }
        }
    ]
    EOF

  volume {
    name = "pypi_efs"
    efs_volume_configuration {
      file_system_id     = data.aws_efs_file_system.pypi_cache.file_system_id
      transit_encryption = "ENABLED"
    }
  }

  execution_role_arn       = aws_iam_role.task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role_cloudwatch.arn
  cpu                      = 1024
  memory                   = 2048
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
}


# service definition
resource "aws_ecs_service" "pypi_service" {
  name            = "api"
  task_definition = aws_ecs_task_definition.pypi_task.arn
  cluster         = aws_ecs_cluster.pypi.id
  launch_type     = "FARGATE"

  network_configuration {
    assign_public_ip = false

    security_groups = [
      aws_security_group.pypi_sg.id,
    ]

    subnets = data.aws_subnet_ids.az_subnet.ids
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.alb_tg.arn
    container_name   = aws_ecs_task_definition.pypi_task.family
    container_port   = 8080
  }

  desired_count = 1

  lifecycle {
    ignore_changes = [desired_count]
  }
}

# load balancer
resource "aws_lb_target_group" "alb_tg" {
  name        = "alb-tg"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = local.vpc_id

  health_check {
    enabled = true
    path    = "/"
  }

  depends_on = [aws_alb.pypi_alb]
}

resource "aws_alb" "pypi_alb" {
  name               = "pypi-alb"
  internal           = true
  load_balancer_type = "application"

  subnets = data.aws_subnet_ids.az_subnet.ids

  security_groups = [
    aws_security_group.pypi_sg.id
  ]

}

resource "aws_alb_listener" "pypi_alb_listener" {
  load_balancer_arn = aws_alb.pypi_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb_tg.arn
  }
}

# setting up cloud watch
resource "aws_cloudwatch_log_group" "pypi" {
  name              = "/aws/ecs/fargate/pypi"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_stream" "pypi_log_stream" {
  name           = "pypi-logstream"
  log_group_name = aws_cloudwatch_log_group.pypi.name
}

# setting up route 53
resource "aws_route53_record" "pypi" {
  zone_id = data.aws_route53_zone.zone.id
  name    = "pypi.${data.aws_route53_zone.zone.name}"
  type    = "A"

  alias {
    name                   = aws_alb.pypi_alb.dns_name
    zone_id                = aws_alb.pypi_alb.zone_id
    evaluate_target_health = true
  }
}
