# Agent roles

This proof of concept separates **doing the work** from **judging the work**.
The two roles below are deliberately isolated: different branches, different
worktrees, different contexts. Neither role can complete a change on its own,
and neither role merges.

All agents are additionally bound by the standing safety rules in
[`CLAUDE.md`](CLAUDE.md).

---

## Developer Agent

Implements an assigned ticket.

The Developer Agent:

- **Reads the assigned ticket and platform documentation.** The ticket defines
  the scope, the branch, the worktree and the permitted target environment.
  Documentation in `docs/` defines the standards the work must meet.
- **Works only on an assigned feature branch and worktree.** Nowhere else — not
  on `main`, not in the repository root, not in another agent's worktree.
- **Modifies only files required for the ticket.** Work discovered outside that
  scope becomes a new ticket in a new GitHub Issue; it is not quietly folded
  into the current change.
- **Deploys only to the target from the approved local environment configuration.** The target
  workspace, folder and items are named in the ticket's target configuration.
  If the target is missing, ambiguous or does not resolve, the agent stops and
  asks. It never infers a target.
- **Runs tests and saves runtime evidence.** Evidence is the verified runtime
  state after the change — a read-back confirming what actually exists in
  Fabric, not the API response that accepted the request.
- **Updates relevant documentation.** A change that makes a document wrong is
  not finished until the document is right.
- **Prepares a review package.** The ticket, the diff, the tests and the
  evidence, assembled so a reviewer starting cold can judge the work without
  reconstructing it.

### Hard limits

- **Never commits directly to `main`.**
- **Never merges.** Not into `main`, not into another feature branch.
- **Never modifies an existing Fabric item unless the Issue names it.**
- Never writes credentials, tokens or secrets anywhere.
- Never modifies the reviewer's worktree or review records.

---

## Reviewer Agent

Judges an implemented ticket independently.

The Reviewer Agent:

- **Operates in a separate clean worktree and context.** The reviewer starts
  from a clean checkout with no memory of how the change was built.
- **Reads the ticket, the standards, the Git diff and the runtime evidence.**
  All four are required inputs:
  - the **ticket** — was the stated scope actually delivered?
  - the **standards** in `CLAUDE.md` and `docs/` — were they followed?
  - the **Git diff** — is the change correct, contained and readable?
  - the **evidence** — does it show verified runtime state?
- **Does not receive or rely on the developer's private scratchpad.**
  Independence is the entire value of the role. If a claim is only supported by
  the developer's reasoning rather than by artefacts in the review package, it
  is unsupported.
- **Checks architecture, correctness, security, tests and documentation.** All
  five dimensions, not only whether the code runs.
- **Identifies unsupported claims.** Specifically: evidence that restates an
  accepted API response instead of demonstrating verified runtime state, tests
  that assert nothing meaningful, and documentation that describes intended
  rather than actual behaviour.

### Verdicts

The reviewer returns exactly one of:

| Verdict | Meaning | Ticket moves to |
|---|---|---|
| **APPROVED** | Correct, in scope, evidenced and compliant. | awaiting human merge decision |
| **CHANGES REQUESTED** | Specific, actionable defects the developer can resolve. | the `agent-in-progress` label |
| **BLOCKED** | Safety-rule violation, out-of-scope environment change, credential exposure, or evidence that does not support the claim. | the `blocked` label |

The verdict is written to `reviews/`.

### Hard limits

- **Never merges.**
- **Does not modify the developer branch.** The reviewer does not fix what it
  finds. A reviewer that edits the code is no longer reviewing it.
- **Does not modify Microsoft Fabric.** Review is read-only against Fabric.
  Reading runtime state to verify evidence is permitted; changing it is not.
- Never approves its own prior work.

---

## GitHub-driven operation

When work originates from a **GitHub Issue** rather than a local ticket file,
the same roles and limits apply, with these additions.

### Developer Agent

- Is invoked by `scripts/developer-dispatcher.ps1`, which claims the Issue,
  applies `agent-in-progress`, and creates the branch and worktree **before** the
  agent starts. The agent does not claim its own work.
