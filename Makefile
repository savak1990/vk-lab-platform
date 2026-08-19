.PHONY: state-up state-down status bootstrap-up bootstrap-down secret-encrypt secret-decrypt

# Lifecycle: state -> boostrap -> persistence -> disposable

# Overridable so CI/integration runs can use a disposable, randomly
# generated name instead of the personal lab's, e.g.
# PROJECT_NAME=vk-lab-ci-1234 make bootstrap-up
export PROJECT_NAME ?= vk-lab-platform

# Overridable to run the whole platform in another AWS region, e.g.
# REGION=us-east-1 make bootstrap-up
export REGION ?= eu-west-1

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
	./scripts/bootstrap-up.sh

## Destroys bootstrap-lifecycle resources.
bootstrap-down:
	./scripts/bootstrap-down.sh

## Encrypts a value into secrets/<NAME>.enc using the bootstrap KMS key.
## Usage: make secret-encrypt NAME=test VALUE=secret
secret-encrypt: export SECRET_NAME := $(NAME)
secret-encrypt: export SECRET_VALUE := $(VALUE)
secret-encrypt:
	./scripts/secret-encrypt.sh

## Decrypts secrets/<NAME>.enc and prints the plaintext to stdout.
## Usage: make secret-decrypt NAME=test
secret-decrypt:
	./scripts/secret-decrypt.sh "$(NAME)"
