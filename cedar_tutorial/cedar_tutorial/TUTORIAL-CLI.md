# cedar symcc CLI Tutorial

> **All commands and output in this document were run verbatim before inclusion.**
> The sample files used are in [`tutorial-cli/`](tutorial-cli/).

---

## Contents

1. [Prerequisites](#prerequisites)
2. [Build the CLI](#build-the-cli)
3. [Required flags and argument shape](#required-flags-and-argument-shape)
4. [Sample files](#sample-files)
5. [Property checks](#property-checks)
   - [never-errors](#never-errors)
   - [always-allows / always-denies](#always-allows--always-denies)
   - [equivalent](#equivalent)
   - [implies (subsumption)](#implies-subsumption)
   - [Single-policy checks](#single-policy-checks-always-matches-never-matches)
   - [Two-policy match checks](#two-policy-match-checks-matches-equivalent-matches-implies-matches-disjoint)
6. [Flags reference](#flags-reference)
7. [Exit codes](#exit-codes)
8. [Common errors](#common-errors)

---

## Prerequisites

- **cvc5** installed and on `PATH`, or the path set in `$CVC5`.
  (Verified with cvc5 1.3.5; any 1.3.x build works.)
- The Cedar workspace checked out; the CLI is built from source (see below).

---

## Build the CLI

The `symcc` subcommand is gated behind the `analyze` feature flag.
Build from the workspace root:

```sh
cargo build -p cedar-policy-cli --features analyze
```

The resulting binary is `target/debug/cedar` (or `target/release/cedar` with
`--release`).  All examples below use the variable `$CEDAR` for the binary
path:

```sh
export CEDAR=./target/debug/cedar
```

If `analyze` is not enabled, the command exits with:

```
Error: subcommand `symcc` is experimental, but this executable was not built
with `analyze` experimental feature enabled
```

---

## Required flags and argument shape

Every `cedar symcc` invocation requires four flags that together identify the
**request environment** — the `(principal_type, action, resource_type)` triple
SymCC analyses against.  In schemas with multiple actions you run the command
once per action you care about.

| Flag | Example | Note |
|---|---|---|
| `--schema FILE` | `--schema schema.cedarschema` | Cedar (default) or JSON (`--schema-format json`) |
| `--principal-type TYPE` | `--principal-type User` | Entity type name only, no namespace |
| `--action UID` | `--action 'Action::"view"'` | Full entity UID; use single quotes in shell |
| `--resource-type TYPE` | `--resource-type Document` | Entity type name only |

These go **before** the subcommand name.  The subcommand takes its own
`--policies` (or `--policies1`/`--policies2`) argument after it.

Full shape:

```sh
cedar symcc \
  --schema SCHEMA_FILE \
  --principal-type PRINCIPAL_TYPE \
  --action ACTION_UID \
  --resource-type RESOURCE_TYPE \
  [--cvc5-path PATH] [--counterexample|--no-counterexample] [-v] \
  SUBCOMMAND [SUBCOMMAND_OPTIONS]
```

---

## Sample files

All examples use these four files.  Create them in a working directory:

**`schema.cedarschema`**
```
entity User;
entity Document { owner: User };
action view appliesTo {
    principal: [User],
    resource: [Document],
    context: { count: Long, limit: Long }
};
```

**`policy_owner.cedar`** — allows only the document's owner
```
permit(principal, action == Action::"view", resource)
when { resource.owner == principal };
```

**`policy_overflow.cedar`** — same, but adds arithmetic that can overflow
```
permit(principal, action == Action::"view", resource)
when { resource.owner == principal && context.count + context.limit > 0 };
```

**`policy_owner_rewritten.cedar`** — same ownership check, operands flipped
```
permit(principal, action == Action::"view", resource)
when { principal == resource.owner };
```

**`policy_broad.cedar`** — unconditional permit
```
permit(principal, action == Action::"view", resource);
```

---

## Property checks

### never-errors

Checks that a **single policy** never raises a Cedar runtime error (integer
overflow, accessing an absent optional attribute, etc.) on any well-formed input.

> `never-errors` takes exactly one policy.  Put it in its own file; passing a
> file that contains two policies is an error (see [Common errors](#common-errors)).

**Policy with no arithmetic — verified:**

```sh
cedar symcc \
  --schema schema.cedarschema \
  --principal-type User \
  --action 'Action::"view"' \
  --resource-type Document \
  never-errors --policies policy_owner.cedar
```

```
✓ Policy never errors: VERIFIED
```

**Policy with `count + limit` — can overflow:**

```sh
cedar symcc \
  --schema schema.cedarschema \
  --principal-type User \
  --action 'Action::"view"' \
  --resource-type Document \
  never-errors --policies policy_overflow.cedar
```

```
✗ Policy never errors: DOES NOT HOLD
  Counterexample found:
principal: User::"", action: Action::"view", resource: Document::""
context: {count: -9223372036854775808, limit: -1}
entities: [
  Action::"view",
  Document::"" {
    owner: User::"",
  },
  User::"",
]
```

Cedar's `Long` is a 64-bit signed integer; `MIN_INT + (-1)` overflows.  The
counterexample shows the exact `count`/`limit` values cvc5 found.

---

### always-allows / always-denies

These operate on **policy sets** (one or more policies in the file).

**Owner policy — does NOT always allow:**

```sh
cedar symcc \
  --schema schema.cedarschema \
  --principal-type User \
  --action 'Action::"view"' \
  --resource-type Document \
  always-allows --policies policy_owner.cedar
```

```
✗ Policy set always allows: DOES NOT HOLD
  Counterexample found:
principal: User::"", action: Action::"view", resource: Document::""
context: {count: 0, limit: 0}
entities: [
  User::"",
  Action::"view",
  User::"A",
  Document::"" {
    owner: User::"A",
  },
]
```

The synthesized entity store has the document owned by `User::"A"` while the
principal is `User::""` — a request the ownership check denies.

**Broad policy — always allows:**

```sh
cedar symcc \
  --schema schema.cedarschema \
  --principal-type User \
  --action 'Action::"view"' \
  --resource-type Document \
  always-allows --policies policy_broad.cedar
```

```
✓ Policy set always allows: VERIFIED
```

**Suppress the counterexample** (`--no-counterexample`) — faster when you only
need the boolean:

```sh
cedar symcc \
  --schema schema.cedarschema \
  --principal-type User \
  --action 'Action::"view"' \
  --resource-type Document \
  --no-counterexample \
  always-allows --policies policy_owner.cedar
```

```
✗ Policy set always allows: DOES NOT HOLD
```

**`--verbose`** adds an explanatory line when the property holds:

```sh
cedar symcc \
  --schema schema.cedarschema \
  --principal-type User \
  --action 'Action::"view"' \
  --resource-type Document \
  --verbose \
  always-allows --policies policy_broad.cedar
```

```
✓ Policy set always allows: VERIFIED
  No counterexample found — property holds for all well-formed inputs.
```

---

### equivalent

Checks that two **policy sets** produce the same authorization decision on every
well-formed request.

**Ownership check vs same check with operands flipped — equivalent:**

```sh
cedar symcc \
  --schema schema.cedarschema \
  --principal-type User \
  --action 'Action::"view"' \
  --resource-type Document \
  equivalent \
  --policies1 policy_owner.cedar \
  --policies2 policy_owner_rewritten.cedar
```

```
✓ Policy sets are equivalent: VERIFIED
```

**Ownership check vs unconditional permit — not equivalent:**

```sh
cedar symcc \
  --schema schema.cedarschema \
  --principal-type User \
  --action 'Action::"view"' \
  --resource-type Document \
  equivalent \
  --policies1 policy_owner.cedar \
  --policies2 policy_broad.cedar
```

```
✗ Policy sets are equivalent: DOES NOT HOLD
  Counterexample found:
principal: User::"", action: Action::"view", resource: Document::""
context: {count: 0, limit: 0}
entities: [
  User::"",
  User::"A",
  Action::"view",
  Document::"" {
    owner: User::"A",
  },
]
```

The counterexample is a request where one set allows and the other denies —
here `policy_broad` allows while `policy_owner` denies (the principal is not
the owner).

---

### implies (subsumption)

`implies` checks that every request **allowed by `--policies1`** is also
**allowed by `--policies2`**.  The use case is safe-refactor checking: if new
policies imply old ones, no previously-allowed request becomes denied.

**Narrow implies broad — verified (no regression):**

```sh
cedar symcc \
  --schema schema.cedarschema \
  --principal-type User \
  --action 'Action::"view"' \
  --resource-type Document \
  implies \
  --policies1 policy_owner.cedar \
  --policies2 policy_broad.cedar
```

```
✓ Policy set 1 implies policy set 2: VERIFIED
```

**Broad implies narrow — does not hold (counterexample is a regression):**

```sh
cedar symcc \
  --schema schema.cedarschema \
  --principal-type User \
  --action 'Action::"view"' \
  --resource-type Document \
  implies \
  --policies1 policy_broad.cedar \
  --policies2 policy_owner.cedar
```

```
✗ Policy set 1 implies policy set 2: DOES NOT HOLD
  Counterexample found:
principal: User::"", action: Action::"view", resource: Document::""
context: {count: 0, limit: 0}
entities: [
  Document::"" {
    owner: User::"A",
  },
  User::"A",
  Action::"view",
  User::"",
]
```

The counterexample is a request allowed by `policy_broad` but denied by
`policy_owner` — a genuine regression.

---

### Single-policy checks: always-matches, never-matches

These check whether a **single policy's condition** always / never fires,
independent of its `permit`/`forbid` effect.

```sh
# A policy that always fires (trivially true condition)
cedar symcc \
  --schema schema.cedarschema \
  --principal-type User \
  --action 'Action::"view"' \
  --resource-type Document \
  always-matches --policies policy_broad.cedar
```

```
✓ Policy always matches: VERIFIED
```

```sh
# The ownership policy does not always match
cedar symcc \
  --schema schema.cedarschema \
  --principal-type User \
  --action 'Action::"view"' \
  --resource-type Document \
  always-matches --policies policy_owner.cedar
```

```
✗ Policy always matches: DOES NOT HOLD
  Counterexample found:
...
```

---

### Two-policy match checks: matches-equivalent, matches-implies, matches-disjoint

These compare the **match sets** (the sets of requests on which each policy's
condition fires) of two individual policies, regardless of their
`permit`/`forbid` effect.

- `matches-equivalent` — both policies fire on exactly the same requests
- `matches-implies` — every request that fires `--policy1` also fires `--policy2`
- `matches-disjoint` — no request fires both policies

```sh
cedar symcc \
  --schema schema.cedarschema \
  --principal-type User \
  --action 'Action::"view"' \
  --resource-type Document \
  matches-equivalent \
  --policy1 policy_owner.cedar \
  --policy2 policy_owner_rewritten.cedar
```

```
✓ Policies have equivalent match conditions: VERIFIED
```

---

## Flags reference

| Flag | Default | Description |
|---|---|---|
| `--schema FILE` | (required) | Path to the schema file |
| `--schema-format cedar\|json` | `cedar` | Schema file format |
| `--principal-type TYPE` | (required) | Entity type of the principal |
| `--action UID` | (required) | Full entity UID of the action |
| `--resource-type TYPE` | (required) | Entity type of the resource |
| `--cvc5-path PATH` | (uses `$CVC5` or PATH) | Explicit path to the cvc5 binary |
| `--counterexample` | on | Produce a counterexample when the property fails |
| `--no-counterexample` | off | Only output the boolean result; faster |
| `-v / --verbose` | off | Extra line when the property holds |

---

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Analysis ran successfully — both VERIFIED and DOES NOT HOLD return 0 |
| `1` | Analysis failed (solver error, bad input, schema mismatch, etc.) |

The exit code does **not** encode whether the property held.  If you need to
branch on the result in a script, parse the `✓`/`✗` prefix from stdout.

---

## Common errors

**Solver not found**

```
Analysis failed: × CVC5 solver not found or failed to start: ...
```

Set `$CVC5` to the absolute path of the binary, or add it to `PATH`.

---

**Action not in schema**

```
Analysis failed: × Failed to compile policy set: action not found in schema:
  │ Action::"nonexistent"
```

The `--action` value must exactly match an action declared in the schema,
including namespace and quotes: `Action::"view"`, not `view` or `Action::view`.

---

**never-errors / always-matches / never-matches given more than one policy**

```
Analysis failed: × Expected exactly one policy, found 2
```

The single-policy subcommands (`never-errors`, `always-matches`,
`never-matches`, `matches-equivalent`, `matches-implies`, `matches-disjoint`)
each require exactly one policy in the supplied file.  If your file has two or
more, split them first.

---

**Policy fails type-checking**

```
Analysis failed: × Failed to compile policy set: input policy (set) is not
well typed with respect to the schema ...
```

The policy references attributes or types that are inconsistent with the schema
or the `--principal-type`/`--action`/`--resource-type` triple.  Validate first
with `cedar validate --schema SCHEMA --policies POLICIES`.
