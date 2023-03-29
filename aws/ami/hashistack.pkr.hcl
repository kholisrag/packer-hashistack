packer {
  required_version = ">= 1.8.6"
}

variable "aws_region" {
  type        = string
  description = "AWS Region"
  default     = "us-east-1"
}

variable "ami_regions" {
  type        = list(string)
  description = "A comma separated string value of regions to copy the AMI to"
  default     = []
}

variable "ubuntu_codename" {
  type        = string
  description = "Ubuntu Codename, how to get : `lsb_release -cs`"
  default     = "jammy"
}

variable "ubuntu_version" {
  type        = string
  description = "Ubuntu Version"
  default     = "22.04"
}

variable "docker_version" {
  type        = string
  description = "Docker CE Package, full version string"
  default     = "5:20.10.16~3-0~ubuntu-jammy"
}

variable "containerd_version" {
  type        = string
  description = "ContainerD Package, full version string"
  default     = "1.6.19-1"
}

variable "nomad_version" {
  type        = string
  description = "Nomad binary version (https://releases.hashicorp.com/nomad)"
}

variable "consul_version" {
  type        = string
  description = "Consul binary version (https://releases.hashicorp.com/consul)"
}

variable "vault_version" {
  type        = string
  description = "Vault binary version (https://releases.hashicorp.com/vault)"
}

variable "cni_plugins_version" {
  type        = string
  description = "CNI Plugins version (https://github.com/containernetworking/plugins/releases/)"
}

variable "ami_name_prefix" {
  type        = string
  description = "Name Prefix for the generated AMI"
  default     = "hashistack-ami"
}

variable "ami_tags" {
  type        = map(string)
  description = "Map of Key Value Pair Tags, to pass to Packer Builded's AMI"
}

variable "ami_users" {
  type        = list(string)
  description = "List of String AWS Account ID, that can use this AMI"
  default     = []
}

variable "ami_org_arns" {
  type        = list(string)
  description = "List of string AWS Organization ARN, that can use this AMI"
  default     = []
}

variable "skip_create_ami" {
  type        = bool
  description = "Skip Create AMI ref: https://www.packer.io/plugins/builders/amazon/ebs#skip_create_ami, default: true"
  default     = true
}

locals {
  time_now = timestamp()

  packer_ami_tag_pair_full = merge(
    var.ami_tags,
    { "nomad_version" = var.nomad_version },
    { "consul_version" = var.consul_version },
    { "cni_plugins_version" = var.cni_plugins_version },
    { "containerd_version" = var.containerd_version },
    { "docker_version" = var.docker_version },
    { "nomad_version" = var.nomad_version },
    { "vault_version" = var.vault_version },
    { "ubuntu_version" = var.ubuntu_version }
  )

  skip_region_validation = var.ami_regions == [] ? true : false
}

source "amazon-ebs" "hashistack_ami_amd64" {
  #- Change this to true, when you're debugging / adding a feature
  #- ref: https://www.packer.io/plugins/builders/amazon/ebs#skip_create_ami
  skip_create_ami = var.skip_create_ami

  ami_name               = format("%s-ubuntu-%s-amd64-%s", var.ami_name_prefix, var.ubuntu_version, formatdate("YYYYMMDDhhmmss", local.time_now))
  ami_description        = format("Ubuntu %s AMI with Nomad, Consul, Vault and Docker installed", var.ubuntu_version)
  ami_regions            = var.ami_regions != [] ? var.ami_regions : null
  ami_users              = var.ami_users != [] ? var.ami_users : null
  ami_org_arns           = var.ami_org_arns != [] ? var.ami_org_arns : null
  skip_region_validation = local.skip_region_validation

  region = var.aws_region
  vpc_filter {
    filters = {
      "isDefault" : "true",
    }
  }

  instance_type = "t3a.small"

  source_ami_filter {
    filters = {
      name                = format("ubuntu/images/hvm-ssd/ubuntu-%s-%s-amd64-server-*", var.ubuntu_codename, var.ubuntu_version)
      root-device-type    = "ebs"
      virtualization-type = "hvm"
      architecture        = "x86_64"
    }
    owners      = ["099720109477"]
    most_recent = true
  }

  temporary_iam_instance_profile_policy_document {
    Version = "2012-10-17"
    Statement {
      Effect   = "Allow"
      Resource = ["*"]

      Action = [
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
        "ssm:UpdateInstanceInformation",
      ]
    }

    Statement {
      Effect   = "Allow"
      Resource = ["*"]

      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
    }

    Statement {
      Effect   = "Allow"
      Resource = ["*"]

      Action = [
        "ec2messages:AcknowledgeMessage",
        "ec2messages:DeleteMessage",
        "ec2messages:FailMessage",
        "ec2messages:GetEndpoint",
        "ec2messages:GetMessages",
        "ec2messages:SendReply",
      ]
    }
  }

  communicator     = "ssh"
  ssh_interface    = "session_manager"
  ssh_username     = "ubuntu"
  ssh_timeout      = "5m"
  pause_before_ssm = "10s"

  dynamic "tag" {
    for_each = local.packer_ami_tag_pair_full
    content {
      key   = tag.key
      value = tag.value
    }
  }
}

