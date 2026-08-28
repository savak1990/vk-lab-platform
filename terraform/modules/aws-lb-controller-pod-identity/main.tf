module "pod_identity" {
  source = "../pod-identity"

  cluster_name              = var.cluster_name
  role_name                 = "${var.cluster_name}-aws-lb-controller"
  service_account_name      = var.service_account_name
  service_account_namespace = var.service_account_namespace
}

# No AWS-managed policy exists for this controller (unlike EBS CSI) - this
# is AWS's own published policy document, vendored as-is rather than
# hand-narrowed: https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
# Re-fetch and diff against that URL before applying, in case it has moved
# since this file was written.
resource "aws_iam_role_policy" "controller" {
  name   = "controller"
  role   = module.pod_identity.role_name
  policy = file("${path.module}/iam-policy.json")
}

moved {
  from = aws_iam_role.controller
  to   = module.pod_identity.aws_iam_role.controller
}

moved {
  from = aws_eks_pod_identity_association.controller
  to   = module.pod_identity.aws_eks_pod_identity_association.controller
}
