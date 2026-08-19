# State layer

Creates the Terraform remote-state S3 bucket every other unit in this
repository (`state` itself, `bootstrap/*`, and later `persistent`,
`disposable`, `ci/persistent`, `ci/disposable`) stores its state in. See
`docs/adr/0004-dedicated-state-lifecycle-layer.md` for why this is its own
layer below Bootstrap rather than a unit inside it.

## Usage

```
make state-up
```

Runs `scripts/state-up.sh`. Idempotent: safe to run again later (applies
normally if the bucket already exists) — it only does anything special the
very first time, when the bucket doesn't exist yet and this unit's own
state has nowhere else to live.

```
make state-down
```

Runs `scripts/state-down.sh`. Guarded like `bootstrap-down`: refuses if
Bootstrap, Persistent, Disposable, or CI state still exists in the bucket,
then requires typing the bucket name to confirm. Essentially never run —
see ADR 0004 (why the bucket is its own layer) and ADR 0005 (why a guarded
destroy exists at all, despite ADR 0004's original "no destroy command"
decision). Bypasses Terraform entirely: purges every object version and
delete marker (the bucket is versioned, so a plain delete only adds
markers), then deletes the bucket.

To fully tear down and recreate everything from scratch (throwaway/test
AWS accounts only):

```bash
make bootstrap-down
make state-down
make state-up
make bootstrap-up
make secret-encrypt NAME=test VALUE=hello-from-spec-001
make secret-decrypt NAME=test
```
