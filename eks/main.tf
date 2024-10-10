################################################################################
# Providers
################################################################################

provider "aws" {
  region = var.region
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

################################################################################
# Data Sources
################################################################################

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_rds_engine_version" "postgresql" {
  engine             = "postgres"
  preferred_versions = ["15.5", "15.4", "15.3", "15.2", "15.1"]
}

################################################################################
# Random Resources
################################################################################

resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
  numeric = true
  lower   = true
}

resource "random_password" "rds_password" {
  length  = 16
  special = true
  upper   = true
  numeric = true
  lower   = true
}

################################################################################
# Locals
################################################################################

locals {
  name   = "opengovernance"
  region = var.region

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 2)

  tags = {
    Name        = local.name

  }

  # Use the Key ID (not ARN)
  ebs_kms_key_id = module.ebs_kms_key.key_id
}

################################################################################
# VPC
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${local.name}-vpc-${random_string.suffix.result}"
  cidr = local.vpc_cidr

  azs = local.azs

  private_subnets = [for k, az in local.azs : cidrsubnet(local.vpc_cidr, 8, k)]
  public_subnets  = [for k, az in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 4)]

  # Conditionally create database subnets based on the environment

  enable_nat_gateway = true
  single_nat_gateway = true

  manage_default_network_acl             = false
  manage_default_route_table             = false


  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "Name"                    = "opengovernance-public-subnet"
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "Name"                            = "opengovernance-private-subnet"
  }



  tags = local.tags
}

################################################################################
# EKS Cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.11"

  cluster_name                   = "${local.name}-eks-${random_string.suffix.result}"
  cluster_version                = "1.31"
  cluster_endpoint_public_access = true

  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_group_defaults = {
    iam_role_additional_policies = {
      AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    }
    public_ip = false
  }

  eks_managed_node_groups = {
    opengovernance-main = {
      instance_types = var.eks_instance_types
      min_size       = 1
      max_size       = 5
      desired_size   = 3

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 150
            volume_type           = "gp3"
            iops                  = 3000
            encrypted             = false
            delete_on_termination = true
          }
        }
      }
    }      
  }
  tags = local.tags
}

################################################################################
# EBS KMS Key
################################################################################

module "ebs_kms_key" {
  source  = "terraform-aws-modules/kms/aws"
  version = "~> 1.5"

  description = "Customer managed key to encrypt EKS managed node group volumes"

  key_administrators = [data.aws_caller_identity.current.arn]
  key_service_roles_for_autoscaling = [
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling",
    module.eks.cluster_iam_role_arn,
  ]

  aliases = ["alias/eks/${local.name}/ebs"]

  tags = local.tags
}

################################################################################
# Alias for KMS Key
################################################################################

resource "aws_kms_alias" "ebs_alias" {
  name          = "alias/eks/${local.name}/ebs"
  target_key_id = module.ebs_kms_key.key_id
}

################################################################################
# EBS CSI Driver IRSA
################################################################################

module "ebs_csi_driver_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.20"

  role_name_prefix = "${substr(module.eks.cluster_name, 0, 20)}-ebs-csi-"

  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.tags
}

################################################################################
# EKS Blueprints Addons (Excluding OpenGovernance)
################################################################################

module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.16"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  create_delay_dependencies = [
    for group in module.eks.eks_managed_node_groups : group.node_group_arn
  ]

  eks_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_driver_irsa.iam_role_arn
    }
    coredns    = {}
    vpc-cni    = {}
    kube-proxy = {}
  }

  enable_aws_load_balancer_controller = true
  aws_load_balancer_controller = {
    chart_version = "1.6.0"
  }

  tags = local.tags
}



################################################################################
# Storage Classes
################################################################################

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"

    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  allow_volume_expansion = true
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"

  parameters = {
    encrypted = false
    fsType    = "ext4"
    type      = "gp3"
  }

  depends_on = [
    module.eks
  ]
}

################################################################################
# Outputs
################################################################################

output "vpc_id" {
  description = "The ID of the VPC"
  value       = module.vpc.vpc_id
}

output "eks_cluster_name" {
  description = "The name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "update_kubeconfig_command" {
  description = "Command to update kubeconfig for the EKS cluster"
  value       = "aws eks --region ${var.region} update-kubeconfig --name ${module.eks.cluster_name}"
}

# Additional outputs as needed