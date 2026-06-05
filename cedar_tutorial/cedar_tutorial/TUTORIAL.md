# cedar-policy-symcc Tutorial

> **All code in this document was compiled and run against cvc5 before inclusion.**
> The backing test file is [`tests/tutorial_examples.rs`](tests/tutorial_examples.rs).
> Run it with:
> ```sh
> cargo test -p cedar-policy-symcc --test tutorial_examples
> ```

---

## Contents

1. [Prerequisites](#prerequisites)
2. [API inventory checklist](#api-inventory-checklist)
3. [End-to-end example — never-errors and always-allows](#end-to-end-example--never-errors-and-always-allows)
4. [Counterexample extraction](#counterexample-extraction)
5. [Relational properties — equivalence and implication](#relational-properties--equivalence-and-implication)
6. [Common errors](#common-errors)
7. [README discrepancies](#readme-discrepancies)

---

## Prerequisites

### cvc5

SymCC delegates all satisfiability queries to an external [cvc5](https://github.com/cvc5/cvc5)
process.  The README recommends cvc5-1.3.1; this tutorial was verified against
cvc5 1.3.5.dev.  The source contains **no version check** — any cvc5 1.3.x build
should work.

`LocalSolver::cvc5()` ([`src/symcc/solver.rs:231`](src/symcc/solver.rs#L231))
resolves the binary in this order:

1. The value of the environment variable `CVC5` (if set).
2. `cvc5` anywhere on `PATH`.

```sh
# option A: explicit path
export CVC5=/usr/local/bin/cvc5

# option B: add cvc5 to PATH, then nothing extra is needed
```

Verify the solver is reachable before running any SymCC code:

```sh
cvc5 --version   # or: $CVC5 --version
```

### Cargo dependencies

Add these to `Cargo.toml`:

```toml
[dependencies]
cedar-policy = "4.11"
cedar-policy-symcc = "0.5"
tokio = { version = "1", features = ["rt", "macros"] }
```

SymCC's `check_*` methods are `async`; you need a Tokio runtime.

---

## API inventory checklist

This section lists every public symbol you will touch in normal usage.
All names, signatures, and deprecation notes were read directly from source.

### Core types

| Type | Where | Notes |
|---|---|---|
| `CedarSymCompiler<S: Solver>` | [`lib.rs:267`](src/lib.rs#L267) | Entry point; holds the solver |
| `CompiledPolicy` | [`lib.rs:148`](src/lib.rs#L148) | Single compiled policy (current API) |
| `CompiledPolicySet` | [`lib.rs:215`](src/lib.rs#L215) | Compiled policy set (current API) |
| `Env` | [`src/symcc/concretizer.rs:90`](src/symcc/concretizer.rs#L90) | Counterexample: `pub request: Request, pub entities: Entities` |
| `SymEnv` | [`src/symcc/env.rs:172`](src/symcc/env.rs#L172) | Symbolic request environment |
| `WellTypedPolicy` / `WellTypedPolicies` | [`lib.rs:64,106`](src/lib.rs#L64) | **Deprecated since 0.3.0** — use `CompiledPolicy`/`CompiledPolicySet` |
| `err::Error` | [`src/err.rs:31`](src/err.rs#L31) | Top-level error enum |
| `err::Result<T>` | [`src/err.rs:71`](src/err.rs#L71) | `std::result::Result<T, Error>` |

### Solver

| Symbol | Where | Notes |
|---|---|---|
| `solver::Solver` (trait) | [`src/symcc/solver.rs:91`](src/symcc/solver.rs#L91) | Implemented by `LocalSolver` |
| `LocalSolver::cvc5()` | [`src/symcc/solver.rs:231`](src/symcc/solver.rs#L231) | Spawns a cvc5 process; uses `$CVC5` or `cvc5` on PATH |
| `LocalSolver::cvc5_with_args(args)` | [`src/symcc/solver.rs:237`](src/symcc/solver.rs#L237) | Same but with custom flags, e.g. `["--rlimit=100000"]` |
| `LocalSolver::from_command(cmd)` | [`src/symcc/solver.rs:205`](src/symcc/solver.rs#L205) | Bring-your-own `tokio::process::Command` |

### Compilation

Both constructors do validation + well-typing internally; do **not** call
`WellTypedPolicies::from_policies` first.

```rust
CompiledPolicySet::compile(pset: &PolicySet, env: &RequestEnv, schema: &Schema) -> Result<Self>
CompiledPolicy::compile(policy: &Policy, env: &RequestEnv, schema: &Schema)     -> Result<Self>
```

Sources: [`lib.rs:225`](src/lib.rs#L225), [`lib.rs:158`](src/lib.rs#L158).

### `schema.request_envs()` — callers iterate manually

`Schema::request_envs() -> impl Iterator<Item = RequestEnv>` enumerates every
`(principal_type, action, resource_type)` triple declared in the schema.
**Callers must iterate this themselves.**  A `CompiledPolicy` or
`CompiledPolicySet` is compiled for exactly one `RequestEnv`; mixing them across
environments is a caller invariant violation.

For schemas with a single action (the common tutorial case) the iterator yields
exactly one item.

### `CedarSymCompiler` check methods — current (non-deprecated) API

All methods are `async` and return `Result<_>`.  The `_with_counterexample_opt`
variants return `Option<Env>` — `None` if the property holds, `Some(Env)` if it
does not.

**Single-policy checks (take `&CompiledPolicy`)**

| Method | Returns | Holds when… |
|---|---|---|
| `check_never_errors_opt` | `Result<bool>` | policy errors on no well-formed input |
| `check_always_matches_opt` | `Result<bool>` | policy matches every well-formed input |
| `check_never_matches_opt` | `Result<bool>` | policy matches no well-formed input |
| `check_matches_equivalent_opt` | `Result<bool>` | two policies match the same input set |
| `check_matches_implies_opt` | `Result<bool>` | matching of p1 ⊆ matching of p2 |
| `check_matches_disjoint_opt` | `Result<bool>` | matched-input sets are disjoint |

Each has a `_with_counterexample_opt` twin returning `Result<Option<Env>>`.

**Policy-set checks (take `&CompiledPolicySet`)**

| Method | Returns | Holds when… |
|---|---|---|
| `check_always_allows_opt` | `Result<bool>` | pset allows every well-formed request |
| `check_always_denies_opt` | `Result<bool>` | pset denies every well-formed request |
| `check_equivalent_opt` | `Result<bool>` | pset1 and pset2 produce identical decisions |
| `check_implies_opt` | `Result<bool>` | every allow in pset1 is also an allow in pset2 |
| `check_disjoint_opt` | `Result<bool>` | pset1 and pset2 never both-allow the same request |

Each has a `_with_counterexample_opt` twin returning `Result<Option<Env>>`.

### Feature flags

From [`Cargo.toml:36-38`](Cargo.toml#L36-L38):
- `experimental` (enables `variadic-is-in-range`)
- `variadic-is-in-range`

Neither flag gates any of the `check_*` methods; they affect SMT encoding of IP
address range operations only.

---

## End-to-end example — never-errors and always-allows

```rust
use std::str::FromStr;
use cedar_policy::{Policy, PolicySet, Schema};
use cedar_policy_symcc::{solver::LocalSolver, CedarSymCompiler, CompiledPolicy, CompiledPolicySet};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let (schema, _) = Schema::from_cedarschema_str(r#"
        entity User;
        entity Document { owner: User };
        action view appliesTo {
            principal: [User],
            resource: [Document],
            context: { count: Long, limit: Long }
        };
    "#)?;

    // Policy A: entity comparison only.
    let policy_a_text = r#"
        permit(principal, action == Action::"view", resource)
        when { resource.owner == principal };
    "#;

    // Policy B: same, plus arithmetic that can overflow.
    let policy_b_text = r#"
        permit(principal, action == Action::"view", resource)
        when { resource.owner == principal && context.count + context.limit > 0 };
    "#;

    let pset_a = PolicySet::from_str(policy_a_text)?;
    let pset_b = PolicySet::from_str(policy_b_text)?;

    // `LocalSolver::cvc5()` uses $CVC5 or finds `cvc5` on PATH.
    let mut compiler = CedarSymCompiler::new(LocalSolver::cvc5()?)?;

    // schema.request_envs() yields one RequestEnv per (principal, action, resource)
    // triple in the schema.  Callers must iterate it; compile once per env.
    for req_env in schema.request_envs() {

        // --- never-errors: uses CompiledPolicy (single-policy API) ---
        let policy_a = Policy::parse(None, policy_a_text)?;
        let policy_b = Policy::parse(None, policy_b_text)?;

        let compiled_a = CompiledPolicy::compile(&policy_a, &req_env, &schema)?;
        let compiled_b = CompiledPolicy::compile(&policy_b, &req_env, &schema)?;

        // Policy A: only entity equality — never errors.
        let a_never_errors = compiler.check_never_errors_opt(&compiled_a).await?;
        assert!(a_never_errors);                  // true

        // Policy B: `count + limit` can overflow on Cedar's 64-bit Long.
        let b_never_errors = compiler.check_never_errors_opt(&compiled_b).await?;
        assert!(!b_never_errors);                 // false — it CAN error

        // --- always-allows: uses CompiledPolicySet ---
        let compiled_pset_a = CompiledPolicySet::compile(&pset_a, &req_env, &schema)?;
        let compiled_pset_b = CompiledPolicySet::compile(&pset_b, &req_env, &schema)?;

        // Neither policy always allows — there exist documents not owned by the principal.
        assert!(!compiler.check_always_allows_opt(&compiled_pset_a).await?);
        assert!(!compiler.check_always_allows_opt(&compiled_pset_b).await?);
    }

    Ok(())
}
```

**What the results mean:**

- `check_never_errors_opt` returns `true` → the policy never raises a Cedar
  runtime error (attribute access on absent attribute, integer overflow, etc.)
  on any well-formed input for this `RequestEnv`.
- `check_always_allows_opt` returns `true` → the policy set allows **every**
  request that is well-formed according to the schema and this `RequestEnv`.

---

## Counterexample extraction

When a property does **not** hold, the `_with_counterexample_opt` variant
returns `Some(Env)`.  `Env` is defined as:

```rust
pub struct Env {
    pub request: Request,    // cedar_policy::Request
    pub entities: Entities,  // cedar_policy::Entities
}
```

Both fields are plain `cedar_policy` types; pass them directly to
`Authorizer::is_authorized`.

```rust
use std::str::FromStr;
use cedar_policy::{Authorizer, Decision, PolicySet, Schema};
use cedar_policy_symcc::{solver::LocalSolver, CedarSymCompiler, CompiledPolicySet};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let (schema, _) = Schema::from_cedarschema_str(r#"
        entity User;
        entity Document { owner: User };
        action view appliesTo {
            principal: [User],
            resource: [Document],
            context: { count: Long, limit: Long }
        };
    "#)?;

    let pset = PolicySet::from_str(r#"
        permit(principal, action == Action::"view", resource)
        when { resource.owner == principal };
    "#)?;

    let mut compiler = CedarSymCompiler::new(LocalSolver::cvc5()?)?;

    for req_env in schema.request_envs() {
        let compiled = CompiledPolicySet::compile(&pset, &req_env, &schema)?;

        // Returns None if always-allows holds, Some(Env) if it doesn't.
        match compiler.check_always_allows_with_counterexample_opt(&compiled).await? {
            None => println!("policy always allows — no counterexample"),
            Some(cex) => {
                // cex.request  — cedar_policy::Request
                // cex.entities — cedar_policy::Entities
                let response = Authorizer::new()
                    .is_authorized(&cex.request, &pset, &cex.entities);

                // The counterexample is guaranteed to be denied by the policy.
                assert_eq!(response.decision(), Decision::Deny);

                // Env implements Display: prints principal/action/resource/context
                // and the entity store.
                println!("{cex}");
            }
        }
    }

    Ok(())
}
```

**What the counterexample contains:**  `cex.request` holds the synthesized
principal, action, resource, and context.  `cex.entities` holds an entity store
whose attribute assignments and ancestor relationships satisfy the policy's
conditions in whichever way makes the property fail.  Both are guaranteed to be
schema-valid.

---

## Relational properties — equivalence and implication

These two properties are the main use case for policy analysis (safe refactor
checking, access-scope comparison):

- `check_equivalent_opt(pset1, pset2)` — do both sets produce **identical
  authorization decisions** on every well-formed request?
- `check_implies_opt(pset1, pset2)` — is every request **allowed by `pset1`**
  also allowed by `pset2`?  (pset2 is at least as permissive.)

```rust
use std::str::FromStr;
use cedar_policy::{Authorizer, PolicySet, Schema};
use cedar_policy_symcc::{solver::LocalSolver, CedarSymCompiler, CompiledPolicySet};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let (schema, _) = Schema::from_cedarschema_str(r#"
        entity User;
        entity Document { owner: User };
        action view appliesTo {
            principal: [User],
            resource: [Document],
            context: { count: Long, limit: Long }
        };
    "#)?;

    // Narrow: only the document owner may view.
    let pset_narrow = PolicySet::from_str(r#"
        permit(principal, action == Action::"view", resource)
        when { resource.owner == principal };
    "#)?;

    // Same logic, operand order flipped — syntactically different, semantically identical.
    let pset_narrow_rewritten = PolicySet::from_str(r#"
        permit(principal, action == Action::"view", resource)
        when { principal == resource.owner };
    "#)?;

    // Broad: unconditional permit.
    let pset_broad = PolicySet::from_str(r#"
        permit(principal, action == Action::"view", resource);
    "#)?;

    let mut compiler = CedarSymCompiler::new(LocalSolver::cvc5()?)?;

    for req_env in schema.request_envs() {
        let compiled_narrow =
            CompiledPolicySet::compile(&pset_narrow, &req_env, &schema)?;
        let compiled_rewritten =
            CompiledPolicySet::compile(&pset_narrow_rewritten, &req_env, &schema)?;
        let compiled_broad =
            CompiledPolicySet::compile(&pset_broad, &req_env, &schema)?;

        // (a) narrow ≡ rewritten  — syntactic difference, same semantics
        assert!(compiler.check_equivalent_opt(&compiled_narrow, &compiled_rewritten).await?);

        // (b) narrow ≢ broad
        assert!(!compiler.check_equivalent_opt(&compiled_narrow, &compiled_broad).await?);

        // Counterexample for (b): a request where the two sets disagree.
        let cex = compiler
            .check_equivalent_with_counterexample_opt(&compiled_narrow, &compiled_broad)
            .await?
            .expect("non-equivalent sets must have a counterexample");

        let resp_narrow  = Authorizer::new().is_authorized(&cex.request, &pset_narrow, &cex.entities);
        let resp_broad   = Authorizer::new().is_authorized(&cex.request, &pset_broad,  &cex.entities);
        assert_ne!(resp_narrow.decision(), resp_broad.decision());

        // (c) narrow ⊆ broad (implication)
        //   every request allowed by narrow is also allowed by broad
        assert!( compiler.check_implies_opt(&compiled_narrow, &compiled_broad).await?);
        // broad ⊄ narrow
        assert!(!compiler.check_implies_opt(&compiled_broad,  &compiled_narrow).await?);
    }

    Ok(())
}
```

**Tip — reuse compiled policysets across multiple queries.**
`CompiledPolicySet::compile` is the expensive step (it runs the Cedar
typechecker and symbolic compilation).  If you need to run several properties
against the same policy set in the same `RequestEnv`, compile once and call as
many `check_*_opt` methods as needed on the same `CompiledPolicySet`.  Each
check creates a fresh SMT query but does not re-compile the Cedar policy.

---

## Common errors

### Solver not found

**Symptom:** `LocalSolver::cvc5()` returns `Err(SolverError::Io(...))` with
a "No such file or directory" message, or `CedarSymCompiler::new(...)` panics
in test code that uses `.unwrap()`.

**Cause:** Neither `$CVC5` nor `cvc5` on `PATH` resolves to an executable.

**Fix:**
```sh
export CVC5=/path/to/cvc5-1.3.x
# or symlink/copy cvc5 into a directory on PATH
```

Source: [`src/symcc/solver.rs:238`](src/symcc/solver.rs#L238).

---

### Policy not well-typed (`PolicyNotWellTyped`)

**Symptom:** `CompiledPolicy::compile(...)` or `CompiledPolicySet::compile(...)`
returns `Err(Error::PolicyNotWellTyped { errs })`.

**Cause:** The policy failed Cedar's strict typechecker for the given schema
and `RequestEnv`.  Common reasons:
- Referencing an attribute (`resource.foo`) that does not exist in the schema.
- Using a context attribute (`context.n1`) not declared in the action's `appliesTo` context.
- Action guard (`action == Action::"view"`) does not match the `RequestEnv` action.

**Fix:** Validate the policy against your schema first with
`Validator::new(schema).validate(&pset, ValidationMode::Strict)` and fix any
reported errors before compiling.

---

### Action not found in schema (`ActionNotInSchema`)

**Symptom:** `SymEnv::new(schema, req_env)` returns
`Err(Error::ActionNotInSchema("Action::\"foo\""))`.

**Cause:** You constructed a `RequestEnv` with `RequestEnv::new(principal, action, resource)`
and the `action` entity UID is not declared in the schema.

This error does **not** occur when you use `schema.request_envs()` to generate
`RequestEnv`s, because that iterator only yields envs for actions that are in
the schema.

---

### Solver returned `unknown` (`SolverUnknown`)

**Symptom:** A `check_*_opt` call returns `Err(Error::SolverUnknown)`.

**Cause:** cvc5 gave up before finding a proof or counterexample (hit the
time/resource limit).  The default `LocalSolver::cvc5()` passes
`--tlimit=60000` (60 seconds of wall time).

**Fix:** Use `LocalSolver::cvc5_with_args(["--tlimit=120000"])` to extend the
limit, or `--rlimit=<n>` for a resource-based limit.  For very complex schemas,
consider splitting the query into smaller `RequestEnv`s.

---

## README discrepancies

**Deprecated API in README example.**  The README example ([`README.md:36-77`](README.md#L36))
uses `WellTypedPolicies::from_policies` and `check_always_allows` — both
deprecated at 0.5.0 in favour of `CompiledPolicySet::compile` and
`check_always_allows_opt`.  The README has not been updated.

Use `CompiledPolicySet` for all new code; the `WellTypedPolicies` path will
be removed in a future release.

**cvc5 version in README.**  README says `cvc5-1.3.1`; the source contains no
version check.  cvc5 1.3.x (including 1.3.5) works.
