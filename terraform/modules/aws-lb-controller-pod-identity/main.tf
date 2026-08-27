data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "controller" {
  name               = "${var.cluster_name}-aws-lb-controller"
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

# No AWS-managed policy exists for this controller (unlike EBS CSI) - this
# is AWS's own published policy document, vendored as-is rather than
# hand-narrowed: https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
# Re-fetch and diff against that URL before applying, in case it has moved
# since this file was written.
resource "aws_iam_role_policy" "controller" {
  name   = "controller"
  role   = aws_iam_role.controller.id
  policy = file("${path.module}/iam-policy.json")
}

resource "aws_eks_pod_identity_association" "controller" {
  cluster_name    = var.cluster_name
  namespace       = var.service_account_namespace
  service_account = var.service_account_name
  role_arn        = aws_iam_role.controller.arn
}
