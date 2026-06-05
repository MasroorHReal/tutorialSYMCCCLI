# cedar symcc CLI — Worked Examples

> **All commands and output were run verbatim before inclusion.**
> Example files live under [`tutorial-cli/examples/`](tutorial-cli/examples/).
> Build the CLI first (see [TUTORIAL-CLI.md](TUTORIAL-CLI.md#build-the-cli)):
> ```sh
> cargo build -p cedar-policy-cli --features analyze
> export CEDAR=./target/debug/cedar
> ```

---

## Contents

- [Example 1: Photo sharing — catching a refactor bug with `equivalent`](#example-1-photo-sharing)
- [Example 2: Project access — consolidation proof with `equivalent` and scope check with `implies`](#example-2-project-access)
- [Example 3: Expense reports — amount thresholds with `implies` and `disjoint`](#example-3-expense-reports)

---

## Example 1: Photo sharing

**Scenario.** A photo-sharing app lets users mark albums as public or private.
The rule is: *you can view an album if it is public or if you are its owner.*
During a code review, someone rewrites the condition and accidentally uses `&&`
instead of `||`.  SymCC finds the bug without needing to write test cases.

### Files

**`schema.cedarschema`**
```
entity User;
entity Album { owner: User, public: Bool };
action viewAlbum appliesTo {
    principal: [User],
    resource: [Album]
};
```

**`policies_v1.cedar`** — the correct policy
```cedar
permit(principal, action == Action::"viewAlbum", resource)
when { resource.public || resource.owner == principal };
```

**`policies_v2_buggy.cedar`** — accidental `&&` instead of `||`
```cedar
permit(principal, action == Action::"viewAlbum", resource)
when { resource.public && resource.owner == principal };
```

**`policies_v3_rewrite.cedar`** — another correct rewrite (operand order flipped)
```cedar
permit(principal, action == Action::"viewAlbum", resource)
when { resource.owner == principal || resource.public };
```

**`entities.json`**
```json
[
    { "uid": { "__entity": { "type": "User",  "id": "alice" } }, "attrs": {}, "parents": [] },
    { "uid": { "__entity": { "type": "User",  "id": "bob"   } }, "attrs": {}, "parents": [] },
    {
        "uid": { "__entity": { "type": "Album", "id": "alice-private" } },
        "attrs": { "owner": { "__entity": { "type": "User", "id": "alice" } }, "public": false },
        "parents": []
    },
    {
        "uid": { "__entity": { "type": "Album", "id": "alice-public" } },
        "attrs": { "owner": { "__entity": { "type": "User", "id": "alice" } }, "public": true },
        "parents": []
    }
]
```

### Concrete decisions with `cedar authorize`

Before using SymCC, verify the concrete behaviour matches intent:

```sh
# alice views her own private album → ALLOW
cedar authorize --schema schema.cedarschema --policies policies_v1.cedar \
  --entities entities.json \
  --principal 'User::"alice"' --action 'Action::"viewAlbum"' --resource 'Album::"alice-private"'
# ALLOW

# bob views alice's private album → DENY
cedar authorize --schema schema.cedarschema --policies policies_v1.cedar \
  --entities entities.json \
  --principal 'User::"bob"' --action 'Action::"viewAlbum"' --resource 'Album::"alice-private"'
# DENY

# bob views alice's PUBLIC album (v1 correct) → ALLOW
cedar authorize --schema schema.cedarschema --policies policies_v1.cedar \
  --entities entities.json \
  --principal 'User::"bob"' --action 'Action::"viewAlbum"' --resource 'Album::"alice-public"'
# ALLOW

# bob views alice's PUBLIC album (v2 BUGGY) → DENY  ← the bug
cedar authorize --schema schema.cedarschema --policies policies_v2_buggy.cedar \
  --entities entities.json \
  --principal 'User::"bob"' --action 'Action::"viewAlbum"' --resource 'Album::"alice-public"'
# DENY
```

### SymCC analysis

**Step 1 — confirm v1 never errors and is not trivially permissive:**

```sh
cedar symcc --schema schema.cedarschema \
  --principal-type User --action 'Action::"viewAlbum"' --resource-type Album \
  never-errors --policies policies_v1.cedar
```
```
✓ Policy never errors: VERIFIED
```

```sh
cedar symcc --schema schema.cedarschema \
  --principal-type User --action 'Action::"viewAlbum"' --resource-type Album \
  always-allows --policies policies_v1.cedar
```
```
✗ Policy set always allows: DOES NOT HOLD
  Counterexample found:
principal: User::"", action: Action::"viewAlbum", resource: Album::""
context: {}
entities: [
  User::"",
  Action::"viewAlbum",
  Album::"" {
    owner: User::"A",
    public: false,
  },
  User::"A",
]
```

A private album owned by someone else is correctly denied.

**Step 2 — prove the correct rewrite is safe (v1 ≡ v3):**

```sh
cedar symcc --schema schema.cedarschema \
  --principal-type User --action 'Action::"viewAlbum"' --resource-type Album \
  equivalent \
  --policies1 policies_v1.cedar \
  --policies2 policies_v3_rewrite.cedar
```
```
✓ Policy sets are equivalent: VERIFIED
```

Flipping `||` operands doesn't change semantics. Safe to ship.

**Step 3 — catch the `&&` bug (v1 ≢ v2):**

```sh
cedar symcc --schema schema.cedarschema \
  --principal-type User --action 'Action::"viewAlbum"' --resource-type Album \
  equivalent \
  --policies1 policies_v1.cedar \
  --policies2 policies_v2_buggy.cedar
```
```
✗ Policy sets are equivalent: DOES NOT HOLD
  Counterexample found:
principal: User::"", action: Action::"viewAlbum", resource: Album::""
context: {}
entities: [
  Album::"" {
    owner: User::"A",
    public: true,
  },
  User::"",
  User::"A",
  Action::"viewAlbum",
]
```

The counterexample is a **public album owned by someone else**. v1 allows it (public ∨ owner satisfies `public`); v2 denies it (public ∧ owner fails when `owner ≠ principal`). This is exactly the bug.

**Step 4 — understand the direction of the regression with `implies`:**

```sh
# v2 (AND) is strictly more restrictive — every v2-allow is also a v1-allow
cedar symcc --schema schema.cedarschema \
  --principal-type User --action 'Action::"viewAlbum"' --resource-type Album \
  implies --policies1 policies_v2_buggy.cedar --policies2 policies_v1.cedar
```
```
✓ Policy set 1 implies policy set 2: VERIFIED
```

```sh
# v1 does NOT imply v2 — v1 is more permissive
cedar symcc --schema schema.cedarschema \
  --principal-type User --action 'Action::"viewAlbum"' --resource-type Album \
  implies --policies1 policies_v1.cedar --policies2 policies_v2_buggy.cedar
```
```
✗ Policy set 1 implies policy set 2: DOES NOT HOLD
  ...counterexample: public album, non-owner principal
```

`v2 ⊆ v1` (v2 implies v1, i.e., v2 is stricter) but `v1 ⊄ v2` (v1 is more permissive).
The buggy policy **silently removed access** that was previously granted.

---

## Example 2: Project access

**Scenario.** An internal project tracker has two access rules for reading
projects: team members can read any project; anyone can read a non-internal
project.  A developer wants to consolidate two separate policy rules into one
combined condition.  SymCC proves the consolidation is correct, then verifies
that the team-member-only policy is a subset of the broader policy (so
converting from members-only to members-or-public never breaks existing access).

### Files

**`schema.cedarschema`**
```
entity Employee in [Team];
entity Team;
entity Project { team: Team, internal: Bool };
action readProject appliesTo {
    principal: [Employee],
    resource: [Project]
};
action writeProject appliesTo {
    principal: [Employee],
    resource: [Project]
};
```

**`policies_members_only.cedar`**
```cedar
permit(principal, action == Action::"readProject", resource)
when { principal in resource.team };
```

**`policies_members_or_public.cedar`**
```cedar
permit(principal, action == Action::"readProject", resource)
when { principal in resource.team || !resource.internal };
```

**`policies_split.cedar`** — same as `members_or_public` but as two rules
```cedar
permit(principal, action == Action::"readProject", resource)
when { principal in resource.team };

permit(principal, action == Action::"readProject", resource)
when { !resource.internal };
```

**`entities.json`**
```json
[
    { "uid": { "__entity": { "type": "Team", "id": "engineering" } }, "attrs": {}, "parents": [] },
    {
        "uid": { "__entity": { "type": "Employee", "id": "alice" } },
        "attrs": {},
        "parents": [{ "__entity": { "type": "Team", "id": "engineering" } }]
    },
    { "uid": { "__entity": { "type": "Employee", "id": "bob" } }, "attrs": {}, "parents": [] },
    {
        "uid": { "__entity": { "type": "Project", "id": "roadmap" } },
        "attrs": { "team": { "__entity": { "type": "Team", "id": "engineering" } }, "internal": true },
        "parents": []
    },
    {
        "uid": { "__entity": { "type": "Project", "id": "status-page" } },
        "attrs": { "team": { "__entity": { "type": "Team", "id": "engineering" } }, "internal": false },
        "parents": []
    }
]
```

### Concrete decisions with `cedar authorize`

```sh
# alice (in engineering) reads internal roadmap (members_only) → ALLOW
cedar authorize --schema schema.cedarschema --policies policies_members_only.cedar \
  --entities entities.json \
  --principal 'Employee::"alice"' --action 'Action::"readProject"' --resource 'Project::"roadmap"'
# ALLOW

# bob (no team) reads internal roadmap (members_only) → DENY
cedar authorize --schema schema.cedarschema --policies policies_members_only.cedar \
  --entities entities.json \
  --principal 'Employee::"bob"' --action 'Action::"readProject"' --resource 'Project::"roadmap"'
# DENY

# bob reads public status-page (members_only) → DENY
cedar authorize --schema schema.cedarschema --policies policies_members_only.cedar \
  --entities entities.json \
  --principal 'Employee::"bob"' --action 'Action::"readProject"' --resource 'Project::"status-page"'
# DENY

# bob reads public status-page (members_or_public) → ALLOW
cedar authorize --schema schema.cedarschema --policies policies_members_or_public.cedar \
  --entities entities.json \
  --principal 'Employee::"bob"' --action 'Action::"readProject"' --resource 'Project::"status-page"'
# ALLOW
```

### SymCC analysis

**Step 1 — prove the consolidated single-rule policy equals the two-rule form:**

```sh
cedar symcc --schema schema.cedarschema \
  --principal-type Employee --action 'Action::"readProject"' --resource-type Project \
  equivalent \
  --policies1 policies_members_or_public.cedar \
  --policies2 policies_split.cedar
```
```
✓ Policy sets are equivalent: VERIFIED
```

One rule or two rules — Cedar treats permit policies as a union, so the result
is the same. The consolidation is safe.

**Step 2 — check that rolling out `members_or_public` never removes existing access:**

```sh
cedar symcc --schema schema.cedarschema \
  --principal-type Employee --action 'Action::"readProject"' --resource-type Project \
  implies \
  --policies1 policies_members_only.cedar \
  --policies2 policies_members_or_public.cedar
```
```
✓ Policy set 1 implies policy set 2: VERIFIED
```

Every request allowed today (members-only) is still allowed after the change
(members-or-public). No regressions.

**Step 3 — confirm the new policy IS more permissive (does grant new access):**

```sh
cedar symcc --schema schema.cedarschema \
  --principal-type Employee --action 'Action::"readProject"' --resource-type Project \
  implies \
  --policies1 policies_members_or_public.cedar \
  --policies2 policies_members_only.cedar
```
```
✗ Policy set 1 implies policy set 2: DOES NOT HOLD
  Counterexample found:
principal: Employee::"", action: Action::"readProject", resource: Project::""
context: {}
entities: [
  Project::"" {
    internal: false,
    team: Team::"",
  },
  ...
  Employee::"",
]
```

The counterexample is a non-internal project accessed by a non-team-member —
exactly the new access the change was intended to grant.

---

## Example 3: Expense reports

**Scenario.** A finance system allows employees to approve expense reports.
Three policy variants exist: approve only small amounts (< $1,000), approve
only large amounts (> $10,000), and approve any amount.  A fourth variant
restricts approval to reports submitted by someone in the same department.
SymCC verifies amount-tier subsumption and proves that small and large tiers
don't overlap.

### Files

**`schema.cedarschema`**
```
entity Department;
entity Employee { department: Department };
entity ExpenseReport { amount: Long, submitter: Employee };
action approveExpense appliesTo {
    principal: [Employee],
    resource: [ExpenseReport]
};
```

**`policies_small.cedar`**
```cedar
permit(principal, action == Action::"approveExpense", resource)
when { resource.amount < 1000 };
```

**`policies_large.cedar`**
```cedar
permit(principal, action == Action::"approveExpense", resource)
when { resource.amount > 10000 };
```

**`policies_any.cedar`**
```cedar
permit(principal, action == Action::"approveExpense", resource);
```

**`policies_same_dept.cedar`**
```cedar
permit(principal, action == Action::"approveExpense", resource)
when { principal.department == resource.submitter.department };
```

**`entities.json`**
```json
[
    { "uid": { "__entity": { "type": "Department", "id": "engineering" } }, "attrs": {}, "parents": [] },
    { "uid": { "__entity": { "type": "Department", "id": "finance"     } }, "attrs": {}, "parents": [] },
    {
        "uid": { "__entity": { "type": "Employee", "id": "alice" } },
        "attrs": { "department": { "__entity": { "type": "Department", "id": "engineering" } } },
        "parents": []
    },
    {
        "uid": { "__entity": { "type": "Employee", "id": "bob" } },
        "attrs": { "department": { "__entity": { "type": "Department", "id": "finance" } } },
        "parents": []
    },
    {
        "uid": { "__entity": { "type": "ExpenseReport", "id": "report-500"   } },
        "attrs": { "amount": 500,   "submitter": { "__entity": { "type": "Employee", "id": "alice" } } },
        "parents": []
    },
    {
        "uid": { "__entity": { "type": "ExpenseReport", "id": "report-5000"  } },
        "attrs": { "amount": 5000,  "submitter": { "__entity": { "type": "Employee", "id": "alice" } } },
        "parents": []
    },
    {
        "uid": { "__entity": { "type": "ExpenseReport", "id": "report-50000" } },
        "attrs": { "amount": 50000, "submitter": { "__entity": { "type": "Employee", "id": "alice" } } },
        "parents": []
    }
]
```

### Concrete decisions with `cedar authorize`

```sh
# alice approves $500 report (small policy) → ALLOW
cedar authorize --schema schema.cedarschema --policies policies_small.cedar \
  --entities entities.json \
  --principal 'Employee::"alice"' --action 'Action::"approveExpense"' --resource 'ExpenseReport::"report-500"'
# ALLOW

# alice approves $5,000 report (small policy) → DENY  (over threshold)
cedar authorize --schema schema.cedarschema --policies policies_small.cedar \
  --entities entities.json \
  --principal 'Employee::"alice"' --action 'Action::"approveExpense"' --resource 'ExpenseReport::"report-5000"'
# DENY

# alice approves $5,000 report (any policy) → ALLOW
cedar authorize --schema schema.cedarschema --policies policies_any.cedar \
  --entities entities.json \
  --principal 'Employee::"alice"' --action 'Action::"approveExpense"' --resource 'ExpenseReport::"report-5000"'
# ALLOW

# alice approves her own $500 report (same_dept) → ALLOW
cedar authorize --schema schema.cedarschema --policies policies_same_dept.cedar \
  --entities entities.json \
  --principal 'Employee::"alice"' --action 'Action::"approveExpense"' --resource 'ExpenseReport::"report-500"'
# ALLOW

# bob (finance) approves alice's (engineering) $500 report (same_dept) → DENY
cedar authorize --schema schema.cedarschema --policies policies_same_dept.cedar \
  --entities entities.json \
  --principal 'Employee::"bob"' --action 'Action::"approveExpense"' --resource 'ExpenseReport::"report-500"'
# DENY
```

### SymCC analysis

**Step 1 — verify `small` never errors and is not over-permissive:**

```sh
cedar symcc --schema schema.cedarschema \
  --principal-type Employee --action 'Action::"approveExpense"' --resource-type ExpenseReport \
  never-errors --policies policies_small.cedar
```
```
✓ Policy never errors: VERIFIED
```

Cedar `Long` comparison (`< 1000`) never throws; no overflow is possible in a
plain comparison.

```sh
cedar symcc --schema schema.cedarschema \
  --principal-type Employee --action 'Action::"approveExpense"' --resource-type ExpenseReport \
  always-allows --policies policies_small.cedar
```
```
✗ Policy set always allows: DOES NOT HOLD
  Counterexample found:
...
entities: [
  ExpenseReport::"" {
    amount: 9223372036854775776,
    ...
  },
]
```

The counterexample amount is a large positive `Long` — the solver found an
amount ≥ 1000 that the policy denies.

**Step 2 — verify `any` is truly unconditional:**

```sh
cedar symcc --schema schema.cedarschema \
  --principal-type Employee --action 'Action::"approveExpense"' --resource-type ExpenseReport \
  always-allows --policies policies_any.cedar
```
```
✓ Policy set always allows: VERIFIED
```

**Step 3 — tier subsumption: `small` ⊆ `any`:**

```sh
cedar symcc --schema schema.cedarschema \
  --principal-type Employee --action 'Action::"approveExpense"' --resource-type ExpenseReport \
  implies --policies1 policies_small.cedar --policies2 policies_any.cedar
```
```
✓ Policy set 1 implies policy set 2: VERIFIED
```

```sh
cedar symcc --schema schema.cedarschema \
  --principal-type Employee --action 'Action::"approveExpense"' --resource-type ExpenseReport \
  implies --policies1 policies_any.cedar --policies2 policies_small.cedar
```
```
✗ Policy set 1 implies policy set 2: DOES NOT HOLD
  Counterexample found:
...
entities: [
  ExpenseReport::"" {
    amount: 9223372036854775776,
    ...
  },
]
```

Any amount ≥ 1000 is allowed by `any` but denied by `small`. The tiers are
strictly ordered: `small ⊂ any`.

**Step 4 — prove the two tiers don't overlap (`disjoint`):**

```sh
cedar symcc --schema schema.cedarschema \
  --principal-type Employee --action 'Action::"approveExpense"' --resource-type ExpenseReport \
  disjoint --policies1 policies_small.cedar --policies2 policies_large.cedar
```
```
✓ Policy sets are disjoint: VERIFIED
```

No amount is simultaneously `< 1000` and `> 10000`.  The tiers can be delegated
to separate approvers without risk of one approval covering the other's range.

**Step 5 — confirm `small` and `any` DO overlap (a disjoint check that fails):**

```sh
cedar symcc --schema schema.cedarschema \
  --principal-type Employee --action 'Action::"approveExpense"' --resource-type ExpenseReport \
  disjoint --policies1 policies_small.cedar --policies2 policies_any.cedar
```
```
✗ Policy sets are disjoint: DOES NOT HOLD
  Counterexample found:
...
entities: [
  ExpenseReport::"" {
    amount: 992,
    ...
  },
]
```

Amount 992 (< 1000) is approved by both `small` and `any`.

**Step 6 — `small` and `same_dept` are independent constraints:**

```sh
cedar symcc --schema schema.cedarschema \
  --principal-type Employee --action 'Action::"approveExpense"' --resource-type ExpenseReport \
  implies --policies1 policies_small.cedar --policies2 policies_same_dept.cedar
```
```
✗ Policy set 1 implies policy set 2: DOES NOT HOLD
  Counterexample found:
...
entities: [
  Employee::"A" {
    department: Department::"A",
  },
  Employee::"" {
    department: Department::"",
  },
  ExpenseReport::"" {
    amount: 992,
    submitter: Employee::"A",
  },
]
```

The solver found a small-amount report (`amount: 992`) whose submitter
(`Employee::"A"`, department `"A"`) is in a different department from the
principal (`Employee::""`, department `""`).  The `small` policy allows it (the
amount is under the threshold), but `same_dept` denies it (different
departments).  Amount and department are **orthogonal constraints** — knowing a
report is small tells you nothing about whether the approver is in the right
department.
