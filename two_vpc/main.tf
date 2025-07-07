################################################################################
# 1_network.tf: Defines VPCs, Subnets, Gateways, and Routing
################################################################################

# --- Bastion VPC (192.168.0.0/16) ---
resource "aws_vpc" "vpc_bastion" {
  cidr_block           = "192.168.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "VPC-Bastion"
  }
}

# --- Application VPC (172.32.0.0/16) ---
resource "aws_vpc" "vpc_app" {
  cidr_block           = "172.32.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "VPC-Application"
  }
}

# --- Data source for Availability Zones ---
data "aws_availability_zones" "available" {
  state = "available"
}

# --- Bastion VPC Subnets ---
resource "aws_subnet" "bastion_public" {
  count             = 1 # Only one public subnet needed for the bastion
  vpc_id            = aws_vpc.vpc_bastion.id
  cidr_block        = "192.168.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
  tags = {
    Name = "Subnet-Bastion-Public"
  }
}

# --- Application VPC Subnets ---
resource "aws_subnet" "app_public" {
  count             = 2
  vpc_id            = aws_vpc.vpc_app.id
  cidr_block        = "172.32.${count.index + 1}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = {
    Name = "Subnet-App-Public-${data.aws_availability_zones.available.names[count.index]}"
  }
}

resource "aws_subnet" "app_private" {
  count             = 2
  vpc_id            = aws_vpc.vpc_app.id
  cidr_block        = "172.32.${count.index + 101}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = {
    Name = "Subnet-App-Private-${data.aws_availability_zones.available.names[count.index]}"
  }
}

# --- Internet Gateways ---
resource "aws_internet_gateway" "igw_bastion" {
  vpc_id = aws_vpc.vpc_bastion.id
  tags = {
    Name = "IGW-Bastion"
  }
}

resource "aws_internet_gateway" "igw_app" {
  vpc_id = aws_vpc.vpc_app.id
  tags = {
    Name = "IGW-App"
  }
}

# --- NAT Gateway for Application VPC ---
resource "aws_eip" "nat" {
  domain = "vpc"
  tags = {
    Name = "EIP-NAT-Gateway"
  }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.app_public[0].id
  tags = {
    Name = "NAT-Gateway-App"
  }
  depends_on = [aws_internet_gateway.igw_app]
}

# --- Route Tables ---
# Bastion Public Route Table
resource "aws_route_table" "rt_bastion_public" {
  vpc_id = aws_vpc.vpc_bastion.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw_bastion.id
  }
  tags = {
    Name = "RT-Bastion-Public"
  }
}

# App Public Route Table
resource "aws_route_table" "rt_app_public" {
  vpc_id = aws_vpc.vpc_app.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw_app.id
  }
  tags = {
    Name = "RT-App-Public"
  }
}

# App Private Route Table (routes to NAT Gateway)
resource "aws_route_table" "rt_app_private" {
  vpc_id = aws_vpc.vpc_app.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = {
    Name = "RT-App-Private"
  }
}

# --- Route Table Associations ---
resource "aws_route_table_association" "bastion_public" {
  subnet_id      = aws_subnet.bastion_public[0].id
  route_table_id = aws_route_table.rt_bastion_public.id
}

resource "aws_route_table_association" "app_public" {
  count          = 2
  subnet_id      = aws_subnet.app_public[count.index].id
  route_table_id = aws_route_table.rt_app_public.id
}

resource "aws_route_table_association" "app_private" {
  count          = 2
  subnet_id      = aws_subnet.app_private[count.index].id
  route_table_id = aws_route_table.rt_app_private.id
}

# --- Transit Gateway for Inter-VPC Communication ---
resource "aws_ec2_transit_gateway" "main" {
  description = "Transit Gateway for inter-VPC communication"
  tags = {
    Name = "TGW-Main"
  }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "bastion" {
  subnet_ids         = [aws_subnet.bastion_public[0].id]
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id             = aws_vpc.vpc_bastion.id
  tags = {
    Name = "TGW-Attachment-Bastion"
  }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "app" {
  subnet_ids         = [for s in aws_subnet.app_private : s.id]
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id             = aws_vpc.vpc_app.id
  tags = {
    Name = "TGW-Attachment-App"
  }
}

# --- Transit Gateway Routing ---
# Route from Bastion VPC to App VPC
resource "aws_route" "bastion_to_app" {
  route_table_id         = aws_route_table.rt_bastion_public.id
  destination_cidr_block = aws_vpc.vpc_app.cidr_block
  transit_gateway_id     = aws_ec2_transit_gateway.main.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.bastion]
}

# Route from App VPC to Bastion VPC
resource "aws_route" "app_to_bastion" {
  route_table_id         = aws_route_table.rt_app_private.id
  destination_cidr_block = aws_vpc.vpc_bastion.cidr_block
  transit_gateway_id     = aws_ec2_transit_gateway.main.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.app]
}

