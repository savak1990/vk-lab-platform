# ADR 0030: Civo API token handling

## Status

Accepted

## Context

Constitution §5 requires GitHub Actions to authenticate to AWS through
OIDC and temporary credentials, and forbids long-lived AWS access keys.
`CIVO_TOKEN` is not an AWS credential, so that specific rule is not
literally engaged — but it is itself a long-lived static API key
(Civo has no OIDC-style federated-identity offering to exchange it for
something short-lived), and it grants cluster-admin on the Civo k3s
cluster (ADR 0029), so it needs handling hygiene equivalent to what this
repository already applies to other committed secret material.

ADR 0023 established the pattern this repository uses for exactly this
shape of problem: one committed KMS ciphertext file per secret, named
after its contents, decrypted at script run time, never combined with
another secret in one file.

## Decision

**The Civo API token is a static key, handled by the existing
committed-ciphertext pattern**, not a new mechanism. It is KMS-encrypted
to `secrets/civo-token.enc` — flat under `secrets/`, alongside
`secrets/root-domain.enc`, not nested under a per-project directory.
This matches what is already on disk: account-wide/cross-project secrets
(`root-domain.enc`, `civo-token.enc`) live flat under `secrets/`, while
secrets scoped to one AWS project live under `secrets/<project>/` (e.g.
`secrets/vk-lab-platform/postgres-app-password.enc`) — `civo-token.enc`
follows the flat convention because the token is not project-scoped
config. Scripts decrypt it at run time, the same way `secrets/root-domain.enc`
and other committed ciphertexts are already decrypted (ADR 0023). CI
masks the decrypted value in logs.

**Rotation is: regenerate the token in Civo's console, re-encrypt it,
commit the new ciphertext.** No in-repo rotation automation — this
mirrors how every other KMS-encrypted secret in this repository is
rotated.

**The cluster autoscaler (spec CIVO-170) needs its own in-cluster API
key, held as a separate ciphertext file (`secrets/civo-autoscaler-token.enc`),
not the operator's token reused.** An in-cluster credential and an
operator-workstation/CI credential are different trust boundaries; giving
the autoscaler its own dedicated key keeps a cluster-side Secret read
from also compromising the operator's ability to manage the whole Civo
account from outside the cluster.

**Constitution §5's "no long-lived AWS credential" rule is not
violated** — `CIVO_TOKEN` is not an AWS credential, and every AWS-facing
identity from Civo workloads goes through Roles Anywhere (ADR 0029), not
through `CIVO_TOKEN`. This ADR states the principle explicitly so the
distinction is not left implicit: `CIVO_TOKEN` is a long-lived credential
by necessity, handled with the same KMS discipline as every other
committed secret, and is a separate concern from the AWS-credential rule
the constitution actually states.

**Alternatives considered:**

a. **A JWT/short-lived-token exchange in front of the static key.**
   Rejected — Civo offers no federated-identity issuer to exchange
   against, so any such exchange would itself need a long-lived key to
   bootstrap it. That adds an indirection layer with no hygiene
   improvement over encrypting the static key directly.
b. **Storing the token only as a GitHub Actions secret, uncommitted.**
   Rejected — inconsistent with every other secret in this repository
   (ADR 0023's pattern), and loses the workstation-operator path (the
   token must also be usable from a local `make up`, not only from CI).

## Consequences

- `secrets/civo-token.enc` follows the exact one-secret-per-file
  discipline `CLAUDE.md`'s "Secrets and authentication" section already
  states — no new documented exception is needed there.
- A `CIVO_TOKEN` compromise grants cluster-admin on the Civo cluster and,
  per ADR 0029, transitively reaches every AWS role's permissions through
  the CA-key path. This ADR does not reduce that blast radius; ADR 0029
  is where the mitigations for it live.
- The autoscaler's separate key means rotating or revoking the operator's
  token does not require also rotating the in-cluster autoscaler
  credential, and vice versa.
