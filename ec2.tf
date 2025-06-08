# ec2.tf

# Find the latest Amazon Linux 2 AMI
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

# Web Server Instance
resource "aws_instance" "web_server" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.public_a.id
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y httpd
              systemctl start httpd
              systemctl enable httpd
              echo "<h1>Hello from Web Server in Public Subnet</h1>" > /var/www/html/index.html
              EOF

  tags = {
    Name = "web-server"
  }
}

# App Server Instance
resource "aws_instance" "app_server" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.app_a.id
  vpc_security_group_ids = [aws_security_group.app_sg.id]

  # In a real-world scenario, you would use user_data or a configuration
  # management tool to deploy your application code.
  
  tags = {
    Name = "app-server"
  }
}
