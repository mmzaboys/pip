
###############################################################################
# AGENT ASG MODULE - NEW
###############################################################################

# Security Group for Agent Instances
resource "aws_security_group" "agent_sg" {
  name        = "${local.env}-agent-sg"
  description = "Security group for agent instances"
  vpc_id      = aws_vpc.main.id

  # HTTP for Nginx
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Agent port (default 3000 for React app)
  ingress {
    description = "Agent React App"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH for debugging
  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.env}-agent-sg"
  }
}

# IAM Role for Agent Instances
resource "aws_iam_role" "agent_instance_role" {
  name = "${local.env}-agent-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "ec2.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "agent_policy" {
  name = "${local.env}-agent-instance-policy"
  role = aws_iam_role.agent_instance_role.id

  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : [
          "ssm:DescribeAssociation",
          "ssm:GetDeployablePatchSnapshotForInstance",
          "ssm:GetDocument",
          "ssm:DescribeDocument",
          "ssm:GetManifest",
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:ListAssociations",
          "ssm:ListInstanceAssociations",
          "ssm:PutInventory",
          "ssm:PutComplianceItems",
          "ssm:PutConfigurePackageResult",
          "ssm:UpdateAssociationStatus",
          "ssm:UpdateInstanceAssociationStatus",
          "ssm:UpdateInstanceInformation"
        ],
        "Resource" : "*"
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ],
        "Resource" : "*"
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ec2messages:AcknowledgeMessage",
          "ec2messages:DeleteMessage",
          "ec2messages:FailMessage",
          "ec2messages:GetEndpoint",
          "ec2messages:GetMessages",
          "ec2messages:SendReply"
        ],
        "Resource" : "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "agent_instance_profile" {
  name = "${local.env}-agent-instance-profile"
  role = aws_iam_role.agent_instance_role.name
}

# User Data Script for Agent Installation


resource "aws_launch_template" "agent" {
  name_prefix   = "${local.env}-agent-"
  image_id      = "ami-00e428798e77d38d9"  # Amazon Linux 2
  instance_type = "t3.medium"
  key_name      = "lk"  # Update with your key pair name
  
  # User data with minimal installation only
  user_data = base64encode(<<-EOT
#!/bin/bash
set -ex

# Update system
yum update -y

# Install Node.js 18.x
curl -sL https://rpm.nodesource.com/setup_18.x | bash -
yum install -y nodejs git

# Install pnpm globally
npm install -g pnpm

# Create agent directory
mkdir -p /opt/agent
chown -R ec2-user:ec2-user /opt/agent

# The rest (Nginx, service file, etc.) will be handled by deploy.sh
# This keeps the initial instance setup minimal and fast
EOT
  )

  iam_instance_profile {
    name = aws_iam_instance_profile.agent_instance_profile.name
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.agent_sg.id]
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${local.env}-agent-instance"
    }
  }

  

  tags = {
    Name = "${local.env}-agent-launch-template"
  }
}

# Auto Scaling Group
resource "aws_autoscaling_group" "agent" {
  name_prefix         = "${local.env}-agent-asg-"
  # Use your existing public subnets
  vpc_zone_identifier = [aws_subnet.public_zone1.id, aws_subnet.public_zone2.id]
  min_size            = 1
  max_size            = 3
  desired_capacity    = 2
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.agent.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${local.env}-agent-instance"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = "agent-starter"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Load Balancer
resource "aws_lb" "agent_lb" {
  name               = "${local.env}-agent-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.agent_sg.id]
  # Use your existing public subnets
  subnets            = [aws_subnet.public_zone1.id, aws_subnet.public_zone2.id]

  enable_deletion_protection = false

  tags = {
    Name = "${local.env}-agent-load-balancer"
  }
}

resource "aws_lb_target_group" "agent" {
  name        = "${local.env}-agent-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "${local.env}-agent-target-group"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.agent_lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.agent.arn
  }

  tags = {
    Name = "${local.env}-agent-http-listener"
  }
}
resource "aws_lb_listener" "ui_port" {
  load_balancer_arn = aws_lb.agent_lb.arn
  port              = 3000
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.agent.arn
  }

  tags = {
    Name = "${local.env}-agent-http-listener"
  }
}
# Additional EC2 Instance from Custom AMI
resource "aws_instance" "custom_agent" {
  ami           = "ami-09eccb9e1b3400041"  # Replace with your custom AMI ID
  instance_type = "t2.medium"
  key_name      = "lk"  # Your existing key pair

  # Assign to a public subnet
  subnet_id              = aws_subnet.public_zone1.id
  associate_public_ip_address = true

  # Security group (reuse your existing agent SG)
  vpc_security_group_ids = [aws_security_group.agent_sg.id]

  # Optional: Tags
  tags = {
    Name    = "${local.env}-custom-agent"
    Project = "agent-starter"
  }


}


resource "aws_autoscaling_attachment" "agent" {
  autoscaling_group_name = aws_autoscaling_group.agent.id
  lb_target_group_arn   = aws_lb_target_group.agent.arn
}

# Outputs
output "agent_load_balancer_dns" {
  description = "DNS name of the agent load balancer"
  value       = aws_lb.agent_lb.dns_name
}

output "agent_security_group_id" {
  description = "Agent security group ID"
  value       = aws_security_group.agent_sg.id
}

output "public_subnets" {
  description = "Public subnet IDs"
  value       = [aws_subnet.public_zone1.id, aws_subnet.public_zone2.id]
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}