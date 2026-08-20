.PHONY: state-up state-down status bootstrap-up bootstrap-down secret-encrypt secret-decrypt generate-secrets persistent-up persistent-down clear-cache disposable-up disposable-down eks-kubeconfig

# Lifecycle: state -> boostrap -> persistence -> disposable

# Overridable so CI/integration runs can use a disposable, randomly
# generated name instead of the personal lab's, e.g.
# PROJECT_NAME=vk-lab-ci-1234 make bootstrap-up
export PROJECT_NAME ?= vk-lab-platform

# Overridable to run the whole platform in another AWS region, e.g.
# REGION=us-east-1 make bootstrap-up
export REGION ?= eu-west-1

# Overridable subdomain delegated from the root domain, e.g. lab.<root-domain>.
export SUBDOMAIN ?= lab

## Reports which lifecycle layers currently have state in the shared bucket.
status:
	./scripts/status.sh

## Creates the State layer. Run once, first, expected that it should never be re-run.
state-up:
	./scripts/state-up.sh

## Destroys the State layer. Expected to never be run for real. Only for ci/cd.
state-down:
	./scripts/state-down.sh

## Creates bootstrap-lifecycle resources.
bootstrap-up:
	./scripts/require-state.sh
	cd terraform/live/bootstrap && terragrunt run --all apply --non-interactive

## Destroys bootstrap-lifecycle resources.
bootstrap-down:
	./scripts/bootstrap-down.sh

## Creates Persistent-lifecycle resources (lab DNS zone + delegation, ACM cert, Secrets Manager).
persistent-up:
	./scripts/require-persistent-secrets.sh
	cd terraform/live/persistent && terragrunt run --all apply --non-interactive

## Destroys Persistent-lifecycle resources. Guarded, rarely-used - see constitution §17.
persistent-down:
	./scripts/persistent-down.sh

## Creates Disposable-lifecycle resources (EKS cluster + system node group + addons).
disposable-up:
	cd terraform/live/disposable && terragrunt run --all apply --non-interactive

## Destroys Disposable-lifecycle resources. Routine, unlike bootstrap-down/persistent-down.
disposable-down:
	cd terraform/live/disposable && terragrunt run --all destroy --non-interactive

## Points local kubectl context at the disposable EKS cluster.
## Usage: make eks-kubeconfig
eks-kubeconfig:
	aws eks update-kubeconfig --name $(PROJECT_NAME)-eks --region $(REGION) --alias $(PROJECT_NAME)-eks

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
## environment: root-domain from ROOT_DOMAIN, and a fixed, publicly-known
## postgres-admin-password ("test"). Never use this for the personal lab.
## Usage: PROJECT_NAME=vk-lab-ci ROOT_DOMAIN=<domain> make generate-secrets
generate-secrets: export ROOT_DOMAIN := $(ROOT_DOMAIN)
generate-secrets:
	@./scripts/generate-secrets.sh
