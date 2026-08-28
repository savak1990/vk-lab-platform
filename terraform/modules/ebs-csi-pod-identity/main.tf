module "pod_identity" {
  source = "../pod-identity"

  cluster_name              = var.cluster_name
  role_name                 = "${var.cluster_name}-ebs-csi-controller"
  service_account_name      = var.service_account_name
  service_account_namespace = var.service_account_namespace
}

resource "aws_iam_role_policy_attachment" "controller" {
  role       = module.pod_identity.role_name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

moved {
  from = aws_iam_role.controller
  to   = module.pod_identity.aws_iam_role.controller
}

moved {
  from = aws_eks_pod_identity_association.controller
  to   = module.pod_identity.aws_eks_pod_identity_association.controller
}
