# File: 0-locals.tf
locals {
  env         = "staging"
  region      = "us-east-2"
  zone1       = "us-east-2a"
  zone2       = "us-east-2b"
  eks_name    = "demo"
  eks_version = "1.30"
}

# File: 1-providers.tf
provider "aws" {
  region = local.region
}

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.53"
    }
  }
}

# File: 2-vpc.tf
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.env}-main"
  }
}

# File: 3-igw.tf
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.env}-igw"
  }
}

# File: 4-subnets.tf
resource "aws_subnet" "private_zone1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.0.0/19"
  availability_zone = local.zone1

  tags = {
    "Name"                                                 = "${local.env}-private-${local.zone1}"
    "kubernetes.io/role/internal-elb"                      = "1"
    "kubernetes.io/cluster/${local.env}-${local.eks_name}" = "owned"
  }
}

resource "aws_subnet" "private_zone2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.32.0/19"
  availability_zone = local.zone2

  tags = {
    "Name"                                                 = "${local.env}-private-${local.zone2}"
    "kubernetes.io/role/internal-elb"                      = "1"
    "kubernetes.io/cluster/${local.env}-${local.eks_name}" = "owned"
  }
}

resource "aws_subnet" "public_zone1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.64.0/19"
  availability_zone       = local.zone1
  map_public_ip_on_launch = true

  tags = {
    "Name"                                                 = "${local.env}-public-${local.zone1}"
    "kubernetes.io/role/elb"                               = "1"
    "kubernetes.io/cluster/${local.env}-${local.eks_name}" = "owned"
  }
}

resource "aws_subnet" "public_zone2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.96.0/19"
  availability_zone       = local.zone2
  map_public_ip_on_launch = true

  tags = {
    "Name"                                                 = "${local.env}-public-${local.zone2}"
    "kubernetes.io/role/elb"                               = "1"
    "kubernetes.io/cluster/${local.env}-${local.eks_name}" = "owned"
  }
}

# File: 5-nat.tf
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${local.env}-nat"
  }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_zone1.id

  tags = {
    Name = "${local.env}-nat"
  }

  depends_on = [aws_internet_gateway.igw]
}
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name = "${local.env}-private"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${local.env}-public"
  }
}

resource "aws_route_table_association" "private_zone1" {
  subnet_id      = aws_subnet.private_zone1.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_zone2" {
  subnet_id      = aws_subnet.private_zone2.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "public_zone1" {
  subnet_id      = aws_subnet.public_zone1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_zone2" {
  subnet_id      = aws_subnet.public_zone2.id
  route_table_id = aws_route_table.public.id
}

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
data "template_file" "user_data" {
  template = <<-EOF
#!/bin/bash
set -ex

# Update system
yum update -y

# Install Node.js 18.x
curl -sL https://rpm.nodesource.com/setup_18.x | bash -
yum install -y nodejs git

# Install pnpm
npm install -g pnpm

# Install Nginx
amazon-linux-extras install -y nginx1
systemctl enable nginx
systemctl start nginx

# Configure Nginx as reverse proxy for the agent
cat > /etc/nginx/conf.d/agent.conf <<'NGINXCONF'
server {
    listen 80;
    server_name _;
    
    location / {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINXCONF

# Test Nginx configuration and reload
nginx -t && systemctl reload nginx

# Create agent directory
mkdir -p /opt/agent
cd /opt/agent

# Clone the agent starter repository
git clone https://github.com/livekit-examples/agent-starter-react.git .
rm -rf .git

# Install dependencies
pnpm install

# Create systemd service for the agent
cat > /etc/systemd/system/agent.service <<'SERVICECONF'
[Unit]
Description=LiveKit Agent Starter
After=network.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/opt/agent
Environment=NODE_ENV=production
ExecStart=/usr/bin/pnpm start
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICECONF

# Start the agent service
systemctl daemon-reload
systemctl enable agent
systemctl start agent

EOF
}

# Launch Template
resource "aws_launch_template" "agent" {
  name_prefix   = "${local.env}-agent-"
  # Amazon Linux 2 AMI for us-east-2
  image_id      = "ami-02f3416038bdb17fb"  
  instance_type = "t3.medium"
  key_name      = "lk"  # Update with your key pair name
  user_data     = base64encode(data.template_file.user_data.rendered)

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

  block_device_mappings {
    device_name = "/dev/xvda"
    
    ebs {
      volume_size = 30
      volume_type = "gp3"
      encrypted   = true
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