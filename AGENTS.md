# AGENTS.md: orkstage-modules

Guide for AI coding agents and the developers working with them.

## What this repository is

The OpenTofu module library OrkStage applies on customer accounts, one module per logical
resource and provider: `modules/<provider>/<module>/` with `main.tf` (variables, resources,
outputs) and `versions.tf` (required providers). The runner image
(`docker/tofu-runner.Dockerfile`) bakes the whole `modules/` tree in at `/modules`.

Providers: `aws`, `azure`, `gcp`, `oci`, `digitalocean`, `vultr`, `coreweave`, `magalu`. Module
names are shared across providers where the concept exists: `network`, `container-service`,
`postgres`, `redis`, `object-storage`, `ingress`, plus AWS only `container-registry`, `queue`,
`dns`.

## How modules are called

The provider adapter in the `orkstage` repository (`packages/cloud-<provider>/src/stacks.ts`)
writes a root configuration per resource: the backend, the provider block and

```hcl
module "resource" { source = "/modules/<provider>/<module>"  ...inputs }
output "all" { value = module.resource }
```

Consequences:

- **One isolated state per resource.** A module never assumes another module's resources are in
  the same state; it receives what it needs (network id, subnet ids, secret refs) as inputs.
- **Inputs are the contract with the adapter.** Renaming or removing a variable breaks the adapter;
  change both together (adapter first behind a default, then the module).
- **Outputs must be flat scalars** (strings, numbers, booleans; lists joined with commas, maps as
  `jsonencode`) and **never `sensitive`**, because `output "all"` would fail. Every module outputs
  `kind` (the logical resource type).
- **Secrets never appear in outputs.** Generated passwords go to the provider's secret store (or
  stay in state with write only attributes where available); the module outputs a `secret_ref`.
- No provider blocks and no backend blocks inside modules; credentials come from environment
  variables of the runner.
- Apply `tags` or labels the adapter passes; respect `production` inputs (deletion protection, no
  force destroy).

## Checks

Native `tofu` may be blocked on some machines; the container works everywhere (Git Bash needs
`MSYS_NO_PATHCONV=1`):

```bash
M=$(pwd -W)/modules        # or $PWD/modules
run() { MSYS_NO_PATHCONV=1 docker run --rm -v "$M:/m" -v orkstage-validate:/plugins -e TF_PLUGIN_CACHE_DIR=/plugins -w "$1" ghcr.io/opentofu/opentofu:1.13.2 "${@:2}"; }
run /m fmt -check -recursive /m
run /m/<provider>/<module> init -backend=false -input=false -no-color
run /m/<provider>/<module> validate -no-color
```

CI runs `fmt`, `init -backend=false` plus `validate` on every `modules/*/*/`, and builds the runner
image. Delete `.terraform/` and `.terraform.lock.hcl` files you create; state files are never
committed.

## Adding a module

1. Confirm resource names and arguments in the provider's current documentation; pin the provider
   major you verified in `versions.tf`.
2. Mirror an existing module of the same kind for variable names and output conventions.
3. Validate as above, then add or update the adapter's `moduleCall` in the `orkstage` repository
   and its tests (a root config rendered by the adapter should validate against the module).
4. Comments and descriptions: plain English, no em or en dashes, no emoji.

## Git workflow

Branch, pull request, squash merge when CI (`fmt`, `validate`, `runner-image`) is green, then bump
the pin in `orkstage-dev`. Merge module changes before the adapter change that depends on them.
