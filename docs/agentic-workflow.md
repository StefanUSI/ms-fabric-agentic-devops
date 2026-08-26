# Agentic workflow and ticket state model

How a GitHub Issue becomes a reviewed, human-merged change.

```
GitHub Issue (ticket)
  -> developer dispatcher claims it
    -> feature branch + isolated developer worktree
      -> developer agent implements, tests, evidences
        -> pull request
          -> reviewer dispatcher claims the PR
            -> separate reviewer worktree + independent context
              -> APPROVED / CHANGES REQUESTED / BLOCKED
                -> HUMAN merge
```

The transition from a reviewer verdict to a merge has **no agent in it**. That
gap is the control that makes everything upstream of it safe.

---

## 1. Labels are the external source of truth

Ticket state lives on the **GitHub Issue**, expressed as labels. It does not
live in a local file, an agent's memory, or a dispatcher's process state.

This is deliberate. Local state is invisible to the human, is lost when a
process dies, and cannot be corrected from a phone. A label can be inspected
and changed by anyone with repository access, at any time, without touching the
machine the dispatcher runs on.

| Label | Meaning |
|---|---|
| `fabric-dev-agent` | This Issue is a Fabric development ticket eligible for the developer agent |
| `agent-in-progress` | Claimed by a developer agent; work is underway |
| `blocked` | Halted — ambiguous target, missing authorisation, or a safety conflict |
| `ready-for-review` | Implementation complete and evidenced; awaiting the reviewer agent |
| `fabric-review-agent` | Under, or awaiting, independent agent review |
| `changes-requested` | Reviewer returned CHANGES REQUESTED; returns to the developer |
| `approved-by-agent` | Reviewer returned APPROVED; awaiting the human merge decision |
| `human-decision-required` | Needs a human decision; no agent may proceed |

## 2. Lifecycle

| Stage | Labels present |
|---|---|
| New ticket | `fabric-dev-agent` |
| Claimed | `fabric-dev-agent` + `agent-in-progress` |
| Blocked | `fabric-dev-agent` + `blocked` |
| Implementation complete | `ready-for-review` |
| Review findings | `changes-requested` |
| Approved by reviewer | `approved-by-agent` |
| Human decision required | `human-decision-required` |

```
                    +---------------------------+
                    |  fabric-dev-agent (new)   |
                    +-------------+-------------+
                                  |  dispatcher claims
                                  v
                    +---------------------------+
              +---->|     agent-in-progress     |-----+
              |     +-------------+-------------+     | ambiguity,
              |                   | implementation    | missing target,
              |                   | complete          | safety conflict
              |                   v                   v
              |     +---------------------------+   +---------+
              |     |     ready-for-review      |   | blocked |
              |     +-------------+-------------+   +----+----+
              |                   | reviewer verdict     |
              |         +---------+---------+            | human clears
              |         |         |         |            |
              |         v         v         v            |
              | changes-    approved-   blocked <--------+
              | requested   by-agent
              |         |         |
              +---------+         | HUMAN merge only
                                  v
                              Issue closed
```

## 3. Allowed transitions

| From | To | Trigger | Actor |
|---|---|---|---|
| new | `agent-in-progress` | dispatcher claims the ticket | developer dispatcher |
| `agent-in-progress` | `ready-for-review` | implementation complete, PR opened | developer agent |
| `agent-in-progress` | `blocked` | ambiguity, missing target, safety conflict | developer agent |
| `agent-in-progress` | `human-decision-required` | a decision no agent may make | developer agent |
| `ready-for-review` | `approved-by-agent` | reviewer returns APPROVED | reviewer agent |
| `ready-for-review` | `changes-requested` | reviewer returns CHANGES REQUESTED | reviewer agent |
| `ready-for-review` | `blocked` | reviewer returns BLOCKED | reviewer agent |
| `changes-requested` | `agent-in-progress` | developer resumes work | developer dispatcher |
| `blocked` | `agent-in-progress` | human clears the block | **human** |
| `blocked` | `human-decision-required` | escalation | **human** |
| `human-decision-required` | any | human decides | **human** |
| `approved-by-agent` | merged / closed | **human merge** | **human** |

## 4. Invalid states — the dispatcher must refuse

An ambiguous state is a **stop condition**, never something to resolve by
picking the most likely interpretation. If a dispatcher guesses, the label set
stops describing reality and the audit trail becomes fiction.

| Invalid state | Why it is refused |
|---|---|
| `approved-by-agent` **and** `changes-requested` | Contradictory verdicts. Which one governs cannot be inferred. |
| `approved-by-agent` **and** `blocked` | A block is unresolved; approval cannot coexist with it. |
| `ready-for-review` **and** `agent-in-progress` | Work cannot be simultaneously finished and underway. |
| `blocked` **and** `agent-in-progress` | A blocked ticket is not being worked on. |
| `blocked` **and** `ready-for-review` | Blocked work is not reviewable. |
| `human-decision-required` with any agent-active label | A human decision is outstanding; no agent may proceed. |
| `agent-in-progress` with **no** branch or worktree | The label claims work that does not exist. |
| `agent-in-progress` on more than one Issue at a time | Concurrency is not supported; see section 5. |
| `fabric-dev-agent` absent on a ticket being claimed | Not an eligible ticket. |
| Fabric deployment permitted, but no explicit target configuration | The agent must stop and ask, never infer. |

