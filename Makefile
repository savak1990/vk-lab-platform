.PHONY: up down full-up full-down platform-up platform-down state-up state-down status account-up account-down bootstrap-up bootstrap-down secret-encrypt secret-decrypt generate-secrets persistent-up persistent-down clear-cache cluster-up cluster-down eks-kubeconfig argo-up argo-down

.NOTPARALLEL:

# Lifecycle: state -> bootstrap -> persistence -> cluster -> argo

# Overridable so CI/integration runs can use a disposable, randomly
# generated name instead of the personal lab's, e.g.
# PROJECT_NAME=vk-lab-ci-1234 make bootstrap-up
export PROJECT_NAME ?= vk-lab-platform

# Overridable to run the whole platform in another AWS region, e.g.
# PROJECT_REGION=us-east-1 make bootstrap-up
export PROJECT_REGION ?= eu-west-1

# The account layer (kms/lab-role/github-oidc/eks-access-identity, created
# once by account-up) applies in this fixed region regardless of PROJECT_REGION -
# the shared secrets KMS key only exists here. Only relevant to
# account-up/account-down and secret-encrypt/secret-decrypt/generate-secrets;
# leave unset unless account-up itself was run against a non-default region.
export ACCOUNT_MAIN_REGION ?= eu-west-1

# Overridable subdomain delegated from the root domain, e.g. lab.<root-domain>.
export SUBDOMAIN ?= lab

## Brings up the cluster + Argo CD onto an existing Persistent layer.
## Fails fast (naming `make persistent-up`) if Persistent doesn't exist yet -
## never creates it (constitution §17). For a from-scratch environment use
## `make full-up`.
up: clear-cache cluster-up argo-up

## Tears down Argo CD then the cluster. Does NOT touch Persistent or
## Bootstrap - use `make persistent-down`/`make bootstrap-down` for those.
down: clear-cache argo-down cluster-down

## Brings up the entire platform from nothing: Bootstrap (state bucket +
## DNS zone + ACM cert) -> Persistent (VPC + Secrets Manager) -> cluster ->
## Argo CD. Persistent-lifecycle passwords are generated only if missing
## (see persistent-up); root-domain.enc is generated from $ROOT_DOMAIN if
## set and missing, otherwise it must already exist - it's a real domain,
## never randomly generated.
full-up: clear-cache bootstrap-up persistent-up cluster-up argo-up

## Tears down the entire platform: Argo CD -> cluster -> Persistent ->
## Bootstrap (DNS zone + ACM cert, then this project's own state bucket).
## Rarely used - persistent-down/bootstrap-down each keep their own guards
## (CONFIRM_DESTROY for bootstrap-down).
full-down: clear-cache argo-down cluster-down persistent-down bootstrap-down

## Brings up Persistent + the disposable cluster + Argo CD onto an existing
## State/Bootstrap layer. For cluster+Argo only (Persistent already up) use
## `make up`; for everything from scratch use `make full-up`.
platform-up: clear-cache persistent-up cluster-up argo-up

## Tears down Argo CD -> cluster -> Persistent, stopping there. Leaves
## Bootstrap/State untouched. For an environment whose Bootstrap/State must
## survive (e.g. the personal lab) but whose Persistent layer (DNS zone,
## ACM cert, Secrets Manager) is meant to be torn down along with everything
## above it.
platform-down: clear-cache argo-down cluster-down persistent-down

## Reports which lifecycle layers currently have state in the shared bucket.
status:
	./scripts/status.sh

## Creates this project's own state bucket directly. Usually invoked via
## `make bootstrap-up`, not directly - kept as its own target for manual/
## debugging use.
state-up:
	./scripts/state-up.sh

## Destroys this project's own state bucket directly. Usually invoked via
## `make bootstrap-down`, not directly - kept as its own target for manual/
## debugging use. Only for ci/cd or a full manual teardown.
state-down:
	./scripts/state-down.sh

## Creates account-global resources (shared secrets KMS key, shared lab-role,
## GitHub OIDC provider, eks-access-identity) in their own dedicated state
## bucket, then sets lab.yml's vars.AWS_ROLE_ARN/secrets.ROOT_DOMAIN. Run
## once per AWS account - deliberately in no composite target.
account-up:
	./scripts/account-up.sh

## Destroys account-global resources, including their own dedicated state
## bucket. Guarded (CONFIRM_DESTROY), expected to run essentially never -
## every project in the account shares these.
account-down:
	./scripts/account-down.sh

## Creates Bootstrap-lifecycle resources for this project: its own state
## bucket, then the lab DNS zone/delegation + ACM cert.
bootstrap-up:
	./scripts/bootstrap-up.sh

## Destroys Bootstrap-lifecycle resources for this project: the DNS zone/
## cert, then its own state bucket. Guarded (CONFIRM_DESTROY must match
## PROJECT_NAME) and refuses while Persistent/Disposable state still exists.
bootstrap-down:
	./scripts/bootstrap-down.sh

