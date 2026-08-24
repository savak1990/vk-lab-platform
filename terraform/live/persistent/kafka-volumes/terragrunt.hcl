include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true # needed to read include.root.locals.postgres_az below
}

terraform {
  source = "${get_repo_root()}/terraform/modules/ebs-volume"
}

inputs = {
  volume_count = 1 # one per Kafka broker; raise alongside KafkaNodePool.spec.replicas
  # Only read at creation time (see the module's ignore_changes note).
  size_gb           = 10
  availability_zone = include.root.locals.postgres_az # the platform's one shared AZ, despite the name
  component         = "kafka"
}
