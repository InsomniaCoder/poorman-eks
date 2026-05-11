output "karpenter_controller_role_arn" {
  value = aws_iam_role.karpenter_controller.arn
}

output "karpenter_interruption_queue_name" {
  value = aws_sqs_queue.karpenter_interruption.name
}

output "argocd_server_service_name" {
  value = "argocd-server"
}
