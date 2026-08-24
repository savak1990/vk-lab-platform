resource "aws_ebs_volume" "this" {
  count             = var.volume_count
  availability_zone = var.availability_zone
  size              = var.size_gb
  type              = "gp3"

  tags = {
    Component = var.component
  }

  lifecycle {
    # Kafka's storage.size is fixed (no CSI-driven grow-in-place resize
    # planned), so drift here is unlikely - kept anyway for consistency
    # with any future consumer of this module that does grow volumes
    # in place via the CSI driver.
    ignore_changes = [size]
  }
}
