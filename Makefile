.PHONY: up down full-up full-down platform-up platform-down state-up state-down status clusters require-valid-project-name require-valid-node-config require-valid-recover-from account-up account-down bootstrap-up bootstrap-down secret-encrypt secret-decrypt secrets-check node-config-check scripts-check generate-secrets ca-init ssh-key-init persistent-up persistent-down clear-cache cluster-up cluster-down park unpark kubeconfig node-ssh test-kubeconfig test-kubeconfig-isolated argo-up argo-down test go-check terraform-check forward-up forward-down

.NOTPARALLEL:

# Lifecycle: state -> bootstrap -> persistence -> cluster -> argo

# Selects the provider's project/stack defaults and dispatch. aws is the
# default; behavior is unchanged from before this variable existed.
export PROVIDER ?= aws
ifeq ($(filter aws civo hetzner local,$(PROVIDER)),)
$(error PROVIDER must be aws, civo, hetzner or local, got '$(PROVIDER)')
endif

# Overridable so CI/integration runs can use a disposable, randomly
# generated name instead of the personal lab's, e.g.
# PROJECT_NAME=vk-lab-ci-1234 make bootstrap-up
ifeq ($(PROVIDER),civo)
export PROJECT_NAME ?= vk-civo-lab
export SUBDOMAIN ?= civo
else ifeq ($(PROVIDER),hetzner)
export PROJECT_NAME ?= vk-hetzner-lab
export SUBDOMAIN ?= hz
else ifeq ($(PROVIDER),local)
export PROJECT_NAME ?= vk-local-lab
export SUBDOMAIN ?= local
else
export PROJECT_NAME ?= vk-lab-platform
export SUBDOMAIN ?= lab
endif

# Starts this bring-up from another target's backup archive, named as
# s3://<bucket>/<generation>. Exported so both `RECOVER_FROM=x make up` and
# `make up RECOVER_FROM=x` reach the scripts. Empty on an ordinary run.
export RECOVER_FROM ?=

# The cluster's shape, mirroring scripts/lib/catalog.sh. Exported because
# several recipes call terragrunt directly and never source provider.sh,
# so get_env() would otherwise see nothing. local takes none of these.
# require-valid-node-config rejects a value outside the catalogue; the
# canonical spelling is resolved in provider.sh, not here.
ifeq ($(PROVIDER),civo)
export REGION ?= LON1
export WORKER_NODE_TYPE ?= g4s.kube.medium
export MIN_WORKER_NODES ?= 3
export MAX_WORKER_NODES ?= 4
else ifeq ($(PROVIDER),hetzner)
export REGION ?= fsn1
# No WORKER_NODE_TYPE literal: hetzner's default depends on the region, since
# hel1 does not sell cx43, and every hetzner recipe reaches terragrunt through
# provider.sh, which resolves it. A literal here would override that and make
# REGION=hel1 fail the gate on a type the operator never chose.
export MIN_WORKER_NODES ?= 1
export MAX_WORKER_NODES ?= 2
export CONTROL_PLANE_NODE_TYPE ?= cx23
else ifeq ($(PROVIDER),local)
else
export REGION ?= eu-west-1
export WORKER_NODE_TYPE ?= t4g.medium
export MIN_WORKER_NODES ?= 1
export MAX_WORKER_NODES ?= 3
endif

# Repo-local kubeconfigs, one per identity so the read-only test context can
# never overwrite the cluster-admin one. Every target except `kubeconfig` and
# `test-kubeconfig` works through these, so a lifecycle run leaves the
# operator's own current context alone (constitution §17).
# Absolute: `go test` runs each test binary with its own package directory as
# the working directory, so a relative path would resolve under tests/e2e/.
LAB_KUBECONFIG := $(CURDIR)/.kube/$(PROJECT_NAME).config
LAB_TEST_KUBECONFIG := $(CURDIR)/.kube/$(PROJECT_NAME)-test.config

