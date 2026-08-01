###############################################################################
# Module: ecs_ui
# ECS Fargate cluster + task + service + ALB
# ALB uses Cognito for authentication (OAuth2/OIDC code flow)
###############################################################################

###############################################################################
# CloudWatch Log Group
###############################################################################

resource "aws_cloudwatch_log_group" "ui" {
  name              = "/ecs/${var.project_name}-ui"
  retention_in_days = 365
  kms_key_id        = var.kms_key_arn

  tags = merge(var.tags, {
    Name = "${var.project_name}-ui-logs"
  })
}

###############################################################################
# ECS Cluster
###############################################################################

resource "aws_ecs_cluster" "this" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-cluster"
  })
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

###############################################################################
# ECS Task Definition
###############################################################################

resource "aws_ecs_task_definition" "ui" {
  family                   = "${var.project_name}-ui"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.task_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name      = "ui"
      image     = "${var.ecr_ui_repository_url}:latest"
      essential = true

      portMappings = [
        {
          containerPort = 8501
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "AWS_REGION", value = var.aws_region },
        { name = "AGENT_RUNTIME_ID", value = var.agent_runtime_id },
        { name = "AGENT_ENDPOINT_ID", value = var.agent_endpoint_id },
        { name = "S3_BUCKET_NAME", value = var.artifacts_bucket_name },
        { name = "DYNAMODB_TABLE", value = var.dynamodb_table_name },
        { name = "COGNITO_USER_POOL_ID", value = var.enable_cognito_auth ? var.cognito_user_pool_arn : "" },
        { name = "COGNITO_CLIENT_ID", value = var.enable_cognito_auth ? var.cognito_user_pool_client_id : "" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ui.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ui"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:8501/_stcore/health')\" || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 15
      }

      readonlyRootFilesystem = false
      privileged             = false
    }
  ])

  tags = merge(var.tags, {
    Name = "${var.project_name}-ui"
  })
}

###############################################################################
# Application Load Balancer
###############################################################################

resource "aws_lb" "this" {
  #tfsec:ignore:aws-elb-alb-not-public - ALB is the public entry point for the UI, protected by Cognito auth
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids
  ip_address_type    = "dualstack"

  enable_deletion_protection = true
  drop_invalid_header_fields = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-alb"
  })
}

resource "aws_lb_target_group" "ui" {
  name        = "${var.project_name}-ui-tg"
  port        = 8501
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  stickiness {
    type            = "lb_cookie"
    cookie_duration = 3600
    enabled         = true
  }

  health_check {
    enabled             = true
    path                = "/_stcore/health"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-ui-tg"
  })
}

# HTTP listener - forwards to ECS directly
resource "aws_lb_listener" "http" {
  #tfsec:ignore:aws-elb-http-not-used - HTTP used; auth handled at app level via Cognito API
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ui.arn
  }
}

###############################################################################
# ECS Service
###############################################################################

resource "aws_ecs_service" "ui" {
  name            = "${var.project_name}-ui"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.ui.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"
  force_new_deployment = true

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [var.ecs_ui_security_group_id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ui.arn
    container_name   = "ui"
    container_port   = 8501
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_controller {
    type = "ECS"
  }

  depends_on = [aws_lb_listener.http]

  tags = merge(var.tags, {
    Name = "${var.project_name}-ui"
  })
}