################################################################################
# 2_logging.tf: Defines CloudWatch logging for VPC Flow Logs
################################################################################

# --- CloudWatch Log Group for VPC Flow Logs ---
resource "aws_cloudwatch_log_group" "vpc_flow_logs_group" {
  name = "VPCFlowLogs"
}

# --- Log Streams for each VPC ---
resource "aws_cloudwatch_log_stream" "bastion_vpc_flow_log_stream" {
  name           = "Bastion-VPC-Flow-Logs"
  log_group_name = aws_cloudwatch_log_group.vpc_flow_logs_group.name
}

resource "aws_cloudwatch_log_stream" "app_vpc_flow_log_stream" {
  name           = "App-VPC-Flow-Logs"
  log_group_name = aws_cloudwatch_log_group.vpc_flow_logs_group.name
}

# --- IAM Role for VPC Flow Logs ---
resource "aws_iam_role" "vpc_flow_logs_role" {
  name = "vpc-flow-logs-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "vpc-flow-logs.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_role_policy" "vpc_flow_logs_policy" {
  name = "vpc-flow-logs-policy"
  role = aws_iam_role.vpc_flow_logs_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Effect   = "Allow"
        Resource = "*"
      },
    ]
  })
}

# --- Enable Flow Logs for both VPCs ---
resource "aws_flow_log" "bastion_vpc_flow_log" {
  iam_role_arn    = aws_iam_role.vpc_flow_logs_role.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs_group.arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.vpc_bastion.id
  log_destination_type = "cloud-watch-logs"
  log_group_name       = aws_cloudwatch_log_group.vpc_flow_logs_group.name
}

resource "aws_flow_log" "app_vpc_flow_log" {
  iam_role_arn    = aws_iam_role.vpc_flow_logs_role.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs_group.arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.vpc_app.id
  log_destination_type = "cloud-watch-logs"
  log_group_name       = aws_cloudwatch_log_group.vpc_flow_logs_group.name
}

################################################################################
# 3_bastion.tf: Defines the Bastion Host
################################################################################

# --- Security Group for Bastion Host ---
resource "aws_security_group" "sg_bastion" {
  name        = "sg-bastion-host"
  description = "Allow SSH from public internet"
  vpc_id      = aws_vpc.vpc_bastion.id

  ingress {
    description = "SSH from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # WARNING: For production, restrict this to your IP
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "SG-Bastion"
  }
}

# --- EIP for Bastion Host ---
resource "aws_eip" "bastion" {
  domain = "vpc"
  tags = {
    Name = "EIP-Bastion"
  }
}

# --- Bastion Host EC2 Instance ---
resource "aws_instance" "bastion_host" {
  ami           = var.bastion_ami_id
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.bastion_public[0].id
  key_name      = var.key_name
  security_groups = [aws_security_group.sg_bastion.id]
  associate_public_ip_address = true

  tags = {
    Name = "Bastion-Host"
  }
}

# --- Associate EIP with Bastion Host ---
resource "aws_eip_association" "bastion" {
  instance_id   = aws_instance.bastion_host.id
  allocation_id = aws_eip.bastion.id
}

################################################################################
# 4_application.tf: Defines S3, IAM, ASG, NLB for the application
################################################################################

# --- S3 Bucket for Application Configuration ---
resource "aws_s3_bucket" "app_config" {
  bucket = var.s3_bucket_name
  
  tags = {
    Name = "s3-app-config-bucket"
  }
}

# --- IAM Role and Instance Profile for App Servers ---
resource "aws_iam_role" "app_server_role" {
  name = "app-server-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

# Attach SSM policy for Session Manager
resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.app_server_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Attach custom policy for S3 access
resource "aws_iam_role_policy" "s3_access_policy" {
  name = "app-server-s3-access"
  role = aws_iam_role.app_server_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Effect   = "Allow"
        Resource = [
          aws_s3_bucket.app_config.arn,
          "${aws_s3_bucket.app_config.arn}/*"
        ]
      },
    ]
  })
}

resource "aws_iam_instance_profile" "app_server_profile" {
  name = "app-server-instance-profile"
  role = aws_iam_role.app_server_role.name
}

# --- Security Group for App Servers ---
resource "aws_security_group" "sg_app" {
  name        = "sg-app-server"
  description = "Allow HTTP from public and SSH from Bastion"
  vpc_id      = aws_vpc.vpc_app.id

  ingress {
    description     = "SSH from Bastion SG"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.sg_bastion.id]
  }

  ingress {
    description = "HTTP from anywhere (via NLB)"
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
    Name = "SG-App-Servers"
  }
}

# --- Key Pair ---
# Note: This resource creates a new key pair and stores the private key locally.
# For production, it's safer to create the key pair in the AWS console and
# reference its name using var.key_name.
resource "aws_key_pair" "deployer" {
  key_name   = var.key_name
  public_key = file(var.public_key_path)
}