# The disposable-cluster stack directory; civo and hetzner each use their
# own directory, never wired into the aws path.
ifeq ($(PROVIDER),civo)
export CLUSTER_DIR := cluster-civo
export PERSISTENT_EXTRA_DIR := persistent-civo
export BOOTSTRAP_EXCLUDE := acm
export PERSISTENT_EXCLUDE := vpc backups
else ifeq ($(PROVIDER),hetzner)
export CLUSTER_DIR := cluster-hetzner
export PERSISTENT_EXTRA_DIR := persistent-hetzner
export BOOTSTRAP_EXCLUDE := acm
export PERSISTENT_EXCLUDE := vpc
else ifeq ($(PROVIDER),local)
export CLUSTER_DIR :=
export PERSISTENT_EXTRA_DIR :=
export BOOTSTRAP_EXCLUDE :=
export PERSISTENT_EXCLUDE :=
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
up: require-valid-project-name require-valid-node-config require-valid-recover-from clear-cache cluster-up argo-up

## Tears down Argo CD then the cluster. Does NOT touch Persistent or
## Bootstrap - use `make persistent-down`/`make bootstrap-down` for those.
down: require-valid-project-name require-valid-node-config clear-cache argo-down cluster-down

## Brings up the entire platform from nothing: Bootstrap (state bucket +
## DNS zone + ACM cert) -> Persistent (VPC + Secrets Manager) -> cluster ->
## Argo CD. Persistent-lifecycle passwords are generated only if missing
## (see persistent-up); root-domain.enc is generated from $ROOT_DOMAIN if
## set and missing, otherwise it must already exist - it's a real domain,
## never randomly generated.
full-up: require-valid-project-name require-valid-node-config require-valid-recover-from clear-cache bootstrap-up persistent-up cluster-up argo-up

## Tears down the entire platform: Argo CD -> cluster -> Persistent ->
## Bootstrap (DNS zone + ACM cert, then this project's own state bucket).
## Rarely used - persistent-down/bootstrap-down each keep their own guards
## (CONFIRM_DESTROY for bootstrap-down).
full-down: require-valid-project-name require-valid-node-config clear-cache argo-down cluster-down persistent-down bootstrap-down

## Brings up Persistent + the disposable cluster + Argo CD onto an existing
## State/Bootstrap layer. For cluster+Argo only (Persistent already up) use
## `make up`; for everything from scratch use `make full-up`.
platform-up: require-valid-project-name require-valid-node-config require-valid-recover-from clear-cache persistent-up cluster-up argo-up

## Tears down Argo CD -> cluster -> Persistent, stopping there. Leaves
## Bootstrap/State untouched. For an environment whose Bootstrap/State must
## survive (e.g. the personal lab) but whose Persistent layer (DNS zone,
## ACM cert, Secrets Manager) is meant to be torn down along with everything
## above it. Reaches persistent-down, so requires CONFIRM_DESTROY=PROJECT_NAME.
platform-down: require-valid-project-name require-valid-node-config clear-cache argo-down cluster-down persistent-down

## Reports which lifecycle layers currently have state in the shared bucket.
status:
	./scripts/status.sh

## Lists every platform cluster live on every provider, across all projects.
clusters:
	./scripts/clusters.sh

## Creates this project's own state bucket directly. Usually invoked via
## `make bootstrap-up`, not directly - kept as its own target for manual/
## debugging use.
state-up: clear-cache
	./scripts/state-up.sh

## Destroys this project's own state bucket directly. Usually invoked via
## `make bootstrap-down`, not directly - kept as its own target for manual/
## debugging use. Only for ci/cd or a full manual teardown.
state-down: clear-cache
	./scripts/state-down.sh

## Creates account-global resources (shared secrets KMS key, shared lab-role,
## GitHub OIDC provider, eks-access-identity) in their own dedicated state
## bucket, then sets lab.yml's vars.AWS_ROLE_ARN. Run
## once per AWS account - deliberately in no composite target.
account-up: clear-cache
	./scripts/account-up.sh

## Destroys account-global resources, including their own dedicated state
## bucket. Guarded (CONFIRM_DESTROY), expected to run essentially never -
## every project in the account shares these.
account-down: clear-cache
	./scripts/account-down.sh

## Creates Bootstrap-lifecycle resources for this project: its own state
## bucket, then the lab DNS zone/delegation + ACM cert.
ifeq ($(PROVIDER),local)
bootstrap-up: clear-cache
	@echo "PROVIDER=local owns no cloud resources - nothing to create."
else
bootstrap-up: clear-cache
	./scripts/bootstrap-up.sh
endif

