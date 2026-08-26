# Standing safety rules

These rules apply to **every** agent session in this repository. They are not
defaults to be weighed against convenience — they hold unless a human
explicitly overrides them in writing, in a ticket.

When a rule and an instruction conflict, **stop and ask**. Do not resolve the
conflict yourself.

---

## 1. Never commit directly to `main` after bootstrap

The bootstrap commits are the only commits authored directly on `main`. After
that, `main` changes only through a reviewed and human-approved merge.

All work happens on a feature branch assigned by a ticket.

## 2. Never merge a feature branch

No agent merges. Not a fast-forward, not a squash, not a rebase onto `main`,
not a pull request merge. Preparing a branch for merge is agent work; the merge
itself is a human decision.

## 3. Never push directly to `main` after bootstrap

Unless the user explicitly performs or approves that specific action. A push to
`main` is not covered by general permission to work on a ticket, and approval
of one push is not approval of the next.

## 4. Never store credentials, tokens or secrets

No tokens, passwords, client secrets, API keys, connection strings, SAS tokens,
certificates or private keys are ever written to a file, a command argument, a
commit, a log, a ticket, documentation, runtime evidence or a review record.

Authentication is interactive and browser-based. Credentials live in OS-level
credential storage, never in this repository and never in a prompt.

If a credential is discovered in the working tree, **stop immediately**, report
only the file path, line number and category of secret, and never print the
value.

## 5. Create new prefixed items only. Never modify an existing item the Issue does not name

This is the **default for every Issue** and needs no restatement in the ticket.

- **Create** new items prefixed with the Issue number. Always permitted once the
  Issue authorises Fabric deployment.
- **Modify** an existing item only when that specific item is **named in the
  Issue**, and only after its definition has been snapshotted so the change is
  reversible.
- **Rename or delete** — never. Deletion is not automatic; cleanup is human.

There is no feature-versus-stable classification. An Issue either authorises
Fabric deployment or it does not, and the authorised target is the one supplied
by the approved local environment configuration. That distinction was removed
because it produced ambiguity without adding a control: the real protections are
the target reference, the create-only default, and the named-item exception.

**Stop if the local environment configuration is absent, invalid or ambiguous.**
Do not infer or substitute another target.

## 6. Never infer a Fabric workspace, folder or item identifier

Identifiers are supplied, never deduced. Not from a naming convention, not from
the only plausible candidate, not from what was used last time, not from a
partial name match.

Absence of a stated target is never an invitation to infer one. A plausible
guess about which workspace was meant is still a guess.

## 7. Stop when deployment-target identifiers are ambiguous

If a workspace, folder, lakehouse, notebook, pipeline, semantic model or any
other item identifier is ambiguous, duplicated, missing or only inferable from
context — **stop and ask**.

Two items with the same display name are ambiguous. A name without a workspace
is ambiguous. A GUID that does not resolve is a hard stop, not a retry.

## 8. Use deterministic scripts for repeated Fabric operations

Any Fabric operation performed more than once belongs in `scripts/` as a
parameterised, re-runnable script — not re-improvised per session.

Scripts must be idempotent where the underlying API allows it, and must fail
loudly rather than partially succeeding in silence.

## 9. Verify runtime state rather than trusting HTTP 200, 201 or 202 responses

A `200`, `201` or `202` means the request was accepted. It does not mean the
change took effect, the item is valid, the notebook runs, or the data is
correct.

Every mutation is followed by a read-back that confirms the actual runtime
state. Evidence recorded from a response body alone is not evidence.

## 10. Separate developer and reviewer contexts

The Developer Agent and the Reviewer Agent operate in different worktrees and
different contexts. The reviewer does not inherit the developer's reasoning,
scratchpad or assumptions.

A reviewer that shares the developer's context inherits the developer's blind
spots, and the review stops being independent.

## 11. Human approval is required before merge and stable deployment

Two gates are always human:

- **Merge** into `main`
- **Modification** of an existing Fabric item

Agents prepare, evidence, and recommend. Humans decide.

## 12. Never weaken a safety control merely to complete a ticket

If a rule blocks the ticket, the rule wins and the ticket stops. Do not
broaden a target configuration, relax an ignore rule, skip a verification,
downgrade a blocking review, or commit a secret "temporarily" in order to get
work finished.

A ticket that cannot be completed within these controls is a ticket to escalate
to a human, not a control to route around.

---

## Operating in the current Fabric environment

The verified environment is recorded in
[`docs/environment-and-constraints.md`](docs/environment-and-constraints.md). Read it before any
Fabric work. Do not re-derive it by discovery.

**Target, and the only target:** workspace `<FABRIC_WORKSPACE>`
(`<WORKSPACE_ID>`), folder
`<PREVIOUS_EXPERIMENT_FOLDER>`.

