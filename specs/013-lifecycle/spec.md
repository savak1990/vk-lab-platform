# 013 — Lifecycle (make up / make down)

**Complexity:** High
**Risk:** High — this is the spec that proves or breaks the platform's core promise: a disposable lab that can be torn down and rebuilt safely and idempotently. Every prior spec's individual destroy/recreate proof gets composed here into one real end-to-end flow.
**Estimated cost:** ~2–3 days · AWS runtime cost: this spec doesn't add new resources, but it's where you'll run the most full create/destroy cycles, so budget for that time/cost.
**Recommended model:** Opus — orchestrating dependency-aware shutdown/startup across every sync wave and hook built so far, and proving idempotency, is the highest-stakes reasoning task in the roadmap.
**Depends on:** every prior spec (001–012) — this is the integration point. Debezium (spec 023) lands after this spec; its lifecycle steps are added retroactively when that spec is implemented, not part of this spec's initial acceptance criteria.
**Lifecycle class(es) touched:** Disposable (orchestration target) / coordinates the Bootstrap/Persistent/Disposable boundary

## Scope

Implements `make up` and `make down` as the coordinated entry points for the full lifecycle described in architecture.md §20–24:

- `make up`: verify the Persistent stack (spec 002) already exists → Terragrunt apply disposable → EKS ready → system capacity available → Argo CD bootstrapped (spec 004) → root Application created → Argo reconciles the full platform in creation order (operators/controllers → platform components → stateful workloads → dependent workloads → public exposure) → verify healthy.
- `make down`: trigger cascading Argo-driven deletion in reverse order (public exposure → dependent workloads → stateful workloads → platform services/operators) → verify Argo-managed platform is empty → Terragrunt destroy disposable → verify AWS-side disposable resources are gone → verify persistent resources remain untouched. (Once spec 023 (Debezium) lands, its deletion step slots in between "dependent workloads" and "stateful workloads," per the constitution's deletion-ordering rule — added at that point, not here.)
- Explicit postcondition verification for both directions, not just "the command exited 0."

Excludes: any new platform component — this spec orchestrates what specs 001–012 already built, it doesn't add new infrastructure (Debezium, spec 023, lands after this spec and is folded into the lifecycle sequence when it's implemented). Also excludes `make bootstrap-up`/`make bootstrap-down` (spec 001) and `make persistent-up`/`make persistent-down` (spec 002) themselves — this spec's `make up` calls the Persistent-existence check those specs define, but does not own creating or destroying Bootstrap or Persistent resources. Also excludes `make minikube-up`/`make kind-up` (spec 020, the `local` target) — those are separate, non-lifecycle-class commands outside the State/Bootstrap/Persistent/Disposable command surface this spec orchestrates.

## Requirements