On encountering any of these the dispatcher **exits non-zero without changing
GitHub state**, and reports the Issue number and the conflicting labels.

## 5. One ticket at a time

The developer dispatcher claims **exactly one** Issue per run and refuses to
start if any Issue already carries `agent-in-progress`.

Concurrency is excluded on purpose. Two agents in two worktrees writing to the
same feature Fabric environment produce interleaved state that neither the
evidence nor the reviewer can untangle — and the failure appears as
"inexplicable data", long after the run.

## 6. Isolation

| Role | Branch | Worktree |
|---|---|---|
| Developer | `feature/issue-<number>-<short-name>` | `worktrees/developer/issue-<number>` |
| Reviewer | reads the PR head, detached | `worktrees/reviewer/pr-<number>` |

The reviewer worktree is **detached**, so a reviewer cannot commit onto the
developer's branch. The reviewer receives no developer scratchpad, no
uncommitted files and no chain-of-thought — only what is committed and
therefore checkable. A claim that survives only in the developer's reasoning is
an **unsupported claim**, and identifying those is part of the review.

Worktree contents are ignored by the parent repository.

## 7. What the dispatchers will not do

Neither dispatcher merges, pushes to `main`, force-pushes, deletes a branch or
worktree, calls a Fabric API, or writes a credential anywhere. These are
asserted by tests in `tests/dispatcher.tests.ps1`, not merely by convention.

**Dry-run is the default for both.** Live mode requires an explicit `-Mode Live`
argument. A dispatcher that defaulted to live would turn a careless invocation
into a GitHub write.

## 8. Human authority

Three things are always human:

1. **Merging** into `main`
2. **Deploying** to a existing Fabric item
3. **Clearing** a `blocked` or `human-decision-required` ticket

Agents prepare, evidence and recommend. Humans decide.

## 8a. Fabric deployment — what replaces Git sync

Native Fabric Git integration is **disabled by tenant policy**, so the reference
model's mechanism — branch → feature workspace → Git sync → run → sync back — is
unavailable at every arrow.

The substitute is one-way and explicit:

```
repository definition (committed)
  → snapshot existing definition, if modifying
    → deploy via Fabric REST (Create / Update Item Definition)
      → run and poll to a terminal state
        → read runtime state back
          → commit evidence to the feature branch
```

### Invariants

- **The repository is the source of truth.** The agent edits local definitions
  and deploys them. It never makes a portal change absent from the repo.
- **There is no sync-back.** Anything existing only in Fabric is invisible to
  review and is treated as a defect, detected by the inventory diff.
- **Acceptance is not evidence.** A `200`, `201` or `202` proves a request was
  accepted, not that anything works.

### Required sequence

| Step | Action | Failure behaviour |
|---|---|---|
| 1 | Pre-deployment inventory of the target folder | Abort if the folder cannot be enumerated |
| 2 | Verify every target is on the ticket's item **and data-path** allowlist | Abort on any undeclared target |
| 3 | Snapshot existing definitions of anything being modified | Abort if a snapshot cannot be taken |
| 4 | Deploy definitions from the repository | Stop; reversal plan applies |
| 5 | Run, polling to a terminal state | Report the real terminal status, never the submission |
| 6 | Read runtime state back and reconcile | A failed reconciliation is a failed ticket |
| 7 | Post-deployment inventory, diffed against step 1 | Any undeclared change is a defect |
| 8 | Commit the evidence package to the feature branch | — |

Deletion is **never executed automatically**. Cleanup is human.

### Isolation is organizational, not enforced

Work is filed under `<PREVIOUS_EXPERIMENT_FOLDER>` in the shared
`<FABRIC_WORKSPACE>` workspace. That folder is **not** a security, Git, capacity or
permission boundary.

The agent runs under a delegated user identity with Workspace Admin rights and
can technically reach anything in `<FABRIC_WORKSPACE>`. Every item is therefore prefixed
with the GitHub Issue number, one job runs at a time, and pipeline concurrency
is 1 — because the capacity is a shared, modest and a Spark run can throttle other
people's work.

See [`environment-and-constraints.md`](environment-and-constraints.md) for the full limitation
and residual-risk record.

## 8b. Iteration ceiling

The developer/reviewer cycle can loop: changes requested, changes made,
re-reviewed. Each iteration costs budget and touches a shared workspace.

Every ticket carries a **maximum iteration count**. On reaching it the
dispatcher stops, applies `human-decision-required`, and waits. An agent loop
with no ceiling is a cost and blast-radius risk, not just an inefficiency.

## 9. Current phase limitations

This is a **local control-plane prototype** running at Level 1 maturity.

- Native Fabric Git integration is **disabled by tenant policy**; REST
  deployment substitutes for it.
- There is **no service principal**; agents run under a delegated user identity
  and inherit its permissions.
- Isolation is **organizational, not enforced** — a folder in a shared
  workspace, not a sandbox.
- It does not run unattended; dispatchers are invoked deliberately and default
  to dry-run.

See [`environment-and-constraints.md`](environment-and-constraints.md) for the verified
environment, the maturity ladder and the open design decisions, and
[`agent-toolbox.md`](agent-toolbox.md) for the deployment command contract.

See also [`environment-and-constraints.md`](environment-and-constraints.md) for the local
file-based ticket workflow, which remains valid and is complementary: this
document covers the GitHub-Issue-driven path.
