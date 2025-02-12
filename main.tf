locals {
  name   = "demo"
  region = "ap-southeast-1"
}

data "http" "my_public_ip" {
  url = "http://ifconfig.me/ip"
}

data "aws_availability_zones" "available" {}

resource "aws_iam_policy" "jumphost" {
  name        = "JumphostPolicy"
  description = "Allow access to Kafka, Secrets Manager, and KMS"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kafka:DescribeCluster",
          "kafka:GetBootstrapBrokers",
          "kafka:ListClusters",
          "kafka:ListTopics",
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeGroup",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:ReadData"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = "*" # You can restrict this to specific secret ARNs
      },
      {
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = "*" # Restrict to KMS key ARNs if possible
      }
    ]
  })
}

module "aws_vpc" {
  source = "tfstack/vpc/aws"

  region             = local.region
  vpc_name           = local.name
  vpc_cidr           = "10.0.0.0/16"
  availability_zones = data.aws_availability_zones.available.names

  public_subnets   = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_subnets  = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
  isolated_subnets = ["10.0.7.0/24", "10.0.8.0/24", "10.0.9.0/24"]

  jumphost_subnet             = "10.0.0.0/24"
  jumphost_ingress_cidrs      = ["${data.http.my_public_ip.response_body}/32"]
  jumphost_instance_type      = "t3.micro"
  jumphost_allow_egress       = true
  jumphost_user_data_file     = "${path.module}/external/cloud-init.yaml"
  jumphost_inline_policy_arns = [aws_iam_policy.jumphost.arn]

  create_igw = true
  ngw_type   = "single"
}