1. `make up` and `make down` MUST coordinate only the boundary between Argo/Kubernetes cleanup and Terragrunt/AWS destruction (constitution §6, architecture.md §21) — they MUST NOT reimplement Argo's or Kubernetes' internal deletion graph in shell/Go; sync waves, cascading deletion, and finalizers (already built into specs 004–012) do that work.
2. Creation and deletion order MUST follow architecture.md §20/§21 exactly: creation is operators/controllers → platform components → stateful workloads → dependent workloads → public exposure; deletion is the exact reverse.
3. A controller MUST remain running until resources it manages have completed cleanup (constitution §7) — `make down` must wait on (or trust Argo's own waiting on) Strimzi outliving Kafka CRs, the Postgres operator outliving its CRs, and the AWS Load Balancer Controller outliving ALB-triggering resources, exactly as specs 007/008/011 each already established individually.
4. `make up` SHOULD be idempotent (constitution §14/architecture.md's platform invariants) — running it twice in a row without an intervening `make down` should converge to the same healthy state, not error or duplicate resources.
5. A successful `terraform destroy`/`terragrunt destroy` alone is NOT sufficient to declare shutdown successful (constitution §12, architecture.md §23) — `make down` MUST include explicit postcondition verification: EKS, system worker, Karpenter-provisioned instances, ALB, Envoy, Kafka/Postgres pods, observability pods, and disposable Route 53 records inside the lab hosted zone are confirmed absent; Terraform state, KMS, Secrets Manager, the `lab.<root-domain>` hosted zone, its ACM certificate, RDS (n/a here — no RDS), and retained EBS volumes are confirmed to remain (constitution §14) — and the parent/root hosted zone is confirmed untouched (no API calls against it at any point in `make down`). No dedicated VPC exists to verify at this point in the roadmap (constitution §15) — the AWS default VPC is untouched by `make down` simply because this platform never manages it; once spec 019 lands, its VPC joins this "must remain" list.
6. `make down` MUST fail safely (not proceed to AWS-layer destruction) if persistence invariants aren't satisfied (constitution §4) — e.g., if a stateful workload hasn't finished cleanup, don't force through to Terraform destroy.
7. `make up`/`make down` MUST be environment-agnostic — no hardcoded assumption that they run on a developer's machine (e.g. no reliance on local-only credential caches or interactive prompts) — so that spec 014's GitHub Actions workflows can call the exact same targets and get the exact same behavior (architecture.md §34). This spec builds only the local-invocable `make up`/`make down` targets; the GitHub Actions workflows that call them are out of scope here and covered in spec 014.
8. `make up` MUST verify the Persistent stack (spec 002) already exists before doing anything else, and MUST fail with an actionable error naming `make persistent-up` if it does not (constitution §17) — it MUST NOT create Persistent resources itself, silently or otherwise.
9. `make down` MUST touch Disposable-lifecycle resources only. Removing Persistent or Bootstrap resources is `make persistent-down` (spec 002) and `make bootstrap-down` (spec 001) — separate, explicitly-confirmed commands this spec does not implement or trigger (constitution §17).

## Implementation hints

- Keep `make up`/`make down` as thin orchestrators: call Terragrunt, then poll Argo/Kubernetes API for sync/health status on the root Application (and key child Applications) rather than hardcoding waits for specific component types — this is what keeps the constitution's "don't reimplement the deletion graph" requirement honest.
- Postcondition verification is best implemented as a small, explicit checklist script (AWS API calls: describe EKS cluster absent, describe ALBs absent, list EC2 instances tagged Karpenter absent, describe EBS volumes present-and-retained) run at the end of `make down` and again at the start of `make up` (to confirm a clean starting state) — this is a legitimate verification script, distinct from the "don't reimplement the deletion graph" rule which targets *shutdown orchestration*, not *verification*.
- Test idempotency deliberately: run `make up` twice back-to-back and diff cluster/Argo state between runs; run `make down` on an already-torn-down environment and confirm it exits cleanly rather than erroring on "nothing to destroy."
- This is the spec where all the individual destroy/recreate proofs from specs 005/007/008 should be re-run as one composed end-to-end flow, since the real acceptance test the constitution cares about (§38 in architecture.md) is the full sequence, not each component in isolation.
- The Persistent-existence check (Requirement 8) can be a simple `terragrunt output`/remote-state check against `terraform/live/persistent/` at the top of `make up`, failing fast before any Terragrunt apply against the disposable stack is attempted.

## Testing / acceptance criteria

This spec's acceptance criterion **is** the constitution's full lifecycle acceptance test (architecture.md §38, constitution §11), run for real. Debezium lands after this spec (spec 023): until then, steps 2 and 5 below run without Debezium/CDC — that coverage is added retroactively when spec 023 is implemented, not part of this spec's own acceptance criteria.

1. `make up`
2. Verify EKS/Argo/Karpenter/Kafka/Postgres/observability/Envoy/ALB all healthy, and HTTPS through a `*.lab.<root-domain>` hostname works
3. Write PostgreSQL test data
4. Write Kafka test data
5. (Deferred until spec 023 lands: verify CDC end-to-end — Debezium picks up the Postgres write and produces the Kafka event.)
6. `make down`
7. Verify disposable infrastructure is absent (the full postcondition checklist from the implementation hints), including the ALB and its DNS records inside the lab zone
8. Verify persistent state remains: the `lab.<root-domain>` hosted zone, its ACM certificate, Secrets Manager, retained EBS volumes (no dedicated VPC exists yet at this point in the roadmap — constitution §15) — and verify the parent/root hosted zone was never modified (constitution §14)
9. `make up` again
10. Verify state recovery (Postgres/Kafka data from steps 3–4 is present and correct after rebinding), and verify DNS/HTTPS works again through the same `*.lab.<root-domain>` hostname without any change to the parent zone or a new certificate being issued
11. `make down`
12. Verify no disposable AWS resources leaked

Running this full sequence successfully, twice, is what "done" means for this spec — not a single successful pass.

Two more scenarios are part of this spec's acceptance criteria, run separately from the routine sequence above:

**`make up` precondition check (Requirement 8):** in an AWS account/state where `make persistent-up` has never been run, `make up` fails immediately with an error naming `make persistent-up` — it does not attempt any Terragrunt apply against the disposable stack, and it does not create any Persistent resource itself.

**Full teardown including Persistent (deliberate, run once, not part of the routine two-pass sequence above):** after the routine sequence's final `make down` (step 12), run `make persistent-down` (spec 002) and confirm it refuses to run if any disposable resource were still present, then — after its explicit confirmation step — successfully deletes the `lab.<root-domain>` hosted zone, its ACM certificate, every Secrets Manager secret (spec 012), and every retained EBS volume (specs 005/007/008), leaving nothing but the Bootstrap-lifecycle resources (spec 001) and the untouched parent/root hosted zone behind. This scenario is exercised once per major change to specs 001/002/012, not on every PR.
