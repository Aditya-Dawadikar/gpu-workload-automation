output "head_public_ip" {
  value = aws_instance.head.public_ip
}

output "head_private_ip" {
  value = aws_instance.head.private_ip
}

output "worker_public_ips" {
  value = aws_instance.worker[*].public_ip
}

output "worker_private_ips" {
  value = aws_instance.worker[*].private_ip
}

output "head_instance_id" {
  value = aws_instance.head.id
}

output "worker_instance_ids" {
  value = aws_instance.worker[*].id
}

output "worker_count" {
  value = var.worker_count
}

output "ray_dashboard_url" {
  value = "http://${aws_instance.head.public_ip}:8265"
}

output "grafana_url" {
  value = "http://${aws_instance.head.public_ip}:3000"
}

output "prometheus_url" {
  value = "http://${aws_instance.head.public_ip}:9090"
}

output "llm_api_url" {
  description = "OpenAI-compatible base URL once a model is deployed with ../llm-deployment."
  value       = "http://${aws_instance.head.public_ip}:8000/v1"
}

output "grafana_admin_password" {
  value     = random_password.grafana_admin.result
  sensitive = true
}

output "ssh_private_key_path" {
  description = "Private key matching the key pair on the nodes."
  value       = local.ssh_private_key_path
}

output "ssh_head" {
  value = "ssh -i ${local.ssh_private_key_path} ubuntu@${aws_instance.head.public_ip}"
}
