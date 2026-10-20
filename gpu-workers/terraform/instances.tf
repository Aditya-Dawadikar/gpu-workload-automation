locals {
  obs_dir       = "${path.module}/../observability"
  bootstrap_lib = file("${path.module}/templates/bootstrap-lib.sh")

  # Files shipped to /opt/observability on the head node via cloud-init.
  observability_files = {
    "docker-compose.yml" = templatefile("${local.obs_dir}/docker-compose.yml.tftpl", {
      prometheus_image    = var.prometheus_image
      grafana_image       = var.grafana_image
      node_exporter_image = var.node_exporter_image
    })
    "prometheus/prometheus.yml" = templatefile("${local.obs_dir}/prometheus/prometheus.yml.tftpl", {
      region       = var.region
      cluster_name = var.cluster_name
    })
    "grafana/provisioning/datasources/prometheus.yml" = file("${local.obs_dir}/grafana/provisioning/datasources/prometheus.yml")
    "grafana/provisioning/dashboards/dashboards.yml"  = file("${local.obs_dir}/grafana/provisioning/dashboards/dashboards.yml")
    "grafana/dashboards/gpu/gpu-cluster.json"         = file("${local.obs_dir}/grafana/dashboards/gpu/gpu-cluster.json")
    ".env"                                            = "GRAFANA_ADMIN_PASSWORD=${random_password.grafana_admin.result}\n"
  }
}

# ---------------------------------------------------------------------------
# Head node
# ---------------------------------------------------------------------------
data "cloudinit_config" "head" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/cloud-config"
    content = yamlencode({
      write_files = [
        for path, content in local.observability_files : {
          path        = "/opt/observability/${path}"
          encoding    = "b64"
          content     = base64encode(content)
          permissions = path == ".env" ? "0600" : "0644"
        }
      ]
    })
  }

  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/templates/head-init.sh.tftpl", {
      bootstrap_lib = local.bootstrap_lib
      ray_version   = var.ray_version
      head_num_cpus = var.head_schedulable ? "" : "--num-cpus=0"
    })
  }
}

resource "aws_instance" "head" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = var.head_instance_type
  subnet_id              = aws_subnet.public.id
  private_ip             = local.head_private_ip
  vpc_security_group_ids = [aws_security_group.cluster.id]
  key_name               = aws_key_pair.this.key_name
  iam_instance_profile   = aws_iam_instance_profile.head.name
  user_data_base64       = data.cloudinit_config.head.rendered

  # Rebuild the head when its bootstrap changes. Workers keep running and
  # their ray-worker service reconnects to the same fixed IP.
  user_data_replace_on_change = true

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = var.head_volume_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name        = "${var.cluster_name}-head"
    RayNodeType = "head"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}

# ---------------------------------------------------------------------------
# GPU workers
# ---------------------------------------------------------------------------
data "cloudinit_config" "worker" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/templates/worker-init.sh.tftpl", {
      bootstrap_lib       = local.bootstrap_lib
      ray_version         = var.ray_version
      head_ip             = local.head_private_ip
      node_exporter_image = var.node_exporter_image
      dcgm_exporter_image = var.dcgm_exporter_image
    })
  }
}

resource "aws_instance" "worker" {
  count = var.worker_count

  ami                    = data.aws_ssm_parameter.gpu_ami.value
  instance_type          = var.worker_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.cluster.id]
  key_name               = aws_key_pair.this.key_name
  iam_instance_profile   = aws_iam_instance_profile.worker.name
  user_data_base64       = data.cloudinit_config.worker.rendered
  placement_group        = var.use_placement_group ? aws_placement_group.workers[0].id : null

  user_data_replace_on_change = true

  dynamic "instance_market_options" {
    for_each = var.worker_use_spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        spot_instance_type             = "one-time"
        instance_interruption_behavior = "terminate"
      }
    }
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = var.worker_volume_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name        = "${var.cluster_name}-worker-${count.index}"
    RayNodeType = "worker"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}
