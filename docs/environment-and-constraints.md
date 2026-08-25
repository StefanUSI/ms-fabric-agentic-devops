# Environment and constraints

The conditions this control plane operates under, what they prevent, what
compensates for them, and the path out.

> **No real identifiers appear in this document.** Placeholders such as
> `<FABRIC_WORKSPACE>` and `<TARGET_FOLDER>` stand for values held locally in
> `config/environment.local.json`, which is gitignored.

---

## 1. Environment shape

| Aspect | State |
|---|---|
| Fabric workspace | `<FABRIC_WORKSPACE>` — **shared** with other, unrelated work |
| Capacity | `<FABRIC_CAPACITY>`, a small SKU (single-digit CUs) |
| Role held | Workspace Admin |
| Isolation available | A **folder** inside that workspace |
| Identity | Delegated user identity — **no service principal** |
| Fabric Git integration | **Unavailable in the target tenant** |
| External control plane | GitHub — Issues, labels, branches, pull requests, reviews |

## 2. The constraints, and what each one costs

### No service principal

Agents run as the signed-in user and inherit that user's permissions. There is
no way to scope them down.

**Consequence, stated without softening: every Fabric restriction in this
repository is an instruction, not a permission.** An agent that ignores a rule
in `CLAUDE.md` is not stopped by anything at the identity layer. The usual second
line of defence does not exist, which is what makes those rules load-bearing
rather than advisory.

### No dedicated workspace, and no workspace creation

The reference pattern for this kind of workflow gives each ticket its own
workspace, created and destroyed automatically. That is unavailable.

What replaces it is a **folder**, and a folder is not a boundary:

- It does not restrict what an agent *can* reach — only where items are filed
- Item display names are unique **per workspace**, not per folder, so a
  collision can occur against items in folders the agent never sees
- **Lakehouse tables do not live in folders at all.** Data written to a shared
  lakehouse escapes folder organisation entirely — an item inventory can look
  perfectly clean while table contents were overwritten
- Semantic-model refresh and framing affect every consumer, wherever they sit
- Capacity is shared: a Spark run can throttle other people's work, causing real
  impact that leaves no item-level trace

Never describe the folder as a sandbox, in documentation or in a report.

### No native Fabric Git integration

The reference pattern depends on it at every step: branch → feature workspace →
Git sync → run → sync back. None of that is available.

The substitute is one-way and explicit:

```
repository definition (committed)
  → snapshot existing definition, if modifying
    → deploy via Fabric REST (Create / Update Item Definition)
      → run and poll to terminal state
        → read runtime state back independently
          → commit evidence to the feature branch
```

Invariants this imposes:

- **The repository is the source of truth.** Edit definitions locally and deploy
  them; never make a portal change absent from the repository
- **There is no sync-back.** Anything existing only in Fabric is invisible to
  review and is treated as a defect
- **Acceptance is never evidence.** A 202 means accepted, not done

## 3. Compensating controls

These substitute for a sandbox. They are weaker than one. They are what exists.

**Scope**
- Deliberately low-risk changes; new items in preference to modifications
- No deletion, rename or overwrite of existing items
- Every ticket-scoped item prefixed with the Issue number — the real
  collision-avoidance mechanism, since names are unique per workspace
- Allowlist covering every item **and data path** the ticket may touch
- Undeclared side effects are rejected, not judged

**Verification**
- Folder inventory captured before and after, and diffed on **name + type**
  (name alone is not a key — a Lakehouse and its SQL analytics endpoint share a
  display name)
- Runtime evidence required; API acceptance is not evidence
- Prior definitions snapshotted **before** any modification

**Concurrency**
- One ticket and one Fabric job at a time; pipeline concurrency 1
- A maximum iteration count per ticket, so a developer/reviewer loop cannot run
  away

**Reversal**
- Reversal plan produced **before** deployment
- Deletion never executed automatically; cleanup is human
- Stop before any destructive or irreversible action

**Roles**
- Human merge and human cleanup are mandatory
- The environment is labelled **logically isolated, not permission-isolated**

## 4. Reviewer access — what holds and what does not

The reviewer runs as a **separate process** in a **detached worktree** with no
access to the developer's session. That isolation is real.

**It reads all committed artefacts, including deployment scripts.** An earlier
design withheld them; that was wrong twice over — it did not hold (the worktree
is a full checkout of the branch) and it should not hold, because deployment
scripts carry the API usage, allowlist enforcement, validation and rollback logic
that most needs reviewing.

The boundary that *does* hold is **committed artefacts versus private developer
context**: no conversation history, scratchpads, chain-of-thought, uncommitted
files, or local execution manifests.

**What does not hold:** the reviewer shares the developer's identity and
therefore inherits Fabric write access. There is no Level 1 mitigation for this.
It is recorded as **unmitigated residual risk**, closed only by a separate
identity at Level 2.

Workspace, folder and item IDs are **identifiers, not credentials**.

## 5. Where enforcement is actually possible

Fabric least-privilege is out of reach. **GitHub is not.**

A branch protection rule or ruleset on the default branch requiring a pull
request and blocking direct pushes converts "no agent pushes to `main`" from an
instruction into an **enforced permission**.

It is the only permission-based control within reach in this phase, it costs
nothing, and it should be enabled before any live ticket.

## 6. Residual risk

| Risk | Why it remains | Compensating control |
|---|---|---|
| Agent can reach any item in the workspace | Delegated identity, no service principal | Allowlist, inventory diff, human review |
| Shared lakehouse data overwritten | Folders do not cover data | Data-path allowlist, pre-modification snapshot |
| Capacity throttling affects other users | Shared small capacity | One job at a time, concurrency 1 |
| Reviewer can technically write to Fabric | Shared identity | **None at Level 1.** Closed at Level 2 |
| Name collision outside the visible folder | Names unique per workspace | Issue-number prefix |
| Change made in the portal, absent from the repo | No sync-back | Inventory diff |
| Runaway agent loop | Automated cycle | Iteration ceiling |
| Correlated reviewer blind spots | Same model provider | Deterministic checks carry the objective half |

## 7. Maturity levels

### Level 1 — current

Delegated user identity · GitHub external control plane · local worktrees ·
shared workspace · folder-level organizational isolation · deterministic
deployment allowlist · human merge and cleanup · same-model reviewer in an
isolated context.

### Level 2 — internal pilot

Dedicated agent workspace, **requested from an administrator, not created** ·
service principal with workspace-scoped rights · branch protection enforced ·
reviewer under a separate identity with **read-only** Fabric access · both agents
launched as separate processes · scripted teardown.

Least privilege becomes real rather than instructional.

### Level 3 — production

Ephemeral per-ticket workspaces created and destroyed automatically · full
identity least privilege per role · deployment pipelines or restored Git
integration · cross-vendor review · unattended operation with a complete audit
trail · human merge authority retained.

## 8. Open decisions

| # | Decision | Status |
|---|---|---|
| 1 | How an agent reads row counts back | **Resolved** — the workload writes an audit file to the lakehouse file area; the deployment script retrieves it independently through the OneLake DFS endpoint with a different token audience. No ODBC driver or semantic model required |
| 2 | Whether folder-scoped inventory is reliable | **Resolved** — the items API reports folder membership reliably |
| 3 | Who else uses the shared workspace, and whether the capacity is ever paused | **Open** — affects blast radius and scheduling |
| 4 | Whether branch protection is available on this repository tier | **Open** — the only enforceable permission control |
| 5 | Whether to launch the developer as a separate process | **Open** — the main autonomy gap |
| 6 | How to detect modification of an existing item | **Open** — definition hashes are not yet captured, so only additions and removals are detectable |