source "amazon-ebs" "hashistack_ami_arm64" {
  #- Change this to true, when you're debugging / adding a feature
  #- ref: https://www.packer.io/plugins/builders/amazon/ebs#skip_create_ami
  skip_create_ami = var.skip_create_ami

  ami_name               = format("%s-ubuntu-%s-arm64-%s", var.ami_name_prefix, var.ubuntu_version, formatdate("YYYYMMDDhhmmss", local.time_now))
  ami_description        = format("Ubuntu %s AMI with Nomad, Consul, Vault and Docker installed", var.ubuntu_version)
  ami_regions            = var.ami_regions != [] ? var.ami_regions : null
  ami_users              = var.ami_users != [] ? var.ami_users : null
  ami_org_arns           = var.ami_org_arns != [] ? var.ami_org_arns : null
  skip_region_validation = local.skip_region_validation

  region = var.aws_region
  vpc_filter {
    filters = {
      "isDefault" : "true",
    }
  }

  instance_type = "t4g.small"

  source_ami_filter {
    filters = {
      name                = format("ubuntu/images/hvm-ssd/ubuntu-%s-%s-arm64-server-*", var.ubuntu_codename, var.ubuntu_version)
      root-device-type    = "ebs"
      virtualization-type = "hvm"
      architecture        = "arm64"
    }
    owners      = ["099720109477"]
    most_recent = true
  }

  temporary_iam_instance_profile_policy_document {
    Version = "2012-10-17"
    Statement {
      Effect   = "Allow"
      Resource = ["*"]

      Action = [
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
        "ssm:UpdateInstanceInformation",
      ]
    }

    Statement {
      Effect   = "Allow"
      Resource = ["*"]

      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
    }

    Statement {
      Effect   = "Allow"
      Resource = ["*"]

      Action = [
        "ec2messages:AcknowledgeMessage",
        "ec2messages:DeleteMessage",
        "ec2messages:FailMessage",
        "ec2messages:GetEndpoint",
        "ec2messages:GetMessages",
        "ec2messages:SendReply",
      ]
    }
  }

  communicator     = "ssh"
  ssh_interface    = "session_manager"
  ssh_username     = "ubuntu"
  ssh_timeout      = "5m"
  pause_before_ssm = "20s"

  dynamic "tag" {
    for_each = local.packer_ami_tag_pair_full
    content {
      key   = tag.key
      value = tag.value
    }
  }
}

build {
  sources = [
    "source.amazon-ebs.hashistack_ami_amd64",
    "source.amazon-ebs.hashistack_ami_arm64"
  ]

  provisioner "file" {
    source      = format("%s/scripts", path.root)
    destination = "/tmp/"
  }

  provisioner "shell" {
    inline = [
      "chmod -R +x /tmp/scripts",
      "/tmp/scripts/setup-ubuntu.sh"
    ]
    environment_vars = [
      format("DOCKER_VERSION=%s", var.docker_version),
      format("CONTAINERD_VERSION=%s", var.containerd_version),
      format("NOMAD_VERSION=%s", var.nomad_version),
      format("CONSUL_VERSION=%s", var.consul_version),
      format("VAULT_VERSION=%s", var.vault_version),
      format("CNI_PLUGINS_VERSION=%s", var.cni_plugins_version),
      "DEBIAN_FRONTEND=noninteractive"
    ]
    pause_before = "1s"
  }

  post-processors {
    post-processor "manifest" {
      output     = format("%s/%s-ubuntu-%s.json", path.root, var.ami_name_prefix, var.ubuntu_version)
      strip_path = true
    }
  }
}