## Creates Persistent-lifecycle resources (VPC, Secrets Manager).
## Auto-generates postgres-app-password.enc / grafana-admin-password.enc /
## argocd-admin-password.bcrypt if missing (never overwrites an existing
## one - see ADR 0014); bootstrap-up already generates/requires these plus
## root-domain, so this is normally a no-op repeat.
persistent-up:
	./scripts/generate-secrets.sh
	./scripts/require-persistent-secrets.sh
	cd terraform/live/persistent && terragrunt run --all --non-interactive -- apply -auto-approve

## Destroys Persistent-lifecycle resources. Guarded, rarely-used - see constitution §17.
## Also permanently deletes every retained EBS volume the ebs-retain
## StorageClass created (spec 005) and every retained Postgres EBS
## snapshot (ADR 0013) - both listed before terragrunt's destroy prompt,
## since they're Persistent-lifecycle data outside any Terraform state.
## Usage: make persistent-down
persistent-down:
	./scripts/persistent-down.sh

## Creates the disposable EKS cluster (system node group + addons). Fails
## fast (naming `make persistent-up`) if the Persistent layer doesn't exist
## yet - never creates it (constitution §17). Run `make argo-up` after
## this to install Argo CD and the platform.
cluster-up:
	./scripts/require-persistent.sh
	cd terraform/live/cluster && terragrunt run --all --non-interactive -- apply -auto-approve

## Destroys the disposable EKS cluster. Routine, unlike bootstrap-down/persistent-down.
## Requires `make argo-down` to have already cascaded away Argo/Karpenter's
## resources - refuses to run otherwise (see scripts/cluster-down.sh, ADR 0012).
## Configures its own kubeconfig if the cluster exists; skips straight to
## `terragrunt destroy` if it doesn't.
cluster-down:
	./scripts/cluster-down.sh

## Points local kubectl context at the disposable EKS cluster. Every kubectl
## call re-assumes eks-access-identity via --role-arn (baked into the
## generated kubeconfig's exec plugin), so access never depends on whether
## you or GitHub Actions created the cluster - see docs/adr on this.
## Usage: make eks-kubeconfig
eks-kubeconfig:
	aws eks update-kubeconfig --name $(PROJECT_NAME)-eks --region $(PROJECT_REGION) --alias $(PROJECT_NAME)-eks \
		--role-arn "$$(aws iam get-role --role-name eks-access-identity --query Role.Arn --output text)"
	kubectl config set-context --current --namespace=default

## Installs Argo CD and the root Application onto the disposable EKS
## cluster (ADR 0012 - a script, not Terraform), then blocks until the
## whole platform is Synced/Healthy. Run after `make cluster-up`.
argo-up:
	./scripts/argo-up.sh

## Cascades away everything Argo CD manages (Karpenter, CNPG, EBS CSI,
## Postgres CRs, ...), then removes Argo CD itself - before
## `make cluster-down` touches the EKS cluster. Run before
## `make cluster-down`, always. Configures its own kubeconfig (like
## argo-up.sh) after confirming via the AWS API that the cluster exists -
## a CI runner starts with none, and no cluster means nothing to cascade.
argo-down:
	./scripts/argo-down.sh

## Clears every .terragrunt-cache dir under terraform/live/. Run as the
## first step of every composite *-up/*-down target below - a cache left
## over from a different PROJECT_NAME/PROJECT_REGION/SUBDOMAIN bakes its old backend
## config into the cached working directory, which then makes terraform
## refuse to proceed ("Backend configuration has changed").
clear-cache:
	find terraform/live -type d -name .terragrunt-cache -prune -exec rm -rf {} +

## Encrypts a value into secrets/<NAME>.enc using the shared account-global KMS key.
## Usage: make secret-encrypt NAME=test VALUE=secret
secret-encrypt: export SECRET_NAME := $(NAME)
secret-encrypt: export SECRET_VALUE := $(VALUE)
secret-encrypt:
	@./scripts/secret-encrypt.sh

## Decrypts secrets/<NAME>.enc and prints the plaintext to stdout.
## Usage: make secret-decrypt NAME=test
secret-decrypt:
	@./scripts/secret-decrypt.sh "$(NAME)"

## Generates throwaway secrets/$(PROJECT_NAME)/ files for a CI/test
## environment: root-domain from ROOT_DOMAIN and fixed, publicly-known
## passwords ("test"). Never use this for the personal lab - persistent-up
## calls the same script directly (without FIXED_TEST_PASSWORDS) to
## auto-generate real random passwords instead.
## Usage: PROJECT_NAME=vk-lab-ci ROOT_DOMAIN=<domain> make generate-secrets
generate-secrets: export ROOT_DOMAIN := $(ROOT_DOMAIN)
generate-secrets: export FIXED_TEST_PASSWORDS := true
generate-secrets:
	@./scripts/generate-secrets.sh
