# ADR 0043: The first business application pointer

## Status

Accepted

Implements the pointer half of [ADR 0015](0015-business-app-gitops-topology.md)
and carries the identifiers [ADR 0042](0042-app-owned-cognito-in-the-persistent-layer.md)
put in the persistent layer.

## Context

ADR 0015 fixed the topology two years of platform work has not yet exercised:
this repository owns exactly one pointer `Application` per business
application, and the application's own monorepo owns everything below it.
Nothing had ever been wired, so every `Application` in `gitops/templates/` was
still `project: default` and `gitops/templates/apps/` did not exist.

ADR 0042 then put the Ahorro Cognito pool in
`terraform/live/persistent/ahorro-cognito/` and said its identifiers "take the
route `fqdn` already takes — SSM, read by `scripts/argo-up.sh`, passed down as
Helm parameters". Spec AWS-035 deliberately excluded that carrying step, and
the application's own spec 060 claims it. This is that work.

## Decision

### The two files ADR 0015 specified, and nothing more

`gitops/templates/apps/vk-ahorro/appproject.yaml` and `application.yaml`. The
pointer names the application's repository and its `gitops` path; everything
below it is that repository's business.

`AppProject` at sync-wave 4, the pointer at 5. The order is load-bearing in
one direction only: an `Application` naming a project that does not exist is
rejected outright rather than retried, so the project must land first. Wave 5
also makes the application the last thing a bring-up creates, after every
platform component.

This is the first `AppProject` in the repository. ADR 0015 said `default`
"remains acceptable only while the tree under `root` is platform-only", and
that stops being true here.

### Three identifiers join the existing value chain

`user_pool_id`, `client_id` and `issuer` travel exactly the route `fqdn`
travels: SSM, into `argo-up.sh`, `--set` onto `gitops/bootstrap`, a
`helm.parameters` entry on the root `Application`, a default in
`gitops/values.yaml`, and finally a parameter on the pointer.

They are **not** delivered by External Secrets. They are public identifiers,
and that path would store public data as secret data — ADR 0042 says so
directly.

**No region is threaded.** The issuer already contains it, and
`gitops/values.yaml` already carries `region: eu-west-1` as a fixed non-knob.

**The AWS resolver's batch goes from six names to nine**, against a
`get-parameters` cap of ten. A tenth still fits; an eleventh needs the
batching loop `civo_resolve_inputs` already has. That is noted in the comment
so the next person does not discover the cap by silent truncation.

`civo_resolve_inputs` keeps its own arrays and maps values by suffix, so it
gets three `case` arms rather than the shared helper the other two use. No new
`case "$PROVIDER"` block was added anywhere: the dispatch test requires every
such block to name all four providers, and extending the existing arrays
avoids the question entirely.

### Gated off the local target, for now

`{{- if ne .Values.target "local" }}`, because `local_resolve_inputs` reaches
no cloud API and has no source for the three identifiers, and because the
local target's Argo CD route already claims the root path prefix that a web
client would need. The application's own spec 107 covers what local support
requires; until it lands, the pointer does not render there.

The render check's structural lists name the two objects explicitly, on every
target. A new `Application` is otherwise neither required nor forbidden there,
so the check would pass silently whether it rendered or not — which is a trap
worth closing on the first use, not the tenth.

## Consequences

- `make full-up` now ends with a business application running, which it never
  has before. `argo_watch_root` blocks until `root` is Synced and Healthy, and
  the pointer and its children are resources beneath it, so the bring-up does
  not return until both application pods are healthy.
- A broken pointer wedges `root` until its retry budget runs out, roughly
  sixteen minutes. That is the risk ADR 0015 accepted for this topology, and
  the golden baseline plus the structural lists are what keep it from
  happening by accident.
- The application sets `selfHeal: false` on the pointer and on both of its
  children, because its operator installs those charts by hand. Drift inside
  namespace `ahorro` is therefore not corrected automatically. That is the
  application's call, not the platform's.
- Adding a second business application is the same two files under a new
  directory. Adding a service to *this* one is a change in the other
  repository only.
- `full-down` destroys everything in namespace `ahorro`. The Cognito pool and
  the GHCR packages survive, as ADR 0042 intends.
