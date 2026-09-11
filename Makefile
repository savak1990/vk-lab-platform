.PHONY: up down full-up full-down platform-up platform-down state-up state-down status clusters require-valid-project-name account-up account-down bootstrap-up bootstrap-down secret-encrypt secret-decrypt generate-secrets civo-ca-init persistent-up persistent-down clear-cache cluster-up cluster-down kubeconfig test-kubeconfig argo-up argo-down test

.NOTPARALLEL:

# Lifecycle: state -> bootstrap -> persistence -> cluster -> argo

# Selects the provider's project/stack defaults and dispatch. aws is the
# default; behavior is unchanged from before this variable existed.
export PROVIDER ?= aws
ifeq ($(filter aws civo,$(PROVIDER)),)
$(error PROVIDER must be aws or civo, got '$(PROVIDER)')
endif

# Overridable so CI/integration runs can use a disposable, randomly
# generated name instead of the personal lab's, e.g.
# PROJECT_NAME=vk-lab-ci-1234 make bootstrap-up
ifeq ($(PROVIDER),civo)
export PROJECT_NAME ?= vk-civo-lab
export SUBDOMAIN ?= civo
else
export PROJECT_NAME ?= vk-lab-platform
export SUBDOMAIN ?= lab
endif

# The platform targets exactly one region. Deliberately := and unexported:
# the scripts read it from scripts/lib/region.sh, terragrunt from root.hcl.
REGION := eu-west-1

# The disposable-cluster stack directory; civo uses its own directory,
# never wired into the aws path.
ifeq ($(PROVIDER),civo)
export CLUSTER_DIR := cluster-civo
export PERSISTENT_EXTRA_DIR := persistent-civo
export BOOTSTRAP_EXCLUDE := acm
export PERSISTENT_EXCLUDE := vpc
else
export CLUSTER_DIR := cluster
export PERSISTENT_EXTRA_DIR :=
export BOOTSTRAP_EXCLUDE :=
export PERSISTENT_EXCLUDE :=
endif

## Brings up the cluster + Argo CD onto an existing Persistent layer.
## Fails fast (naming `make persistent-up`) if Persistent doesn't exist yet -
## never creates it (constitution §17). For a from-scratch environment use
## `make full-up`.
up: require-valid-project-name clear-cache cluster-up argo-up

## Tears down Argo CD then the cluster. Does NOT touch Persistent or
## Bootstrap - use `make persistent-down`/`make bootstrap-down` for those.
down: require-valid-project-name clear-cache argo-down cluster-down

## Brings up the entire platform from nothing: Bootstrap (state bucket +
## DNS zone + ACM cert) -> Persistent (VPC + Secrets Manager) -> cluster ->
## Argo CD. Persistent-lifecycle passwords are generated only if missing
## (see persistent-up); root-domain.enc is generated from $ROOT_DOMAIN if
## set and missing, otherwise it must already exist - it's a real domain,
## never randomly generated.
full-up: require-valid-project-name clear-cache bootstrap-up persistent-up cluster-up argo-up

## Tears down the entire platform: Argo CD -> cluster -> Persistent ->
## Bootstrap (DNS zone + ACM cert, then this project's own state bucket).
## Rarely used - persistent-down/bootstrap-down each keep their own guards
## (CONFIRM_DESTROY for bootstrap-down).
full-down: require-valid-project-name clear-cache argo-down cluster-down persistent-down bootstrap-down

## Brings up Persistent + the disposable cluster + Argo CD onto an existing
## State/Bootstrap layer. For cluster+Argo only (Persistent already up) use
## `make up`; for everything from scratch use `make full-up`.
platform-up: require-valid-project-name clear-cache persistent-up cluster-up argo-up

## Tears down Argo CD -> cluster -> Persistent, stopping there. Leaves
## Bootstrap/State untouched. For an environment whose Bootstrap/State must
## survive (e.g. the personal lab) but whose Persistent layer (DNS zone,
## ACM cert, Secrets Manager) is meant to be torn down along with everything
## above it. Reaches persistent-down, so requires CONFIRM_DESTROY=PROJECT_NAME.
platform-down: require-valid-project-name clear-cache argo-down cluster-down persistent-down

## Reports which lifecycle layers currently have state in the shared bucket.
status:
	./scripts/status.sh

## Lists every platform cluster live in the AWS account, across all projects.
clusters:
	./scripts/clusters.sh

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
## bucket, then sets lab.yml's vars.AWS_ROLE_ARN. Run
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
ifeq ($(PROVIDER),civo)
persistent-up:
	./scripts/persistent-up-civo.sh
else
persistent-up:
	./scripts/generate-secrets.sh
	./scripts/require-persistent-secrets.sh
	cd terraform/live/persistent && terragrunt run --all --non-interactive -- apply -auto-approve
endif

## Destroys Persistent-lifecycle resources. Guarded (CONFIRM_DESTROY must
## match PROJECT_NAME), rarely-used - see constitution §17. Also
## permanently deletes every retained EBS volume the ebs-retain
## StorageClass created (spec 005) and every retained Postgres EBS
## snapshot (ADR 0013) - both listed before terragrunt's destroy prompt,
## since they're Persistent-lifecycle data outside any Terraform state.
## Usage: CONFIRM_DESTROY=vk-lab-platform make persistent-down
persistent-down:
	./scripts/persistent-down.sh

## Creates the disposable cluster (system node group + addons, or firewall +
## k3s cluster on civo). Fails fast (naming `make persistent-up`) if the
## Persistent layer doesn't exist yet - never creates it (constitution §17).
## Run `make argo-up` after this to install Argo CD and the platform.
ifeq ($(PROVIDER),civo)
cluster-up:
	./scripts/require-persistent.sh
	@bash -c 'source scripts/lib/region.sh; source scripts/lib/provider.sh; civo_token; cd terraform/live/$(CLUSTER_DIR) && terragrunt run --all --non-interactive -- apply -auto-approve'
