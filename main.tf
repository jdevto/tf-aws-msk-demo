locals {
  name   = "demo"
  region = "ap-southeast-1"
}

data "http" "my_public_ip" {
  url = "http://ifconfig.me/ip"
}

data "aws_availability_zones" "available" {}

resource "aws_iam_policy" "jumphost" {
  name = "${local.name}-policy"
  # name        = "JumphostPolicy"
  # description = "Allow access to Kafka, Secrets Manager, and KMS"

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
          "kafka-cluster:CreateTopic",
          "kafka-cluster:DeleteTopic",
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

  jumphost_subnet        = "10.0.0.0/24"
  jumphost_ingress_cidrs = ["${data.http.my_public_ip.response_body}/32"]
  jumphost_allow_egress  = true

  jumphost_instance_create    = true
  jumphost_user_data_file     = "${path.module}/external/cloud-init.yaml"
  jumphost_inline_policy_arns = [aws_iam_policy.jumphost.arn]

  create_igw = true
  ngw_type   = "single"
}

module "aws_security_group_msk" {
  source = "tfstack/security-group/aws"

  name        = "${local.name}-msk"
  description = "Security group for MSK cluster, enabling internal connectivity"
  vpc_id      = module.aws_vpc.vpc_id

  custom_ingress_rules = [
    {
      rule_name   = "zookeeper-2181-tcp"
      cidr_ipv4   = module.aws_vpc.vpc_cidr
      description = "ZooKeeper Connectivity within VPC"
      tags = {
        Purpose  = "Kafka Coordination"
        Protocol = "TCP"
        Port     = "2181"
        Access   = "Inbound"
      }
    },
    # {
    #   rule_name   = "kafka-9092-tcp"
    #   cidr_ipv4   = aws_vpc.main.cidr_block
    #   description = "Apache Kafka"
    #   tags = {
    #     Purpose  = "Kafka Broker Communication"
    #     Protocol = "TCP"
    #     Port     = "9092"
    #     Access   = "Inbound"
    #   }
    # },
    # {
    #   rule_name   = "kafka-9094-tcp"
    #   cidr_ipv4   = aws_vpc.main.cidr_block
    #   description = "Apache Kafka Broker TLS"
    #   tags = {
    #     Purpose  = "Kafka Broker Secure Communication"
    #     Protocol = "TCP"
    #     Port     = "9094"
    #     Access   = "Inbound"
    #   }
    # },
    {
      rule_name   = "kafka-9098-tcp"
      cidr_ipv4   = module.aws_vpc.vpc_cidr
      description = "Apache Kafka IAM Authentication"
      tags = {
        Purpose  = "IAM Authenticated Kafka Connections"
        Protocol = "TCP"
        Port     = "9098"
        Access   = "Inbound"
      }
    }
  ]

  tags = {
    Name        = "${local.name}-msk"
    Environment = "Dev"
    Project     = "MSK Cluster"
    ManagedBy   = "Terraform"
  }
}

resource "aws_msk_configuration" "example" {
  name              = "KafkaConfigOverride"
  kafka_versions    = ["3.6.0"]
  server_properties = <<-EOT
    auto.create.topics.enable=false
    unclean.leader.election.enable=false
  EOT
}


resource "aws_msk_cluster" "example" {
  cluster_name           = local.name
  kafka_version          = "3.6.0"
  number_of_broker_nodes = 3

  broker_node_group_info {
    instance_type   = "kafka.t3.small"
    client_subnets  = module.aws_vpc.private_subnet_ids
    security_groups = [module.aws_security_group_msk.security_group_id]

    storage_info {
      ebs_storage_info {
        volume_size = 10
      }
    }
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS"
      in_cluster    = true
    }
  }

  client_authentication {
    sasl {
      iam = true
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.example.arn
    revision = aws_msk_configuration.example.latest_revision
  }
}

resource "aws_ssm_parameter" "msk_bootstrap" {
  name  = "/config/application/spring.kafka.bootstrap-servers"
  type  = "String"
  value = aws_msk_cluster.example.bootstrap_brokers_sasl_iam
}