# --- Launch Configuration for App Servers ---
resource "aws_launch_configuration" "app_lc" {
  name_prefix                 = "app-server-lc-"
  image_id                    = var.app_ami_id
  instance_type               = "t2.micro"
  security_groups             = [aws_security_group.sg_app.id]
  iam_instance_profile        = aws_iam_instance_profile.app_server_profile.name
  key_name                    = aws_key_pair.deployer.key_name
  associate_public_ip_address = false

  # User data to install httpd, pull code, and start service
  # WARNING: This is a placeholder. You must replace the Bitbucket
  # details with your actual repository and credentials management (e.g., SSH keys).
  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y httpd git
              systemctl start httpd
              systemctl enable httpd
              # --- Placeholder for Bitbucket ---
              # You would need to set up SSH keys or use HTTPS with credentials
              # git clone ssh://git@bitbucket.org/your-user/your-repo.git /var/www/html
              # For this example, we'll just create a test page.
              echo "<h1>Welcome - Instance ID: $(curl -s http://169.254.169.254/latest/meta-data/instance-id)</h1>" > /var/www/html/index.html
              # --- Placeholder for pulling config from S3 ---
              # aws s3 cp s3://${var.s3_bucket_name}/config.json /etc/app/config.json
              EOF

  lifecycle {
    create_before_destroy = true
  }
}

# --- Auto Scaling Group ---
resource "aws_autoscaling_group" "app_asg" {
  name                 = "app-server-asg"
  launch_configuration = aws_launch_configuration.app_lc.name
  min_size             = 2
  max_size             = 4
  desired_capacity     = 2
  vpc_zone_identifier  = [for s in aws_subnet.app_private : s.id]

  # Attach to the NLB Target Group
  target_group_arns = [aws_lb_target_group.app_tg.arn]

  tag {
    key                 = "Name"
    value               = "App-Server-Instance"
    propagate_at_launch = true
  }
}

# --- Network Load Balancer (NLB) ---
resource "aws_lb" "app_nlb" {
  name               = "app-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = [for s in aws_subnet.app_public : s.id]

  enable_deletion_protection = false

  tags = {
    Name = "NLB-Application"
  }
}

# --- NLB Target Group ---
resource "aws_lb_target_group" "app_tg" {
  name     = "app-server-tg"
  port     = 80
  protocol = "TCP"
  vpc_id   = aws_vpc.vpc_app.id

  health_check {
    protocol = "HTTP"
    path     = "/index.html"
    port     = "traffic-port"
  }
}

# --- NLB Listener ---
resource "aws_lb_listener" "app_listener" {
  load_balancer_arn = aws_lb.app_nlb.arn
  port              = "80"
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

################################################################################
# 5_dns.tf: Defines Route 53 record for the NLB
################################################################################

data "aws_route53_zone" "selected" {
  name         = var.domain_name
  private_zone = false
}

resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.selected.zone_id
  name    = "app.${var.domain_name}"
  type    = "CNAME"
  ttl     = 300
  records = [aws_lb.app_nlb.dns_name]
}

################################################################################
# main.tf: Provider configuration
################################################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

################################################################################
# variables.tf: Input variables for the configuration
################################################################################

variable "aws_region" {
  description = "AWS region to deploy resources."
  type        = string
  default     = "us-east-1"
}

variable "key_name" {
  description = "Name of the EC2 key pair to be created and used."
  type        = string
  default     = "webapp-key"
}

variable "public_key_path" {
  description = "Path to the public key file (e.g., ~/.ssh/id_rsa.pub)."
  type        = string
}

variable "bastion_ami_id" {
  description = "AMI ID for the Bastion Host (Amazon Linux 2)."
  type        = string
  default     = "ami-0c55b159cbfafe1f0" # us-east-1 Amazon Linux 2
}

variable "app_ami_id" {
  description = "Golden AMI ID for the Application Servers (Amazon Linux 2)."
  type        = string
  default     = "ami-0c55b159cbfafe1f0" # us-east-1 Amazon Linux 2
}

variable "s3_bucket_name" {
  description = "A unique name for the S3 bucket for application configs."
  type        = string
}

variable "domain_name" {
  description = "Your registered domain name for Route 53 (e.g., example.com)."
  type        = string
}

################################################################################
# outputs.tf: Outputs for important resource information
################################################################################

output "bastion_host_public_ip" {
  description = "The public IP address of the Bastion Host."
  value       = aws_eip.bastion.public_ip
}

output "nlb_dns_name" {
  description = "The DNS name of the Network Load Balancer."
  value       = aws_lb.app_nlb.dns_name
}

output "application_url" {
  description = "The CNAME URL for the application."
  value       = "http://${aws_route53_record.app.name}"
}

output "s3_bucket_id" {
  description = "The ID of the S3 bucket for configuration."
  value       = aws_s3_bucket.app_config.id
}
