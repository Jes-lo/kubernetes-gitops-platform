variable "kube_context" {
  description = "Kubernetes context used for the local platform bootstrap."
  type        = string
  default     = "kind-kubernetes-gitops-dev"
}

variable "argocd_chart_version" {
  description = "Pinned Argo CD Helm chart version."
  type        = string
  default     = "10.9.2"
}