## Destroys Bootstrap-lifecycle resources for this project: the DNS zone/
## cert, then its own state bucket. Guarded (CONFIRM_DESTROY must match
## PROJECT_NAME) and refuses while Persistent/Disposable state still exists.
ifeq ($(PROVIDER),local)
bootstrap-down: clear-cache
	@echo "PROVIDER=local owns no cloud resources - nothing to destroy."
else
bootstrap-down: clear-cache
	./scripts/bootstrap-down.sh
endif

## Creates Persistent-lifecycle resources (VPC, Secrets Manager).
## Auto-generates postgres-app-password.enc / grafana-admin-password.enc /
## argocd-admin-password.bcrypt if missing (never overwrites an existing
## one - see ADR 0014); bootstrap-up already generates/requires these plus
## root-domain, so this is normally a no-op repeat.
ifeq ($(PROVIDER),civo)
persistent-up: clear-cache require-valid-node-config
	./scripts/persistent-up-civo.sh
else ifeq ($(PROVIDER),hetzner)
persistent-up: clear-cache require-valid-node-config
	./scripts/persistent-up-hetzner.sh
else ifeq ($(PROVIDER),local)
persistent-up: clear-cache require-valid-node-config
	@echo "PROVIDER=local owns no cloud resources - nothing to create."
else
persistent-up: clear-cache require-valid-node-config
	./scripts/generate-secrets.sh
	./scripts/require-persistent-secrets.sh
	cd terraform/live/persistent && terragrunt run --all --non-interactive -- apply -auto-approve
endif

## Destroys Persistent-lifecycle resources. Guarded (CONFIRM_DESTROY must
## match PROJECT_NAME), rarely-used - see constitution §17. Also
## empties the Postgres backup bucket and permanently deletes every
## retained EBS volume the ebs-retain StorageClass created (spec 005) and
## any Postgres EBS snapshot left from before ADR 0033 - listed before the
## destroy, since they're Persistent-lifecycle data.
## Usage: CONFIRM_DESTROY=vk-lab-platform make persistent-down
ifeq ($(PROVIDER),local)
persistent-down: clear-cache require-valid-node-config
	@echo "PROVIDER=local owns no cloud resources - nothing to destroy."
else
persistent-down: clear-cache require-valid-node-config
	./scripts/persistent-down.sh
endif

## Creates the disposable cluster (system node group + addons, or firewall +
## k3s cluster on civo). Fails fast (naming `make persistent-up`) if the
## Persistent layer doesn't exist yet - never creates it (constitution §17).
## Run `make argo-up` after this to install Argo CD and the platform.
ifeq ($(PROVIDER),civo)
cluster-up: clear-cache require-valid-node-config
	./scripts/require-persistent.sh
	@bash -c 'source scripts/lib/region.sh; source scripts/lib/provider.sh; civo_token; cd terraform/live/$(CLUSTER_DIR) && terragrunt run --all --non-interactive -- apply -auto-approve'
else ifeq ($(PROVIDER),hetzner)
cluster-up: clear-cache require-valid-node-config
	./scripts/require-persistent.sh
	@bash -c 'source scripts/lib/region.sh; source scripts/lib/provider.sh; hcloud_token; use_isolated_kubeconfig; cd terraform/live/$(CLUSTER_DIR) && terragrunt run --all --non-interactive -- apply -auto-approve && configure_kubeconfig "$$KUBECONFIG" && wait_for_nodes_ready'
else ifeq ($(PROVIDER),local)
cluster-up: clear-cache require-valid-node-config
	./scripts/cluster-up-local.sh
else
cluster-up: clear-cache require-valid-node-config
	./scripts/require-persistent.sh
	cd terraform/live/$(CLUSTER_DIR) && terragrunt run --all --non-interactive -- apply -auto-approve
endif

## Destroys the disposable EKS cluster. Routine, unlike bootstrap-down/persistent-down.
## Requires `make argo-down` to have already cascaded away Argo/Karpenter's
## resources - refuses to run otherwise (see scripts/cluster-down.sh, ADR 0012).
## Configures its own kubeconfig if the cluster exists; skips straight to
## `terragrunt destroy` if it doesn't.
ifeq ($(PROVIDER),local)
cluster-down: clear-cache
	./scripts/cluster-down-local.sh
else
cluster-down: clear-cache
	./scripts/cluster-down.sh
endif

