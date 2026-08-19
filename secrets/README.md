# secrets/ — per-file KMS-encrypted values

Each file here is one value — a runtime secret or a piece of non-secret
private configuration (like the root domain, constitution §14) — encrypted
independently with the bootstrap KMS key (`alias/vk-lab-platform-secrets`).

Rules (constitution §5/§14, architecture.md §18):

- One value per file, named after its contents: `secrets/<name>.enc`.
- Never combine multiple values into one committed ciphertext file.
- Never commit a plaintext value anywhere in this repository.

## Encrypting a new value

```
make secret-encrypt NAME=<name> VALUE=<plaintext-value>
```

Writes `secrets/<name>.enc`. Commit that file; never commit the plaintext
value you passed as `VALUE`.

## Decrypting a value

```
make secret-decrypt NAME=<name>
```

Prints the plaintext to stdout. To supply it to Terraform without landing
it in a file, export it directly as a `TF_VAR_*`, for example:

```
export TF_VAR_root_domain="$(make secret-decrypt NAME=root-domain)"
```

This works standalone from a laptop or CI — it only needs `aws kms decrypt`
against the ciphertext file and permission to use the KMS key. It has no
dependency on Terraform state, outputs, or any in-cluster component, so it
works from spec 002 onward, long before Pod Identity or an in-cluster
secrets controller exist (those are spec 013's job, for runtime application
secrets).

## What's here right now

Nothing yet — this spec ships only the encrypt/decrypt tooling.
`root-domain.enc` and other real values are added later, by whichever spec
first needs them (e.g. spec 002 for the root domain).

## What happens to this directory on `make bootstrap-down`

`make bootstrap-down` destroys the KMS key these files are encrypted with.
Once that key is gone (after its deletion window), every `*.enc` file here
becomes permanently undecryptable ciphertext. `make bootstrap-down` does
not delete these files itself — they're left as-is for you to remove or
re-encrypt under a new key at your own judgment.
