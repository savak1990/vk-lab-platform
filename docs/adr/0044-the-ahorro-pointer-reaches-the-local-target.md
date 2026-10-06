# ADR 0044: The Ahorro pointer reaches the local target

## Status

Accepted

Lifts the gate [ADR 0043](0043-the-first-business-application-pointer.md)
placed on the `local` target. Every other decision in ADR 0043 stands.

## Context

ADR 0043 rendered the Ahorro pointer and its `AppProject` on aws, civo and
hetzner, and gated both off local with `{{- if ne .Values.target "local" }}`.
It gave two reasons and named the application's own spec 107 as the work that
lifts the gate:

- `local_resolve_inputs` reaches no cloud API and has no source for the three
  Cognito identifiers.
- The local target's Argo CD route already claims the root path prefix that a
  web client would need.

Both still hold. What changed is that the application now handles them. It
renders no HTTPRoute when it is told the target is local, and it skips
sign-in behind an explicit flag rather than requiring a user pool.

## Decision

### 1. The pointer renders on every target, and carries `target`

One new Helm parameter. The application cannot infer the target from an empty
`fqdn`: its own hostname template renders `printf "%s.%s" "ahorro" ""` as
`"ahorro."`, which is not empty, so its `required` guard passes and a bogus
hostname reaches the cluster in silence.

**`scripts/argo-up.sh` does not change.** `--set target=local` already exists
in `local_install_root_application`, `envoyGateway.fqdn` already defaults to
`""`, and `ahorro.cognito.*` already default to `""` in `gitops/values.yaml`.
The three identifiers therefore arrive empty on this target with no resolver
edit, and none of the unbound-variable risk that adding a `--set` against
`local_resolve_inputs` would have carried.

### 2. The platform creates `Namespace/ahorro`

The e2e checks reach the two Services through a port-forward, and
`pods/portforward` is granted per namespace. The `RoleBinding` that grants it
syncs at wave 2, while the application's children create their namespace with
`CreateNamespace=true` at wave 5. A `RoleBinding` whose namespace does not
exist fails the apply, and `SkipDryRunOnMissingResource` covers the dry run
only.

So the namespace is created here at wave 1, beside `Namespace/e2e`, which
exists for the same reason. `CreateNamespace=true` is idempotent and tracks
nothing, so nothing is owned twice and a prune on either side removes nothing
the other needs.

Both objects are ungated. This paragraph read "gated to local" on the
reasoning that local is where the application publishes no route, but
`tests/e2e/ahorro_test.go` carries no such gate and runs wherever `make test`
runs, so the grant is needed on every target. The `envoy` RoleBinding beside
them stays local-only, which is correct: only that target reaches the gateway
by forwarding.

### 3. The checks are a smoke test, not an authentication test

`tests/e2e/ahorro_test.go` asserts that the API answers `/healthz`, that the
client answers `/healthz`, and that `/config.json` carries the values the
chart rendered.

The third is the one that earns its place. The image ships a committed
`config.json` of its own, so a ConfigMap mount that silently failed would
still answer 200 with a plausible `localhost:8080`. Asserting the value
catches that; asserting the status code does not.

`ServiceURL` could not be reused: it resolves through an HTTPRoute, and the
application renders none here. `ForwardedServiceURL` follows the shape
`PostgresDSN` already uses for a service with no route — `ServiceSelector`,
`FirstReadyPod`, `PortForward`.

This closes nothing in the application's spec 110. A run with sign-in skipped
cannot catch a wrong issuer, a stale JWKS, an expired token, or CORS failing
on the authenticated call.

## Consequences

- **The application's pull request must merge first.** The pointer hardcodes
  `targetRevision: main` and `argocd app sync root --local` applies to the
  platform chart only, so a local bring-up fetches the application's *merged*
  code. Lifting the gate against a `main` that does not understand `target`
  makes its `validate.yaml` fail on the empty `fqdn`, leaves the pointer
  Degraded, and turns the `kind-integration` job red.
- The render check's local lists move in the same commit, as ADR 0043 and
  local spec 022 requirement 16 both require. `vk-ahorro` leaves
  `FORBIDDEN_APPLICATIONS_LOCAL`, and four objects join
  `REQUIRED_OBJECTS_LOCAL`.
- The aws golden render gains the `target` parameter on the pointer. That is
  the whole diff; nothing else moved.
- `make test` gains the `ahorro` label, so `make test-ahorro` runs these
  alone. The suite is still never wired into `up` or `argo-up`; CI runs it as
  its own step.
- A local bring-up now pulls two images and two charts from GHCR, so it needs
  network. It was already fetching the platform's own Applications, so this
  changes the volume rather than the requirement.
