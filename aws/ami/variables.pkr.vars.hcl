aws_region      = "us-east-1"
ami_name_prefix = "hashistack-ami"
ami_tags = {
  "packer" = "true"
}

ami_regions  = []
ami_users    = []
ami_org_arns = []

nomad_version  = "1.5.2"
vault_version  = "1.13.0"
consul_version = "1.15.1"

cni_plugins_version = "v1.2.0"
containerd_version  = "1.6.19-1"
docker_version      = "5:23.0.2-1~ubuntu.22.04~jammy"

ubuntu_codename = "jammy"
ubuntu_version  = "22.04"