## Takes the worker nodes to zero, leaving the control plane, etcd, every Argo CD
## object, the volumes and the load balancer with its DNS records untouched. The
## cluster still answers kubectl and schedules nothing, so every platform
## workload goes Pending - Postgres included. Cheaper than running and far
## quicker to leave than a bring-up, but not cheaper than `make down`: park for
## hours, tear down for weeks. Hetzner only; the other targets refuse and say why.
## Usage: PROVIDER=hetzner make park
park:
	./scripts/park.sh park

## Brings the workers back after `make park`. The re-created worker rejoins with
## the join token Terraform already holds, so there is no restore and no
## operator step; Argo CD reschedules the platform once the node is Ready.
## Usage: PROVIDER=hetzner make unpark
unpark:
	./scripts/park.sh unpark

## Switches your own kubectl context to the disposable cluster. On aws, every
## kubectl call re-assumes eks-access-identity via --role-arn (baked into
## the generated kubeconfig's exec plugin), so access never depends on
## whether you or GitHub Actions created the cluster. On civo, merges the
## cluster's kubeconfig and renames its context to $(PROJECT_NAME)-civo (the
## civo CLI has no way to name the context directly). On local, exports the
## kind cluster's context (kind-$(PROJECT_NAME)) - a bring-up leaves it out of
## your kubeconfig entirely, so run this once to get a context to switch to.
## Note for local: teardown works through $(LAB_KUBECONFIG), so a context this
## target adds here outlives the cluster - delete it yourself, or skip this
## target entirely and use `make forward-up`, which needs no context at all.
## This target and test-kubeconfig are the only two that write ~/.kube/config
## or change your current context. up/down/argo-up/argo-down/cluster-down/
## status/test all work through $(LAB_KUBECONFIG) instead, so a bring-up never
## moves your kubectl off whatever cluster you are working on.
## Usage: make kubeconfig
kubeconfig:
	@bash -c 'source scripts/lib/region.sh; source scripts/lib/provider.sh; configure_kubeconfig'

## Opens a root shell on a Hetzner node. NODE defaults to the control plane.
## The SSH key is decrypted into a temp directory the call removes on exit,
## including on Ctrl-C, so no private key is ever left on disk.
## Usage: make node-ssh [NODE=$(PROJECT_NAME)-worker-1]
export NODE ?= $(PROJECT_NAME)-cp-1
node-ssh:
	@bash -c 'source scripts/lib/region.sh; source scripts/lib/provider.sh; \
	  if [ "$$PROVIDER" != "hetzner" ]; then echo "node-ssh: not applicable for PROVIDER=$$PROVIDER"; exit 0; fi; \
	  hcloud_token; \
	  ip="$$(hcloud_cli server ip "$$NODE" 2>/dev/null)" || { echo "node-ssh: no server named $$NODE" >&2; exit 1; }; \
	  hetzner_ssh "$$ip"'

## Installs Argo CD and the root Application onto the disposable EKS
## cluster (ADR 0012 - a script, not Terraform), then blocks until the
## whole platform is Synced/Healthy. Run after `make cluster-up`.
argo-up: clear-cache
	./scripts/argo-up.sh

## Switches your own kubectl context to the disposable cluster as the E2E
## suite's read-only identity (rbac/e2e-test-readonly.yaml), never
## cluster-admin. On aws, eks-test-identity maps to that role via its EKS
## access entry (terraform/modules/eks/main.tf). On civo and local, which have
## no IAM, it mints a 1h token for the e2e/e2e-test ServiceAccount.
## A distinct context name ($(E2E_CONTEXT)), so the cluster-admin entry is
## never overwritten. `make test` does NOT use this target - it builds the same
## read-only identity in $(LAB_TEST_KUBECONFIG) and leaves your context alone.
## Usage: make test-kubeconfig
E2E_CONTEXT := $(if $(filter aws,$(PROVIDER)),$(PROJECT_NAME)-eks-test,$(PROJECT_NAME)-$(PROVIDER)-test)
test-kubeconfig:
	@bash -c 'source scripts/lib/region.sh; source scripts/lib/provider.sh; configure_test_kubeconfig'

