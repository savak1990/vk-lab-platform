resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version

  # No ingress: reached via port-forward until spec 012 wires up the real
  # ALB/Envoy edge.
  set = [{
    name  = "server.service.type"
    value = "ClusterIP"
  }]
}

# The root ("app-of-apps") Application, rendered from the gitops/bootstrap
# chart so the exact same chart (not a Terraform-only template) is what
# spec 021's local install script uses for the `local` target.
resource "helm_release" "root_application" {
  name      = "root-application"
  namespace = "argocd"
  chart     = var.root_application_chart_path

  set = [
    {
      name  = "target"
      value = "aws"
    },
    {
      name  = "repoURL"
      value = var.repo_url
    },
    {
      name  = "targetRevision"
      value = var.target_revision
    },
  ]

  depends_on = [helm_release.argocd]
}
