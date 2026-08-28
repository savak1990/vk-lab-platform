.PHONY: up down full-up full-down state-up state-down status account-up account-down bootstrap-up bootstrap-down secret-encrypt secret-decrypt generate-secrets persistent-up persistent-down clear-cache cluster-up cluster-down eks-kubeconfig argo-up argo-down

.NOTPARALLEL:

# Lifecycle: state -> bootstrap -> persistence -> cluster -> argo

# Overridable so CI/integration runs can use a disposable, randomly
# generated name instead of the personal lab's, e.g.
# PROJECT_NAME=vk-lab-ci-1234 make bootstrap-up
export PROJECT_NAME ?= vk-lab-platform

# Overridable to run the whole platform in another AWS region, e.g.
# REGION=us-east-1 make bootstrap-up
export REGION ?= eu-west-1

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

## Brings up the entire platform from nothing: State -> Bootstrap ->
## Persistent -> cluster -> Argo CD. Persistent-lifecycle passwords are
## generated only if missing (see persistent-up); root-domain.enc is
## generated from $ROOT_DOMAIN if set and missing, otherwise it must
## already exist - it's a real domain, never randomly generated.
full-up: clear-cache state-up bootstrap-up persistent-up cluster-up argo-up

## Tears down the entire platform: Argo CD -> cluster -> Persistent ->
## Bootstrap -> State. Rarely used - persistent-down/bootstrap-down/
## state-down each keep their own explicit confirmation prompts.
full-down: clear-cache argo-down cluster-down persistent-down bootstrap-down state-down

## Reports which lifecycle layers currently have state in the shared bucket.
status:
	./scripts/status.sh

## Creates the State layer. Run once, first, expected that it should never be re-run.
state-up:
	./scripts/state-up.sh

## Destroys the State layer. Expected to never be run for real. Only for ci/cd.
state-down:
	./scripts/state-down.sh

## Creates account-global resources (GitHub OIDC provider). Run once per AWS
## account with the primary PROJECT_NAME - deliberately in no composite target.
account-up:
	./scripts/account-up.sh

## Destroys account-global resources. Guarded, expected to run essentially
## never - the provider is shared by every project in the account.
account-down:
	./scripts/account-down.sh

## Creates bootstrap-lifecycle resources.
bootstrap-up:
	./scripts/require-state.sh
	cd terraform/live/bootstrap && terragrunt run --all apply --non-interactive

## Destroys bootstrap-lifecycle resources.
bootstrap-down:
	./scripts/bootstrap-down.sh

## Creates Persistent-lifecycle resources (lab DNS zone + delegation, ACM
## cert, Secrets Manager). Auto-generates postgres-app-password.enc /
## grafana-admin-password.enc / argocd-admin-password.bcrypt if missing
## (never overwrites an existing one - see ADR 0014). root-domain.enc is
## generated from $ROOT_DOMAIN if set and missing, otherwise it must
## already exist. require-unique-subdomain guards against two PROJECT_NAME
## environments sharing SUBDOMAIN.<root-domain> - see that script for why.
persistent-up:
	./scripts/generate-secrets.sh
	./scripts/require-persistent-secrets.sh
	./scripts/require-unique-subdomain.sh
	cd terraform/live/persistent && terragrunt run --all apply --non-interactive

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
	cd terraform/live/disposable && terragrunt run --all apply --non-interactive

## Destroys the disposable EKS cluster. Routine, unlike bootstrap-down/persistent-down.
## Requires `make argo-down` to have already cascaded away Argo/Karpenter's
## resources - refuses to run otherwise (see scripts/cluster-down.sh, ADR 0012).
cluster-down:
	./scripts/cluster-down.sh

## Points local kubectl context at the disposable EKS cluster.
## Usage: make eks-kubeconfig
eks-kubeconfig:
	aws eks update-kubeconfig --name $(PROJECT_NAME)-eks --region $(REGION) --alias $(PROJECT_NAME)-eks
	kubectl config set-context --current --namespace=default

## Installs Argo CD and the root Application onto the disposable EKS
## cluster (ADR 0012 - a script, not Terraform), then blocks until the
## whole platform is Synced/Healthy. Run after `make cluster-up`.
argo-up:
	./scripts/argo-up.sh

## Cascades away everything Argo CD manages (Karpenter, CNPG, EBS CSI,
## Postgres CRs, ...), then removes Argo CD itself - before
## `make cluster-down` touches the EKS cluster. Run before
## `make cluster-down`, always.
argo-down:
	./scripts/argo-down.sh

## Clears every .terragrunt-cache dir under terraform/live/. Run manually
## after switching PROJECT_NAME/REGION/SUBDOMAIN - a cache left over from a
## different value bakes its old backend config into the cached working
## directory, which then makes terraform refuse to proceed ("Backend
## configuration has changed"). Not run automatically by any *-up/*-down
## target; run this yourself first when you know you're switching.
clear-cache:
	find terraform/live -type d -name .terragrunt-cache -prune -exec rm -rf {} +

## Encrypts a value into secrets/<NAME>.enc using the bootstrap KMS key.
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