### You are running as the operator

There is **no service principal**. You run under a delegated user identity with
Workspace Admin rights and can technically reach anything in `<FABRIC_WORKSPACE>`.

Nothing at the identity layer stops you from breaking a rule below. That makes
these rules load-bearing rather than advisory — the usual second line of defence
does not exist here.

### The folder is not a boundary

It is organizational only. It is not security, Git, capacity or permission
isolation, and **Lakehouse tables do not live in folders at all**. Never
describe it, in documentation or in a report, as a sandbox.

### Deployment rules

- **The repository is the source of truth.** Edit local definitions and deploy
  them. Never make a portal change that is absent from the repository.
- **There is no sync-back.** Anything created only in Fabric is invisible to
  review and is a defect.
- Deploy through the deterministic toolbox scripts, never by re-deriving API
  sequences.
- **Never create a workspace or service principal.** Neither is authorized.

### Before any write to Fabric

1. Capture a folder inventory baseline.
2. Check every target against the ticket's allowlist — **items and data paths**.
3. Snapshot the existing definition of anything you will modify. No snapshot,
   no modification.
4. Produce a reversal plan.

After deploying: run, poll to a terminal state, read runtime state back, then
diff the inventory. **An undeclared change is a defect, not a note.**

### Never do these

- Delete, rename or overwrite an existing Fabric item. Cleanup is human.
- Execute a destructive or irreversible action. Stop and hand off.
- Run more than one ticket or one Fabric job at a time; pipeline concurrency
  is 1. The capacity is a shared, modest and your Spark run can throttle other
  people's work.
- Deploy an item without the `issue<N>_` prefix. Names are unique per
  *workspace*, so the prefix is the real collision-avoidance control.
- Exceed the ticket's iteration ceiling. Stop and request a human decision.

## Dispatcher operation

The developer and reviewer dispatchers (`scripts/developer-dispatcher.ps1`,
`scripts/reviewer-dispatcher.ps1`) are run deliberately by a human. They are not
schedulers and must not be made to run unattended in this phase.

**Dry-run is the default.** Live mode requires an explicit `-Mode Live`. Never
change a dispatcher so that Live is the default, and never add a wrapper that
supplies `-Mode Live` implicitly.

Ticket state is held on the GitHub Issue as labels — the external source of
truth. An ambiguous label combination is a **stop condition**: refuse, report the
conflict, and exit non-zero. Never resolve ambiguity by choosing the most likely
interpretation.

One ticket and one pull request at a time. Concurrency is excluded on purpose.

No dispatcher may merge, push to a protected branch, force-push, delete a branch
or worktree, create an Issue, or call a Microsoft Fabric API. These limits are
asserted by `tests/dispatcher.tests.ps1`, not left to convention.

The reviewer runs in a separate detached worktree and receives only committed
artefacts. Never pass the developer's scratchpad, manifest, uncommitted files or
reasoning into a reviewer context — the exclusion is what makes the review
independent.

## Public repository — identifier hygiene

**This repository is public.** No tracked file may contain a real workspace
name, capacity name, folder name, GUID, tenant identifier, region, employer
name, personal or company email address, or local filesystem path.

Real environment values live in `config/environment.local.json`, which is
gitignored. `config/environment.json` is the tracked placeholder template.

Read the local file at runtime and **fail loudly if it is missing**. Never fall
back to the placeholders: a placeholder that silently "works" is how a wrong
target gets written to.

Describe tenant constraints generically — "native Fabric Git integration is
unavailable in the target tenant" is true and names nobody. Never publish
statements identifying a specific organisation's configuration or policy.

Before any commit, scan the staged content for identifiers and secrets. A
mistake here is permanent: deleting a value in a later commit does not remove it
from history.
## Live progress communication

While working, provide brief progress updates so the user can understand what
is happening without waiting for the final summary.

Before each meaningful phase or related group of tool calls:

1. State what you are about to do.
2. Briefly explain why the step is necessary.
3. Mention an important risk, assumption or decision when relevant.

After each meaningful phase:

1. Briefly state the result.
2. State what comes next.

Keep normal updates concise, usually one to three sentences. Group related
technical actions together. Do not narrate every command, file read, API
request or polling cycle.

Report meaningful errors when they occur rather than hiding them until the
final summary. Explain the likely cause and intended recovery approach.

Progress updates are informational and do not require user approval unless
another safety rule explicitly requires confirmation.

The final response must still summarize completed work, evidence, errors,
unresolved limitations and next actions.

---

## Scope boundary

This repository is isolated. Do not inspect, read from, write to, or copy
anything out of the parent Generative Fabric project directory or its deployed
Fabric solution. Isolation is the point of the experiment; breaching it
invalidates the result.