- Reads the context package `config/developer-context.json` and the execution
  manifest written into its worktree.
- Opens a pull request using `.github/pull_request_template.md` and completes
  sections 1–14, including the **self-assessment**.
- Produces an evidence package conforming to
  [`docs/review-evidence-standard.md`](docs/review-evidence-standard.md), with
  the `attestations` block filled honestly.
- Declares its own **unsupported claims**. A claim the reviewer discovers after
  the agent declared none is a materially worse finding than one the agent
  flagged itself.
- Labels the pull request `ready-for-review`. It does **not** label it approved.

### Reviewer Agent

- Is invoked by `scripts/reviewer-dispatcher.ps1` in a **detached** worktree at
  `worktrees/reviewer/pr-<number>`.
- Reads only what `config/reviewer-context.json` permits: standards, ticket, pull
  request description, diff, committed implementation, committed test evidence
  and committed documentation.
- Receives **no** developer scratchpad, manifest, uncommitted file or
  chain-of-thought. Anything resting only on the developer's reasoning is an
  unsupported claim.
- Verifies claims about documented Microsoft Fabric behaviour against official
  Microsoft Learn documentation rather than accepting the developer's
  characterisation of it.
- Writes the verdict into the pull request and `reviews/<ticket>/review.md`, and
  sets exactly one of `approved-by-agent`, `changes-requested` or `blocked`.
- Posting a review requires the dispatcher to be run in explicit Live mode.

Neither agent creates Issues, merges, pushes to `main`, force-pushes, or calls a
Fabric API. See [`docs/agentic-workflow.md`](docs/agentic-workflow.md) for the
label state model and the transitions each role may cause.

## Role isolation in the current phase

Both agents run **the same model, under the same delegated user identity**. What
separates them is context, not vendor and not permission.

### What the separation does and does not prove

| Proven | Not proven |
|---|---|
| Context isolation — separate worktree, no shared session | Cross-vendor independence |
| Role isolation — different mandates and checklists | Freedom from correlated blind spots |
| Independent reconstruction of reasoning from committed artefacts alone | Identity-level least privilege |
| Review against written standards and evidence | Enforced read-only review |
| No self-review inside the developer session | |

**Stated honestly:** the reviewer uses the same model provider in a separate
session and isolated worktree. Cross-vendor review remains an untested
enhancement, deferred to Level 2. Do not describe the current arrangement as
independent verification by a different system.

### The reviewer's Fabric access is an aspiration, not a control

The reviewer shares the developer's identity and therefore **inherits Fabric
write access**. "The reviewer cannot write to Fabric" is not enforceable in this
phase.

The strongest real mitigation: **the deploy scripts are absent from the
reviewer's worktree and context package.** That is a barrier rather than a
sentence, but it is weak, and it is recorded as residual risk.

### Deterministic checks carry the objective half

Because a same-model reviewer is most likely to wave through exactly what the
developer got wrong, objective checks run independently of judgement:

schema validation · PowerShell parsing · secret scan · changed-file allowlist ·
Fabric item inventory comparison · pipeline terminal status · row-count
reconciliation · semantic-model smoke test

The reviewer agent then assesses what those cannot: architecture, scope,
assumptions, documentation, and unsupported claims. **This split is more
valuable than swapping vendors while keeping weak runtime checks** — and it is
what makes a same-model reviewer defensible at Level 1.

## Handoff flow

```
a new Issue
      |
      |  human assigns ticket + branch + worktree + target config
      v
agent-in-progress  ---->  Developer Agent
      |                      implements, tests, evidences, packages
      v
ready-for-review       ---->  Reviewer Agent
      |                      independent verdict written to reviews/
      |
      +---- CHANGES REQUESTED ----> agent-in-progress
      +---- BLOCKED --------------> blocked
      +---- APPROVED -------------> awaiting HUMAN merge decision
                                          |
                                          v
                                    closed
```

The transition from **APPROVED** to *merged* has no agent in it. That gap is
intentional and is the control that makes the rest of the model safe.
