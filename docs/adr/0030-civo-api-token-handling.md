# ADR 0030: Provider API token handling

> **Note (2026-09-20):** this decision generalises from the Civo API token to
> provider API tokens. Hetzner tokens are per project with only two permission
> levels, Read or Read and Write, and both the cloud controller manager and
> the CSI driver require Read and Write, so an in-cluster token on that target
> carries full control of the project. The mitigations are the ones this
> decision already establishes. The in-cluster token is a *second, dedicated*
> token, never the operator's — the same trust-boundary separation applied
> below to the Civo autoscaler's own key — and it lives in its own committed
> ciphertext file. The project holds nothing but this lab, so a Secret reader
> gains the lab project and nothing else. Rotation is unchanged in shape:
> delete the token, re-encrypt, commit the new ciphertext, re-run `argo-up`.
> The Secret is `kube-system/cloud-operator-secret`, one name across non-EKS
> targets; `argo-up` creates it untracked, as it already creates the CA key
> Secret. Note that the Hetzner charts hardcode their own default Secret name
> inside the container environment block rather than exposing a name
> parameter, so adopting the shared name means overriding that whole block in
> the Helm values. Spec HETZ-045 creates the Secret, and HETZ-018 owns naming
> parametrized by provider, including the Civo rename to the shared name. The
> Civo mechanism below is otherwise unchanged and still binding. See
> [ADR 0036](0036-hetzner-kubeadm-third-execution-target.md).

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
- The `civo` CLI defeats this decision if used carelessly. It loads
  `CIVO_TOKEN` into its in-memory config under the name `tempKey`, and any
  command that saves the config then writes that plaintext token to
  `~/.civo.json`. CIVO-020 measured this: one `civo region current LON1`
  put the decrypted token on disk. The Civo API key has no scopes and no
  expiry, so this is a full-account credential at rest.
  Two workarounds exist. Prefer the first.
  1. Never run a config-saving `civo` command. Pass `--region LON1` on
     every invocation instead.
  2. Set the region once, then remove the entry:
     `jq 'del(.apikeys.tempKey) | .meta.current_apikey = ""' ~/.civo.json`.
     The region default survives this. Read-only commands do not add the
     token back.
  A CI runner is not affected in practice, because its `~/.civo.json` does
  not outlive the job. A CI runner must still set the region: a fresh
  config defaults to NYC1, not LON1.
