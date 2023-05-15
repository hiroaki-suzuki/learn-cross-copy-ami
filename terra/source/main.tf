terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "4.67.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"
}

locals {
  name-prefix = "hs-copy-ami"
}

resource "aws_vpc" "main" {
  cidr_block           = "172.30.0.0/16"
  enable_dns_hostnames = true
  tags                 = {
    Name = "${local.name-prefix}-vpc"
  }
}
# サブネット
resource "aws_subnet" "main" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "172.30.0.0/24"
  availability_zone = "ap-northeast-1a"

  tags = {
    Name = "${local.name-prefix}-public-subnet"
  }
}

# インターネットゲートウェイ
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name-prefix}-igw"
  }
}

# ルートテーブル
resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.name-prefix}-public-rtb"
  }
}

resource "aws_route_table_association" "main" {
  route_table_id = aws_route_table.main.id
  subnet_id      = aws_subnet.main.id
}

# セキュリティグループ
resource "aws_security_group" "main" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["3.112.23.0/29"]
    description = "from instance connect"
  }
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

  name = "${local.name-prefix}-ec2-sg"
  tags = {
    Name = "${local.name-prefix}-ec2-sg"
  }
}

# ========================================
# EC2
# ========================================
resource "aws_iam_role" "main" {
  name = "${local.name-prefix}-ec2-role"

  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [
      {
        Effect    = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      },
    ]
  })
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/EC2InstanceConnect"
  ]
}

resource "aws_iam_instance_profile" "main" {
  name = "${local.name-prefix}-ec2-instance-profile"
  role = aws_iam_role.main.name
}

resource "aws_instance" "main" {
  ami                    = "ami-0e0820ad173f20fbb"
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.main.id
  vpc_security_group_ids = [aws_security_group.main.id]
  iam_instance_profile   = aws_iam_instance_profile.main.name

  root_block_device {
    volume_size           = 8
    volume_type           = "gp3"
    iops                  = 3000
    throughput            = 125
    delete_on_termination = true
    encrypted             = true
    kms_key_id            = var.ebs-kms-id

    tags = {
      Name = "${local.name-prefix}-ec2-ebs"
    }
  }

  tags = {
    Name = "${local.name-prefix}-ec2"
  }
}

resource "aws_eip" "main" {
  instance = aws_instance.main.id

  tags = {
    Name = "${local.name-prefix}-ec2-eip"
  }
}

resource "aws_kms_key" "main" {
  description             = "KMS key for encrypting EBS volumes"
  deletion_window_in_days = 7

  policy = <<POLICY
    {
      "Version": "2012-10-17",
      "Id": "${local.name-prefix}-ec2-kms-key",
      "Statement": [
        {
          "Sid": "Enable IAM User Permissions",
          "Effect": "Allow",
          "Principal": {
            "AWS": "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
          },
          "Action": "kms:*",
          "Resource": "*"
        },
        {
          "Effect": "Allow",
          "Principal": {
            "AWS": "arn:aws:iam::${var.shared-account-id}:root"
          },
          "Action": [
            "kms:Encrypt",
            "kms:Decrypt",
            "kms:ReEncrypt*",
            "kms:GenerateDataKey*",
            "kms:DescribeKey"
          ],
          "Resource": "*"
        }
      ]
    }
POLICY
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.name-prefix}-ec2-kms-key"
  target_key_id = aws_kms_key.main.key_id
}

data "aws_caller_identity" "current" {}