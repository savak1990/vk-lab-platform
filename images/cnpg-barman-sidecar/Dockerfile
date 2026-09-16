# The backup sidecar reaches S3 with temporary credentials from IAM Roles
# Anywhere. botocore runs the helper on demand through credential_process,
# so no extra process and no entrypoint of our own is needed.
FROM public.ecr.aws/rolesanywhere/credential-helper@sha256:56b03f3acba0bda06c94189ab62c4a497fd1912f3d08311fb99ab24e4e4c2f84 AS helper

# The base is distroless with no shell, so the mode must come from the source
# layer - there is no RUN chmod available here.
FROM ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar@sha256:06c78deca670525daa35fb1e5323159092785d11cf87b86217bdd5c679a41a84

COPY --from=helper /usr/local/bin/aws_signing_helper /usr/local/bin/aws_signing_helper
