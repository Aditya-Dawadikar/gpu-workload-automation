data "aws_availability_zones" "available" {
  state = "available"
}

# Ubuntu 22.04 for the CPU head node.
data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
}

# AWS Deep Learning Base AMI (Ubuntu 22.04): ships NVIDIA driver, CUDA, Docker
# and the NVIDIA container toolkit, so workers only need Ray on top.
data "aws_ssm_parameter" "gpu_ami" {
  name = "/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id"
}

locals {
  az          = coalesce(var.availability_zone, data.aws_availability_zones.available.names[0])
  subnet_cidr = cidrsubnet(var.vpc_cidr, 8, 0)

  # Fixed head address: workers' user_data is then known at plan time (an
  # unknown IP there trips an AWS provider bug when instances are replaced),
  # and workers reconnect on their own if the head is rebuilt.
  head_private_ip = cidrhost(local.subnet_cidr, 10)
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.cluster_name}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.cluster_name}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.subnet_cidr
  availability_zone       = local.az
  map_public_ip_on_launch = true

  tags = { Name = "${var.cluster_name}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.cluster_name}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# Security group: nodes talk freely to each other (Ray uses many dynamic
# ports); only the operator CIDRs can reach the UIs and SSH.
# ---------------------------------------------------------------------------
resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-sg"
  description = "Ray GPU cluster"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.cluster_name}-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "intra_cluster" {
  security_group_id            = aws_security_group.cluster.id
  referenced_security_group_id = aws_security_group.cluster.id
  ip_protocol                  = "-1"
  description                  = "All traffic between cluster nodes"
}

locals {
  operator_ports = {
    ssh           = 22
    grafana       = 3000
    ray_dashboard = 8265
    prometheus    = 9090
  }

  operator_rules = {
    for pair in setproduct(keys(local.operator_ports), var.allowed_cidrs) :
    "${pair[0]}-${pair[1]}" => { port = local.operator_ports[pair[0]], cidr = pair[1], name = pair[0] }
  }
}

resource "aws_vpc_security_group_ingress_rule" "operator" {
  for_each = local.operator_rules

  security_group_id = aws_security_group.cluster.id
  cidr_ipv4         = each.value.cidr
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  description       = "Operator access: ${each.value.name}"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.cluster.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------------------
# IAM: SSM access everywhere; the head also needs ec2:Describe* so
# Prometheus can discover workers automatically.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "head" {
  name               = "${var.cluster_name}-head"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role" "worker" {
  name               = "${var.cluster_name}-worker"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "head_ssm" {
  role       = aws_iam_role.head.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "worker_ssm" {
  role       = aws_iam_role.worker.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "prometheus_discovery" {
  statement {
    actions   = ["ec2:DescribeInstances", "ec2:DescribeAvailabilityZones"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "head_discovery" {
  name   = "prometheus-ec2-discovery"
  role   = aws_iam_role.head.id
  policy = data.aws_iam_policy_document.prometheus_discovery.json
}

resource "aws_iam_instance_profile" "head" {
  name = "${var.cluster_name}-head"
  role = aws_iam_role.head.name
}

resource "aws_iam_instance_profile" "worker" {
  name = "${var.cluster_name}-worker"
  role = aws_iam_role.worker.name
}

# ---------------------------------------------------------------------------
# Access
# ---------------------------------------------------------------------------
locals {
  generate_ssh_key = var.ssh_public_key_path == null
  ssh_private_key_path = (local.generate_ssh_key
    ? abspath(local_sensitive_file.ssh_private_key[0].filename)
    : trimsuffix(pathexpand(var.ssh_public_key_path), ".pub")
  )
}

# Generated only when no existing public key is supplied. Note the private
# key is also stored in Terraform state.
resource "tls_private_key" "ssh" {
  count     = local.generate_ssh_key ? 1 : 0
  algorithm = "ED25519"
}

resource "local_sensitive_file" "ssh_private_key" {
  count                = local.generate_ssh_key ? 1 : 0
  content              = tls_private_key.ssh[0].private_key_openssh
  filename             = "${path.module}/.keys/${var.cluster_name}.pem"
  file_permission      = "0600"
  directory_permission = "0700"
}

resource "aws_key_pair" "this" {
  key_name = "${var.cluster_name}-key"
  public_key = (local.generate_ssh_key
    ? tls_private_key.ssh[0].public_key_openssh
    : file(pathexpand(var.ssh_public_key_path))
  )
}

resource "random_password" "grafana_admin" {
  length  = 20
  special = false
}

resource "aws_placement_group" "workers" {
  count    = var.use_placement_group ? 1 : 0
  name     = "${var.cluster_name}-workers"
  strategy = "cluster"
}