## Runs the black-box E2E suite (tests/e2e) against the disposable cluster.
## Builds its own read-only kubeconfig so it works standalone, not just chained
## after argo-up/up. Never wired into up/argo-up itself - run explicitly.
## The kubeconfig is passed by path on each recipe line rather than inherited:
## an export made in one recipe line's shell never reaches the next one.
## E2E_INSECURE_TLS=1 skips TLS verification of the public endpoints - only
## for a civo cluster on the Let's Encrypt staging issuer (CIVO-070/140).
## Usage: make test | make test-postgres | make test-grafana | make test-argocd
E2E_TLS_FLAG := $(if $(filter 1 true,$(E2E_INSECURE_TLS)),--insecure-skip-tls-verify,)
## The suite package only. ./tests/e2e/... would hand --context to the
## framework's own test binary too, which does not define it.
test: test-kubeconfig-isolated
	KUBECONFIG=$(LAB_TEST_KUBECONFIG) go test ./tests/e2e -v -args --context=$(E2E_CONTEXT) $(E2E_TLS_FLAG) --ginkgo.v

test-%: test-kubeconfig-isolated
	KUBECONFIG=$(LAB_TEST_KUBECONFIG) go test ./tests/e2e -v -args --context=$(E2E_CONTEXT) $(E2E_TLS_FLAG) --ginkgo.label-filter=$* --ginkgo.v

## Forwards the gateway to localhost in the background so Argo CD and Grafana
## open in a browser. Works through $(LAB_KUBECONFIG), so it neither reads nor
## changes your own kubectl context - `make kubeconfig` is not needed first.
## LOCAL_PORT overrides the default 8080. local only: the others are on DNS.
## Usage: PROVIDER=local make forward-up
forward-up:
	./scripts/forward-up-local.sh

## Stops the forward `make forward-up` started. Safe when nothing is up.
## Usage: PROVIDER=local make forward-down
forward-down:
	./scripts/forward-down-local.sh

## Formats, then validates every Terraform module and every live unit that
## runs without a backend. Needs no cluster and no credentials - every init
## is -backend=false. PARALLEL=<n> sets how many run at once (default 4,
## matching the CI runner).
## Usage: make terraform-check
terraform-check:
	./scripts/terraform-check.sh

## Compiles and vets every Go package, and runs the E2E framework's own
## offline tests. Needs no cluster and no credentials.
## Usage: make go-check
go-check:
	go vet ./...
	go test ./tests/e2e/framework/...
	@echo "GO-CHECK: the Go layer is valid."

## Internal: the same read-only identity as test-kubeconfig, written to
## $(LAB_TEST_KUBECONFIG) instead of your own kubeconfig.
test-kubeconfig-isolated:
	@bash -c 'source scripts/lib/region.sh; source scripts/lib/provider.sh; use_isolated_kubeconfig $(LAB_TEST_KUBECONFIG); configure_test_kubeconfig "$$KUBECONFIG"'

## Cascades away everything Argo CD manages (Karpenter, CNPG, EBS CSI,
## Postgres CRs, ...), then removes Argo CD itself - before
## `make cluster-down` touches the EKS cluster. Run before
## `make cluster-down`, always. Configures its own kubeconfig (like
## argo-up.sh) after confirming via the AWS API that the cluster exists -
## a CI runner starts with none, and no cluster means nothing to cascade.
argo-down: clear-cache
	./scripts/argo-down.sh

## Clears every .terragrunt-cache dir under terraform/live/. A prerequisite of
## every lifecycle target, composite and standalone alike, so it runs once per
## invocation whichever one you call - a cache left over from a different
## PROJECT_NAME/SUBDOMAIN bakes its old backend config into the cached working
## directory, which then makes terraform refuse to proceed ("Backend
## configuration has changed").
## Rejects a PROJECT_NAME whose derived resource names would be invalid.
## A prerequisite of every composite target, so CI and a local
## `PROJECT_NAME=foo make up` are guarded identically.
require-valid-project-name:
	@bash -c 'source scripts/lib/require-valid-project-name.sh; require_valid_project_name "$$PROJECT_NAME"'

## Refuses a NODE_COUNT/NODE_TYPE/REGION combination this platform will not
## order, before any cloud call and without credentials. See
## scripts/lib/catalog.sh for the allowed shapes and why each is there.
require-valid-node-config:
	@bash -c 'source scripts/lib/require-valid-node-config.sh; require_valid_node_config'

