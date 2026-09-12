data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

#Create a VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  instance_tenancy     = "default"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "microservice-vpc"
  }
}

#Create internet gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "microservice-igw"
  }
}

#Create an Elastic IP for the NAT Gateway
resource "aws_eip" "nat" {
  domain = "vpc"
  tags = {
    Name = "microservice-nat-eip"
  }
}

#Create a NAT Gateway in the public subnet
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_az1.id
  depends_on    = [aws_internet_gateway.igw]

  tags = {
    Name = "microservice-nat-gw"
  }
}

#Create 2 public subnets in 2 AZs
resource "aws_subnet" "public_az1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "microservice-public-az1"
  }
}

resource "aws_subnet" "public_az2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true

  tags = {
    Name = "microservice-public-az2"
  }
}

#Create 2 private subnets in 2 AZs
resource "aws_subnet" "private_az1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.3.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false

  tags = {
    Name = "microservice-private-az1"
  }
}

resource "aws_subnet" "private_az2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.4.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = false

  tags = {
    Name = "microservice-private-az2"
  }
}

#Create route table for public subnets
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "microservice-public-rt"
  }
}

# Create route table for private subnets routing through NAT Gateway
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name = "microservice-private-rt"
  }
}

#Attach route tables to public subnets
resource "aws_route_table_association" "public_az1" {
  subnet_id      = aws_subnet.public_az1.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "public_az2" {
  subnet_id      = aws_subnet.public_az2.id
  route_table_id = aws_route_table.public_rt.id
}

# Attach route tables to private subnets
resource "aws_route_table_association" "private_az1" {
  subnet_id      = aws_subnet.private_az1.id
  route_table_id = aws_route_table.private_rt.id
}

resource "aws_route_table_association" "private_az2" {
  subnet_id      = aws_subnet.private_az2.id
  route_table_id = aws_route_table.private_rt.id
}

#Create security group for load balancer
resource "aws_security_group" "alb-sg" {
  name        = "microservice-alb-sg"
  description = "Allow inbound traffic on port 80"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
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
    Name = "microservice-alb-sg"
  }
}

#Create security group for EC2 instances
resource "aws_security_group" "ec2-sg" {
  name        = "microservice-ec2-sg"
  description = "Allow traffic from ALB to dashboard instances"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 9002
    to_port         = 9002
    protocol        = "tcp"
    security_groups = [aws_security_group.alb-sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "microservice-ec2-sg"
  }
}

#IAM role so instances are reachable via Session Manager
resource "aws_iam_role" "ec2_ssm" {
  name = "microservice-ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "microservice-ec2-profile"
  role = aws_iam_role.ec2_ssm.name
}

#Create an Application Load Balancer
resource "aws_lb" "alb" {
  name               = "microservice-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb-sg.id]
  subnets            = [aws_subnet.public_az1.id, aws_subnet.public_az2.id]

  tags = {
    Name = "microservice-alb"
  }
}

#Create a target group for the ALB
resource "aws_lb_target_group" "alb_tg" {
  name     = "microservice-tg"
  port     = 9002
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    enabled             = true
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200-299"
  }
}

#Create a listener for the ALB
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb_tg.arn
  }
}

# Launch Template for Auto Scaling Group
resource "aws_launch_template" "dashboard_lt" {
  name_prefix   = "microservice-dashboard-lt-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = "t3.micro"

  vpc_security_group_ids = [aws_security_group.ec2-sg.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2.name
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  user_data = base64encode(<<EOF
#!/bin/bash
set -e
apt-get update -y
apt-get install -y wget unzip

useradd --system --no-create-home --shell /usr/sbin/nologin appsvc

cd /opt
wget -q https://github.com/hashicorp/demo-consul-101/releases/download/v0.0.5/counting-service_linux_amd64.zip
wget -q https://github.com/hashicorp/demo-consul-101/releases/download/v0.0.5/dashboard-service_linux_amd64.zip
unzip -o counting-service_linux_amd64.zip
unzip -o dashboard-service_linux_amd64.zip
chmod +x counting-service_linux_amd64 dashboard-service_linux_amd64
chown appsvc:appsvc /opt/counting-service_linux_amd64 /opt/dashboard-service_linux_amd64

cat > /etc/systemd/system/counting.service <<'UNIT'
[Unit]
Description=Counting Service
After=network-online.target

[Service]
User=appsvc
Group=appsvc
Environment=PORT=9001
ExecStart=/opt/counting-service_linux_amd64
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/dashboard.service <<'UNIT'
[Unit]
Description=Dashboard Service
After=counting.service

[Service]
User=appsvc
Group=appsvc
Environment=PORT=9002
Environment=COUNTING_SERVICE_URL=http://127.0.0.1:9001
ExecStart=/opt/dashboard-service_linux_amd64
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now counting.service
systemctl enable --now dashboard.service
EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "microservice-dashboard"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

#Create an Auto Scaling Group
resource "aws_autoscaling_group" "dashboard_asg" {
  name                      = "microservice-dashboard-asg"
  desired_capacity          = 2
  max_size                  = 6
  min_size                  = 2
  health_check_grace_period = 300
  health_check_type         = "ELB"
  vpc_zone_identifier       = [aws_subnet.private_az1.id, aws_subnet.private_az2.id]
  target_group_arns         = [aws_lb_target_group.alb_tg.arn]

  launch_template {
    id      = aws_launch_template.dashboard_lt.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 120
    }
  }

  tag {
    key                 = "Name"
    value               = "microservice-dashboard"
    propagate_at_launch = true
  }

  depends_on = [
    aws_route_table_association.private_az1,
    aws_route_table_association.private_az2,
    aws_nat_gateway.nat
  ]
}

#Target tracking scaling policy, without this the ASG never scales
resource "aws_autoscaling_policy" "request_count" {
  name                      = "microservice-request-count-target-tracking"
  autoscaling_group_name    = aws_autoscaling_group.dashboard_asg.name
  policy_type               = "TargetTrackingScaling"
  estimated_instance_warmup = 120

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.alb.arn_suffix}/${aws_lb_target_group.alb_tg.arn_suffix}"
    }
    target_value = 50
  }
}