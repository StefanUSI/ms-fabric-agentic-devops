# Agent toolbox contract

The deterministic commands the developer agent calls instead of re-deriving
Microsoft Fabric API sequences each session.

**Status: specified, not implemented.** This document is the contract. None of
these commands exist yet.

**Scope: Level 1.** This set targets the verified environment in
[`environment-and-constraints.md`](environment-and-constraints.md) — a shared `<FABRIC_WORKSPACE>` workspace,
a delegated user identity, no service principal, no workspace creation, and no
native Git integration.

---

## Why a toolbox exists

`CLAUDE.md` requires deterministic scripts for repeated operations. An agent
that re-derives an API sequence each session produces a different sequence each
session, and the differences never appear in a diff because the sequence was
never source.

A toolbox command is reviewable source, idempotent where the API allows, fails
loudly rather than partially, and emits evidence in a fixed shape the reviewer
can check without rerunning it. It also saves tokens, which matters when the
agent runs headless on a budget.

## Removed from an earlier draft

Two commands were specified before the environment was verified and are now
**impossible**, not merely deferred:

| Removed | Why |
|---|---|
| `New-FabricFeatureEnvironment` | Workspace creation is **not authorized and not proven**. There is no feature workspace to create. |
| `Remove-FabricFeatureEnvironment` | Nothing to tear down; cleanup is human and item-scoped. |

Their absence is the single largest difference between this design and the
reference model. Isolation is a **folder**, not a workspace — organizational,
not enforced.

Deferred until the Level 1 loop works end to end: Direct Lake refresh and
framing, DAX smoke tests, PBIR validation, PBIP packaging, Ontology validation,
Data Agent validation. All were proven in the previous experiment; none is
needed to prove the *integration*.

## Conventions binding every command

| Property | Rule |
|---|---|
| **Identifiers** | Supplied explicitly. A command **never** resolves a workspace, folder or item by guessing, partial match or "the only candidate". |
| **Ambiguity** | A duplicate display name, an unresolvable GUID or a missing target is a **hard stop** with a non-zero exit code. |
| **Authentication** | Resolved at runtime from the Azure CLI session. **No command accepts a token, password or secret as an argument, environment variable or file.** |
| **Allowlist** | Every command that writes checks the ticket's item **and data-path** allowlist first, and refuses anything undeclared. |
| **Prefix** | Every ticket-scoped item is named `issue<N>_...`. Names are unique per *workspace*, so this is the real collision-avoidance mechanism. |
| **Verification** | Acceptance is not success. Every mutating command reads state back and fails if the read-back does not match intent. |
| **Evidence** | Every command emits a JSON fragment conforming to [`review-evidence-standard.md`](review-evidence-standard.md). |
| **Dry run** | Every mutating command supports `-WhatIf`, performing all validation and emitting the plan without changing anything. |
| **Destructive actions** | Never automatic. Commands **stop before** deletion, rename or overwrite and hand off to a human. |
| **Concurrency** | One job at a time. Pipeline concurrency is set to 1 — `<FABRIC_WORKSPACE>` is a shared, modest and a Spark run can throttle other people's work. |
| **Exit codes** | `0` success; distinct non-zero codes per failure class. Never `0` on partial success. |

> **No Fabric credential appears in this document.** The workspace and folder are
> named because they are the fixed, verified target — not secrets. Item
> identifiers come from a ticket, never from documentation.

---

## 1. `Test-RepositoryState`

| | |
|---|---|
| **Purpose** | Confirm the repository is safe to act from: correct branch, clean tree, in sync, ticket state coherent. |
| **Inputs** | `-IssueNumber`, `-ExpectedBranch`, `-RequireClean` |
| **Outputs** | Branch, head SHA, clean flag, sync status, ticket state |
| **Side effects** | **None.** Read-only, local Git. |
| **Auth** | None. |
| **Idempotency** | Fully idempotent. |
| **Failure** | Non-zero on dirty tree, wrong branch, divergence or incoherent ticket state. Never auto-corrects. |
| **Evidence** | `repositoryState` |
| **Rollback** | Not applicable. |

## 2. `Get-FabricFolderInventory`

