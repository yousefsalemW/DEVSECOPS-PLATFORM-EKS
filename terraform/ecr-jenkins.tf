############################################
# ECR
############################################

resource "aws_ecr_repository" "repos" {
  for_each = toset([
    "vprofile-app",
    "vprofile-db",
    "vprofile-mc",
    "vprofile-rmq",
    "vprofile-web"
  ])

  name                 = each.value
  image_tag_mutability = "IMMUTABLE"
  force_delete = true
# Allow full Terraform teardown by deleting images before the ECR repository.
# This is intentional because the ECR repositories are fully managed by Terraform.

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Environment = "production"
    ManagedBy   = "Terraform"
    Project     = "vprofile"
  }
}

resource "aws_ecr_lifecycle_policy" "repos" {
  for_each   = aws_ecr_repository.repos
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 20 images"

        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 20
        }

        action = {
          type = "expire"
        }
      }
    ]
  })
}

############################################
# IAM
############################################

resource "aws_iam_role" "jenkins" {

  name = "jenkins-ec2-role"

  assume_role_policy = jsonencode({

    Version = "2012-10-17"

    Statement = [

      {
        Effect = "Allow"

        Action = "sts:AssumeRole"

        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "jenkins_ssm" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "jenkins_ecr" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

resource "aws_iam_role_policy" "jenkins_eks" {

  name = "jenkins-eks"

  role = aws_iam_role.jenkins.id

  policy = jsonencode({

    Version = "2012-10-17"

    Statement = [

      {
        Effect = "Allow"

        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters"
        ]

        Resource = "*"
      },

      {
        Effect = "Allow"

        Action = [
          "sts:GetCallerIdentity"
        ]

        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "jenkins" {

  name = "jenkins-ec2-profile"

  role = aws_iam_role.jenkins.name
}

############################################
# Security Group
############################################

resource "aws_security_group" "jenkins" {

  name        = "jenkins-sg"
  description = "SSM only - no inbound"

  vpc_id = module.vpc.vpc_id

  tags = {
    Name        = "jenkins-sg"
    Environment = "production"
    ManagedBy   = "Terraform"
    Project     = "vprofile"
  }
}

resource "aws_vpc_security_group_egress_rule" "jenkins_all" {

  security_group_id = aws_security_group.jenkins.id

  cidr_ipv4   = "0.0.0.0/0"

  ip_protocol = "-1"

  description = "Allow all outbound traffic"
}


############################################
# Jenkins EC2
############################################

resource "aws_instance" "jenkins" {

  ami           = "ami-015cabafc8f6249fe"

  instance_type = "m7i-flex.large"

  subnet_id = module.vpc.private_subnets[0]

  vpc_security_group_ids = [
    aws_security_group.jenkins.id
  ]

  iam_instance_profile = aws_iam_instance_profile.jenkins.name

  monitoring = true

  #disable_api_termination = true

  instance_initiated_shutdown_behavior = "stop"

  user_data = file("${path.module}/jenkins-userdata.sh")

  #user_data_replace_on_change = true

  metadata_options {

    http_endpoint = "enabled"

    http_tokens = "required"

    instance_metadata_tags = "enabled"
  }

  root_block_device {

    volume_size = 80

    volume_type = "gp3"

    encrypted = true

    delete_on_termination = true

    iops = 3000

    throughput = 125
  }

  tags = {

    Name = "jenkins-server"

    Environment = "production"

    Project = "vprofile"

    ManagedBy = "Terraform"

    Backup = "true"
  }
}

############################################
# Outputs
############################################

output "jenkins_instance_id" {
  value = aws_instance.jenkins.id
}

output "jenkins_private_ip" {
  value = aws_instance.jenkins.private_ip
}

output "jenkins_private_dns" {
  value = aws_instance.jenkins.private_dns
}