else
cluster-up:
	./scripts/require-persistent.sh
	cd terraform/live/$(CLUSTER_DIR) && terragrunt run --all --non-interactive -- apply -auto-approve
endif

## Destroys the disposable EKS cluster. Routine, unlike bootstrap-down/persistent-down.
## Requires `make argo-down` to have already cascaded away Argo/Karpenter's
## resources - refuses to run otherwise (see scripts/cluster-down.sh, ADR 0012).
## Configures its own kubeconfig if the cluster exists; skips straight to
## `terragrunt destroy` if it doesn't.
cluster-down:
	./scripts/cluster-down.sh

## Points local kubectl context at the disposable cluster. On aws, every
## kubectl call re-assumes eks-access-identity via --role-arn (baked into
## the generated kubeconfig's exec plugin), so access never depends on
## whether you or GitHub Actions created the cluster. On civo, merges the
## cluster's kubeconfig and renames its context to $(PROJECT_NAME)-civo (the
## civo CLI has no way to name the context directly). A manual/human
## convenience target only - up/down/argo-up/argo-down/cluster-down/status
## each configure their own kubeconfig internally instead of depending on
## this, since the cluster may not exist yet (or anymore) when those run,
## and a Make prerequisite can't be conditional.
## Usage: make kubeconfig
kubeconfig:
ifeq ($(PROVIDER),civo)
	@bash -c 'source scripts/lib/region.sh; source scripts/lib/provider.sh; configure_kubeconfig'
else
	aws eks update-kubeconfig --name $(PROJECT_NAME)-eks --region $(REGION) --alias $(PROJECT_NAME)-eks \
		--role-arn "$$(aws iam get-role --role-name eks-access-identity --query Role.Arn --output text)"
	kubectl config set-context --current --namespace=default
endif

## Installs Argo CD and the root Application onto the disposable EKS
## cluster (ADR 0012 - a script, not Terraform), then blocks until the
## whole platform is Synced/Healthy. Run after `make cluster-up`.
argo-up:
	./scripts/argo-up.sh

## Points local kubectl context at the disposable EKS cluster via
## eks-test-identity's read-only access (terraform/modules/eks/main.tf +
## gitops rbac/e2e-test-readonly.yaml), NOT eks-access-identity's
## cluster-admin. A distinct alias from kubeconfig's, so the
## cluster-admin kubeconfig entry itself is never overwritten - but running
## `make test` still switches your shell's *current* context to this
## read-only one; run `make kubeconfig` afterward to switch back.
## Usage: make test-kubeconfig
ifeq ($(PROVIDER),civo)
test-kubeconfig:
	@echo "test-kubeconfig for PROVIDER=civo: implemented in a later Civo spec" >&2
	@exit 1
else
test-kubeconfig:
	aws eks update-kubeconfig --name $(PROJECT_NAME)-eks --region $(REGION) --alias $(PROJECT_NAME)-eks-test \
		--role-arn "$$(aws iam get-role --role-name eks-test-identity --query Role.Arn --output text)"
	kubectl config set-context --current --namespace=default
endif

## Runs the black-box E2E suite (tests/e2e) against the disposable cluster.
## Depends on test-kubeconfig so it works standalone, not just chained after
## argo-up/up. Never wired into up/argo-up itself - run explicitly.
## E2E_INSECURE_TLS=1 skips TLS verification of the public endpoints - only
## for a civo cluster on the Let's Encrypt staging issuer (CIVO-070/140).
## Usage: make test | make test-postgres | make test-grafana | make test-argocd
E2E_TLS_FLAG := $(if $(filter 1 true,$(E2E_INSECURE_TLS)),--insecure-skip-tls-verify,)
test: test-kubeconfig
	go test ./tests/e2e/... -v -args --context=$(PROJECT_NAME)-eks-test $(E2E_TLS_FLAG) --ginkgo.v

test-%: test-kubeconfig
	go test ./tests/e2e/... -v -args --context=$(PROJECT_NAME)-eks-test $(E2E_TLS_FLAG) --ginkgo.label-filter=$* --ginkgo.v

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
## over from a different PROJECT_NAME/SUBDOMAIN bakes its old backend
## config into the cached working directory, which then makes terraform
## refuse to proceed ("Backend configuration has changed").
## Rejects a PROJECT_NAME whose derived resource names would be invalid.
## A prerequisite of every composite target, so CI and a local
## `PROJECT_NAME=foo make up` are guarded identically.
require-valid-project-name:
	@bash -c 'source scripts/lib/require-valid-project-name.sh; require_valid_project_name "$$PROJECT_NAME"'

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

## Generates the Roles Anywhere root CA: a public cert (secrets/$(PROJECT_NAME)/civo-ca-cert.pem)
## and its KMS-encrypted private key. Refuses to overwrite; set ROTATE=1 for a rotation candidate.
## Usage: make civo-ca-init [PROJECT_NAME=vk-civo-lab] [ROTATE=1]
civo-ca-init: export PROJECT_NAME := $(PROJECT_NAME)
civo-ca-init: export ROTATE := $(ROTATE)
civo-ca-init:
	@./scripts/civo-ca-init.sh

## Renders gitops/ and gitops/bootstrap/ for aws/civo/local and verifies:
## the aws render against the committed golden baseline (tests/golden/gitops-aws),
## and civo/local structurally (expected objects present, aws-only kinds absent).
## Usage: make gitops-check
gitops-check:
	@./scripts/gitops-render-check.sh check