| | |
|---|---|
| **Purpose** | Capture a baseline of everything in the target folder before deployment, and the same afterwards. |
| **Inputs** | `-WorkspaceId`, `-FolderPath`, `-OutputPath` |
| **Outputs** | Item id, type, display name, definition hash, last-modified — per item |
| **Side effects** | **None.** Read-only. |
| **Auth** | Read on the workspace. |
| **Idempotency** | Fully idempotent. |
| **Failure** | Non-zero if the folder cannot be enumerated. **Never returns a partial inventory as if complete** — a truncated baseline makes the later diff lie. |
| **Evidence** | `inventoryBefore` / `inventoryAfter` |
| **Rollback** | Not applicable. |

> **Open decision 3.** This assumes the Items API filters reliably by
> `folderId`. If it does not, the command must fall back to a whole-workspace
> inventory and the diff becomes noisier. Unverified.

## 3. `Compare-FabricFolderInventory`

| | |
|---|---|
| **Purpose** | Diff post-deployment against baseline and reject undeclared side effects. |
| **Inputs** | `-BaselinePath`, `-CurrentPath`, `-AllowlistPath` |
| **Outputs** | Added, modified, removed items; declared vs undeclared classification |
| **Side effects** | **None.** |
| **Auth** | None; operates on captured inventories. |
| **Idempotency** | Fully idempotent. |
| **Failure** | **Non-zero on any undeclared change.** Because there is no Git sync-back, this diff is the only mechanism that detects a change made outside the repository. |
| **Evidence** | `inventoryDiff` |
| **Rollback** | Not applicable. |

## 4. `Save-FabricItemSnapshot`

| | |
|---|---|
| **Purpose** | Capture an item's current definition **before** it is modified, so the change is reversible at all. |
| **Inputs** | `-WorkspaceId`, `-ItemId`, `-OutputPath` |
| **Outputs** | Definition parts, hash, capture timestamp |
| **Side effects** | **None.** Read-only. |
| **Auth** | Read on the item. |
| **Idempotency** | Fully idempotent. |
| **Failure** | Non-zero if the definition cannot be retrieved. **Deployment must not proceed** — a reversal plan for a modification without a prior snapshot is a wish, not a plan. |
| **Evidence** | `snapshots[]` |
| **Rollback** | This command *is* the rollback enabler. |

## 5. `Test-DeploymentAllowlist`

| | |
|---|---|
| **Purpose** | Confirm every intended target appears on the ticket's item and data-path allowlist. |
| **Inputs** | `-TicketPath`, `-IntendedItems`, `-IntendedDataPaths` |
| **Outputs** | Per-target allowed/denied with the reason |
| **Side effects** | **None.** |
| **Auth** | None. |
| **Idempotency** | Fully idempotent. |
| **Failure** | Non-zero on any undeclared target. |
| **Evidence** | `allowlistCheck` |
| **Rollback** | Not applicable. |

> **Data paths matter more than they look.** Items live in folders; **Lakehouse
> tables do not**. Without a data-path allowlist, an inventory can come back
> clean while Gold tables were overwritten.

## 6. `Publish-FabricItemDefinition`

| | |
|---|---|
| **Purpose** | Deploy an item definition from the repository into the target folder. This is the command that replaces Git sync. |
| **Inputs** | `-WorkspaceId`, `-FolderPath`, `-DefinitionPath`, `-ItemType`, `-DisplayName`, `-WhatIf` |
| **Outputs** | Item id, definition hash, created-or-updated flag |
| **Side effects** | Creates or updates **exactly** the named item. Never cascades to dependants. |
| **Auth** | Contributor on the workspace (currently: delegated user identity, Workspace Admin). |
| **Idempotency** | Idempotent — republishing an unchanged definition is a no-op verified by hash. |
| **Failure** | Non-zero on invalid definition, unresolvable target, allowlist violation or permission denial. **A 202 is not success**: the command polls to terminal state and re-reads the definition. |
| **Evidence** | `deployments[]` — item id, type, hash before and after, timestamps |
| **Rollback** | Republish the snapshot from command 4. Hash confirms restoration. |

Refuses if: the display name lacks the `issue<N>_` prefix; the target is not on
the allowlist; or the item exists and no snapshot was taken.

## 7. `Invoke-FabricPipeline`

