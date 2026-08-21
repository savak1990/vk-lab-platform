resource "aws_ebs_volume" "this" {
  availability_zone = var.availability_zone
  size              = var.size_gb
  type              = "gp3"

  tags = {
    Component = var.component
  }

  lifecycle {
    # CNPG grows this volume in place via the CSI driver; EBS can't shrink,
    # so tracking size here would make Terraform propose destroying and
    # recreating the volume that holds live data the moment it grows.
    ignore_changes = [size]
  }
}
