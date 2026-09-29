output "argocd_namespace" {
  description = "Namespace where Argo CD is bootstrapped."
  value       = kubernetes_namespace_v1.argocd.metadata[0].name
}

output "argocd_release_name" {
  description = "Terraform-managed Argo CD Helm release name."
  value       = helm_release.argocd.name
}

output "argocd_chart_version" {
  description = "Pinned Argo CD Helm chart version."
  value       = var.argocd_chart_version
}