| | |
|---|---|
| **Purpose** | Start a pipeline run and return its run identifier. |
| **Inputs** | `-WorkspaceId`, `-PipelineName`, `-Parameters`, `-WhatIf` |
| **Outputs** | Run id, submission timestamp |
| **Side effects** | Starts one run. **Moves data** — the most consequential command here. |
| **Auth** | Execute rights. |
| **Idempotency** | **Not idempotent.** Each invocation is a distinct run. Never retry blindly on timeout; poll the existing run id with command 8. |
| **Failure** | Non-zero if the run cannot be submitted. Submission success is **not** run success. |
| **Evidence** | `jobs[]` — run id, parameters with secrets redacted, submission time |
| **Rollback** | None automatic. Data effects need a ticket-specific compensating action, stated in the ticket. |

Sets pipeline concurrency to 1 and refuses to start if another job is running.

## 8. `Wait-FabricJob`

| | |
|---|---|
| **Purpose** | Poll a job to a terminal state and report the real outcome. |
| **Inputs** | `-WorkspaceId`, `-JobId`, `-TimeoutSeconds`, `-PollIntervalSeconds` |
| **Outputs** | Terminal status, duration, failure detail |
| **Side effects** | **None.** |
| **Auth** | Read on the workspace. |
| **Idempotency** | Fully idempotent. |
| **Failure** | Non-zero on failure, cancellation **or timeout**. A timeout reports `Unknown`, never success. |
| **Evidence** | `jobs[]` — terminal status, start and end, duration, error detail |
| **Rollback** | Not applicable. |

## 9. `Test-FabricTableResult`

| | |
|---|---|
| **Purpose** | Read table state back and reconcile it against expectation. This is the command that turns "it ran" into "it is correct". |
| **Inputs** | `-WorkspaceId`, `-LakehouseName`, `-TableName`, `-ExpectedRowCount`, `-ReconciliationQuery`, `-Tolerance` |
| **Outputs** | Row counts, deltas, pass/fail per assertion |
| **Side effects** | **None.** Read-only. |
| **Auth** | Read on the lakehouse. |
| **Idempotency** | Idempotent for a fixed input state. |
| **Failure** | Non-zero when a delta exceeds tolerance or an expected count is unmet. Expected values come from the **ticket**, never derived from the run under test — self-derived expectations make every run pass. |
| **Evidence** | `reconciliation` |
| **Rollback** | Not applicable. |

> ### ⚠️ Open decision 1 — this command is not yet implementable
>
> How the agent reads a row count back is **unresolved**. Candidates: the SQL
> analytics endpoint over ODBC with AAD auth; a DAX query against a semantic
> model; or the notebook writing its own audit row which is then read.
>
> Until this is settled, `review-evidence-standard.md` describes evidence that
> cannot be produced, and the loop cannot prove correctness — only execution.
> **This is the highest-priority decision in the design.**

## 10. `New-ReversalPlan`

| | |
|---|---|
| **Purpose** | Produce the exact steps to undo a deployment, **before** it happens. |
| **Inputs** | `-IntendedItems`, `-SnapshotPaths`, `-DataPaths`, `-OutputPath` |
| **Outputs** | Ordered reversal steps, irreversible steps, data-loss risk rating |
| **Side effects** | **None.** Writes a plan document only. |
| **Auth** | None. |
| **Idempotency** | Fully idempotent. |
| **Failure** | Non-zero if any intended modification has no snapshot, or any step is irreversible without being flagged as such. |
| **Evidence** | `rollback` |
| **Rollback** | This command *is* the plan. |

**Never executes.** Deletion and restoration are human actions, per the
compensating controls.

---

## Sequencing

```
1  Test-RepositoryState
2  Get-FabricFolderInventory        -> baseline
5  Test-DeploymentAllowlist
4  Save-FabricItemSnapshot          (only when modifying)
10 New-ReversalPlan                 (before any write)
6  Publish-FabricItemDefinition
7  Invoke-FabricPipeline
8  Wait-FabricJob
9  Test-FabricTableResult
2  Get-FabricFolderInventory        -> current
3  Compare-FabricFolderInventory    -> reject undeclared side effects
```

Steps 2, 5, 4 and 10 all run **before** the first write. A failure in any of
them stops the ticket with nothing deployed.

## Evidence contract

Each command contributes a named block to the ticket's evidence package. The
schema is in [`review-evidence-standard.md`](review-evidence-standard.md); the
reviewer checks the evidence, not the agent's description of it.