## Rejects a RECOVER_FROM that is not s3://<bucket>/<generation>, before any
## cloud call. Unset on an ordinary bring-up; see scripts/lib for the shape
## and why this one fails closed.
require-valid-recover-from:
	@bash -c 'source scripts/lib/require-valid-recover-from.sh; require_valid_recover_from'

clear-cache:
	find terraform/live -type d -name .terragrunt-cache -prune -exec rm -rf {} +

## Encrypts a value with the shared account-global KMS key into
## secrets/$(PROJECT_NAME)/<NAME>.enc (SCOPE=project, the default) or
## secrets/<NAME>.enc (SCOPE=global: one value for every project in the account).
## Usage: make secret-encrypt NAME=test VALUE=secret [SCOPE=global]
secret-encrypt: export SECRET_NAME := $(NAME)
secret-encrypt: export SECRET_VALUE := $(VALUE)
secret-encrypt: export SECRET_SCOPE := $(SCOPE)
secret-encrypt:
	@./scripts/secret-encrypt.sh

## Decrypts secrets/$(PROJECT_NAME)/<NAME>.enc (SCOPE=project, the default) or
## secrets/<NAME>.enc (SCOPE=global) and prints the plaintext to stdout.
## Usage: make secret-decrypt NAME=test [SCOPE=global]
secret-decrypt: export SECRET_SCOPE := $(SCOPE)
secret-decrypt:
	@./scripts/secret-decrypt.sh "$(NAME)"

## Runs the KMS-free path-resolution test for secret-encrypt/secret-decrypt.
## Usage: make secrets-check
secrets-check:
	@./tests/scripts/secret-scope-test.sh

## Runs the credential-free test of the node-configuration gate: which
## PROVIDER/REGION pairs it accepts, and that aws refuses a region.
## Usage: make node-config-check
node-config-check:
	@./tests/scripts/node-config-test.sh

## Runs the cluster-free test of argo-up's root watch loop (API blips,
## failed syncs, heartbeat, timeout) against a fake kubectl.
## Usage: make argo-watch-check
argo-watch-check:
	@./tests/scripts/argo-watch-test.sh

## Runs pr-gate's decision step against label and job-result combinations,
## with no GitHub involved. Usage: make pr-gate-check
pr-gate-check:
	@./tests/scripts/pr-gate-test.sh

## Reads argo-up.sh and asserts every provider dispatch names every supported
## provider, so no target can reach a `*)` mid-bring-up. Needs no cloud.
## Usage: make argo-up-dispatch-check
argo-up-dispatch-check:
	@./tests/scripts/argo-up-dispatch-test.sh

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

## Generates the Roles Anywhere root CA: a public cert (secrets/$(PROJECT_NAME)/$(PROVIDER)-ca-cert.pem)
## and its KMS-encrypted private key. Refuses to overwrite; set ROTATE=1 for a rotation candidate.
## Usage: PROVIDER=civo|hetzner make ca-init [PROJECT_NAME=vk-civo-lab] [ROTATE=1]
ca-init: export PROJECT_NAME := $(PROJECT_NAME)
ca-init: export ROTATE := $(ROTATE)
ca-init:
	@./scripts/ca-init.sh

## Generates the Hetzner node SSH key: a public key (secrets/$(PROJECT_NAME)/hetzner-ssh-key.pub)
## and its KMS-encrypted private key. Refuses to overwrite; set ROTATE=1 for a rotation candidate.
## Usage: PROVIDER=hetzner make ssh-key-init [PROJECT_NAME=vk-hetzner-lab] [ROTATE=1]
ssh-key-init: export PROJECT_NAME := $(PROJECT_NAME)
ssh-key-init: export ROTATE := $(ROTATE)
ssh-key-init:
	@./scripts/ssh-key-init.sh

## Renders gitops/ and gitops/bootstrap/ for aws/civo/local and verifies:
## the aws render against the committed golden baseline (tests/golden/gitops-aws),
## and civo/local structurally (expected objects present, aws-only kinds absent).
## Usage: make gitops-check
gitops-check:
	@./scripts/gitops-render-check.sh check

## Checks specs/ layout: status letters match front matter, links resolve,
## no old spec paths remain. Usage: make specs-check
specs-check:
	@./scripts/specs-check.sh

## Parses every script with bash -n, lints it with shellcheck, then runs every
## tests/scripts/*-test.sh. Usage: make scripts-check
scripts-check:
	@./scripts/scripts-check.sh
