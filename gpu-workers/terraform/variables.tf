# ---------------------------------------------------------------------------
# General
# ---------------------------------------------------------------------------
variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "availability_zone" {
  description = "AZ for the cluster subnet. GPU capacity differs per AZ; null picks the first AZ in the region."
  type        = string
  default     = null
}

variable "cluster_name" {
  description = "Name of the Ray cluster. Used for resource names and the RayCluster tag that Prometheus uses for discovery."
  type        = string
  default     = "gpu-cluster"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,32}$", var.cluster_name))
    error_message = "cluster_name must be 3-32 chars of lowercase letters, digits and hyphens."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the cluster VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach SSH, the Ray dashboard, Grafana, Prometheus and the Ray Serve API. Set this to your own IP, e.g. [\"203.0.113.7/32\"]."
  type        = list(string)

  validation {
    condition     = length(var.allowed_cidrs) > 0
    error_message = "allowed_cidrs must contain at least one CIDR."
  }
}

variable "ssh_public_key_path" {
  description = "Path to an existing SSH public key installed on every node (user: ubuntu). Leave null to have Terraform generate a dedicated key pair; the private key is written to terraform/.keys/<cluster_name>.pem."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Head node (CPU only: runs Ray GCS/dashboard, Prometheus and Grafana)
# ---------------------------------------------------------------------------
variable "head_instance_type" {
  description = "EC2 instance type for the Ray head node."
  type        = string
  default     = "m5.xlarge"
}

variable "head_volume_size_gb" {
  description = "Root volume size for the head node."
  type        = number
  default     = 60
}

variable "head_schedulable" {
  description = "If false the head advertises 0 CPUs so Ray tasks only run on GPU workers."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# GPU workers
# ---------------------------------------------------------------------------
variable "worker_count" {
  description = "Number of GPU worker nodes."
  type        = number
  default     = 2

  validation {
    condition     = var.worker_count >= 1 && var.worker_count <= 64
    error_message = "worker_count must be between 1 and 64."
  }
}

variable "worker_instance_type" {
  description = "EC2 GPU instance type for workers (g4dn.xlarge = 1x T4, g5.xlarge = 1x A10G, g5.12xlarge = 4x A10G, p4d.24xlarge = 8x A100...)."
  type        = string
  default     = "g4dn.xlarge"
}

variable "worker_volume_size_gb" {
  description = "Root volume size for GPU workers (the Deep Learning AMI needs at least ~75 GB)."
  type        = number
  default     = 150
}

variable "worker_use_spot" {
  description = "Launch GPU workers as Spot instances (much cheaper, may be interrupted)."
  type        = bool
  default     = false
}

variable "use_placement_group" {
  description = "Put workers in a 'cluster' placement group for lower inter-node latency. Can cause capacity errors for large instance counts."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Software versions
# ---------------------------------------------------------------------------
variable "ray_version" {
  description = "Ray version installed on every node. All nodes must run the same Ray and Python version."
  type        = string
  default     = "2.40.0"
}

variable "prometheus_image" {
  type    = string
  default = "prom/prometheus:v2.55.1"
}

variable "grafana_image" {
  type    = string
  default = "grafana/grafana:11.3.0"
}

variable "node_exporter_image" {
  type    = string
  default = "prom/node-exporter:v1.8.2"
}

variable "dcgm_exporter_image" {
  description = "NVIDIA DCGM exporter image used for GPU metrics on workers."
  type        = string
  default     = "nvcr.io/nvidia/k8s/dcgm-exporter:3.3.9-3.6.1-ubuntu22.04"
}
