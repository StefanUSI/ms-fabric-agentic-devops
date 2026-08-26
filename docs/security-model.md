# Security model

How this control plane stays safe while AI agents do real work against
Microsoft Fabric.

The model rests on four ideas: secrets never enter Git, authentication happens
outside the repository, deployment boundaries are explicit rather than
inferred, and the party doing the work is never the party approving it.

> ## Read this first: what this model cannot do
>
> In the current phase there is **no service principal**. Claude operates under a
> **delegated user identity** and inherits every permission that user holds in
> the `<FABRIC_WORKSPACE>` workspace, where the operator is Workspace Admin.
>
> Therefore **every Fabric restriction in this repository is an instruction, not
> a permission.** An agent that ignores a rule below is not stopped by anything
> at the identity layer.
>
> The organizational folder `<PREVIOUS_EXPERIMENT_FOLDER>` is **not a
> security boundary**. It does not constrain reach, it does not cover Lakehouse
> data, and it must never be described as isolation.
>
> This is a known, accepted limitation of Level 1. It is documented in
> [`environment-and-constraints.md`](environment-and-constraints.md) with its residual risks. Do
> not present instruction-based restrictions as equivalent to permission-based
> ones, in this repository or in any report drawn from it.

---

## 1. Secrets are never stored in Git

No token, password, client secret, API key, connection string, SAS token,
certificate or private key is ever committed to this repository — not in source,
not in configuration, not in documentation, not in test fixtures, not in
runtime evidence, not in a commit message.

This is enforced at three layers:

| Layer | Control |
|---|---|
| **Prevention** | `.gitignore` excludes secret file shapes, cloud CLI state, and authentication output before anything can be staged |
| **Detection** | Every prospective tracked file is scanned for credential indicators before staging |
| **Response** | A suspected secret is a hard stop: report file path, line number and category only — never the value |

Git history is effectively permanent. A secret committed and then deleted is
still in the history, still in every clone, and still in every fork. There is
no "remove it in the next commit" remedy, which is why the control sits before
staging rather than after.

### Why the ignore rules are ordered the way they are

A later negation in `.gitignore` overrides an earlier ignore rule. A convenient
blanket negation such as `!config/**` would silently re-include an accidental
`config/secrets.json` and quietly undo the secret rules above it.

Negations in this repository are therefore scoped to Fabric artefact shapes
only, never to whole directories. See
[`repository-structure.md`](repository-structure.md) for what is deliberately
tracked.

---

## 2. Authentication is handled outside repository files

Authentication is interactive and browser-based, performed by the human. The
resulting credential lives in **OS-level credential storage** (the Windows
keyring), managed by the GitHub CLI and Azure CLI.

Consequences that agents must respect:

- Agents **never run an interactive login** on the human's behalf.
- Agents **never read, print, export or store** the authentication token — not
  into a file, a log, a command argument, an evidence record or a chat message.
- Agents **never request a password**. There is no circumstance in this
  repository where an agent needs one.
- Tokens are **never passed as command-line arguments**, where they would be
  visible in process listings and shell history.

The repository holds *intent* and *identifiers*. It never holds the means of
authentication. Configuration in `config/` names **what** to act on;
credentials to act **with** are resolved at runtime from outside the repository.

### Commit identity

Commits use a GitHub no-reply address rather than a real mailbox. Author email
is permanently embedded in every commit object and readable by anyone who can
read the repository — including after a repository is made public, forked or
mirrored.

---

## 3. Feature development must use explicit deployment boundaries

Every environment an agent may touch is **named in advance**, in a target
configuration under `config/`, referenced by an approved ticket.

Two classes of environment exist:

- **The authorised target** — supplied by the approved local environment configuration. The agent deploys there and nowhere else.
- **Existing Fabric items** — never modified without both an approved ticket and
  an explicit target configuration, and never deployed to without human
  approval.

### Identifiers are supplied, never inferred

An agent must not deduce a target from a naming convention, from the only
plausible candidate, from what was used last time, or from a partial name
match. Ambiguity is a stop condition, not a problem to solve:

- two items sharing a display name → **stop**
- an item name with no workspace → **stop**
- a GUID that does not resolve → **stop**, not retry

The failure this prevents is the expensive one: an agent confidently writing to
a production workspace because the name looked close enough.

### Acceptance is not verification

An HTTP `200`, `201` or `202` means a request was accepted. It does not mean
the change took effect, the item is valid, or the notebook runs. Every mutation
is followed by a read-back of actual runtime state, and evidence derived from a
response body alone does not count as evidence.

---

## 4. Developer and reviewer responsibilities are separated

The Developer Agent and the Reviewer Agent run in **different worktrees and
different contexts**, defined in [`../AGENTS.md`](../AGENTS.md).

| | Developer Agent | Reviewer Agent |
|---|---|---|
| Branch | assigned feature branch only | reads only |
| Fabric | permitted the authorised target only | read-only |
| Developer's scratchpad | owns it | never receives it |
| Outcome | review package | APPROVED / CHANGES REQUESTED / BLOCKED |
| Merge | never | never |

The reviewer starts cold, from a clean checkout, with no memory of how the
change was built. This is deliberate: a reviewer sharing the developer's
context inherits the developer's blind spots and stops being an independent
check. A claim supported only by the developer's reasoning — rather than by
artefacts in the review package — is an unsupported claim, and identifying
those is part of the reviewer's job.

The reviewer also never fixes what it finds. An agent that edits the code is no
longer reviewing it.

---

## 4a. Dispatcher security posture

The local dispatchers are the only components that talk to GitHub. Their
security properties are asserted by `tests/dispatcher.tests.ps1` rather than
left to reviewer vigilance.

| Property | How it is enforced |
|---|---|
| **Dry-run by default** | `-Mode` defaults to `DryRun`, constrained by `ValidateSet`. Tests parse the AST and assert the default, so a change to `Live` fails the suite. |
| **No merge** | Token-level scan of the dispatcher source, excluding comments and strings, asserts no merge invocation exists. |
| **No push, no force-push** | Same scan asserts no `push`, `--force` or `--force-with-lease`. |
| **No branch or worktree deletion** | Same scan asserts no deletion invocation. |
| **No Fabric call** | Source scan asserts no Fabric or AAD endpoint appears. |
| **No token handling** | The dispatchers check only the CLI's *exit status*. The token is never requested, read, printed, logged or written — not even masked. |
| **No credentials in manifests** | Manifests carry paths and identifiers only, and are scanned for token, password and key shapes. |
| **No credentials in config** | All three config files are walked value-by-value and asserted free of credential and GUID shapes. |
| **One job at a time** | Configured maximum of one, plus a lock-file gate and a refusal when any Issue already carries `agent-in-progress`. |

### Ambiguity is refused, never resolved

A contradictory label set — `approved-by-agent` together with
`changes-requested`, for instance — causes the dispatcher to exit non-zero
without changing GitHub state.

This matters more than it first appears. A dispatcher that picks the most likely
interpretation makes the labels stop describing reality, and the audit trail
becomes fiction precisely where a human would later look to reconstruct what
happened.

### Authentication boundary

Authentication is the human's own interactive GitHub CLI session, held in
OS-level credential storage. There is **no service principal, no stored secret
and no authentication file** in this phase. A dispatcher that cannot
authenticate stops and tells the human to run `gh auth login` themselves; it
never attempts to authenticate on their behalf.

## 4b. Working without identity isolation

Level 1 has no service principal, so the compensating controls below carry the
weight that permissions normally would. They are weaker. They are what is
available.

### Allowlist items *and* data paths

A ticket declares every Fabric item it may touch **and every data path it may
write**. The second half matters more than it looks: items live in folders,
**Lakehouse tables do not**. An item inventory can come back perfectly clean
while Gold tables were overwritten — the strongest-looking control has a hole
exactly where the damage would be.

Anything not declared is a rejected side effect, not a judgement call.

### Inventory before and after

A pre-deployment inventory of the target folder is captured, and a
post-deployment inventory compared against it. An undeclared item appearing,
changing or disappearing is a defect.

Because there is no Git sync-back, this diff is the **only** mechanism that
detects a change made outside the repository.

### Snapshot before modifying

Creating an item is reversible by deleting it. Modifying one is reversible only
if the previous definition was captured **first**.

So `Get Item Definition` runs before any update, and the prior definition is
stored in the evidence package. Without that step a "reversal plan" for a
modification is a wish, not a plan.

### Issue-number prefix as a real control

Item display names are unique **per workspace**, not per folder. The agent can
therefore collide with items in folders it never sees. Prefixing every
ticket-scoped item with the Issue number is the actual collision-avoidance
mechanism — treat it as a control, not a naming convention.

### One job at a time, concurrency 1

`<FABRIC_WORKSPACE>` runs on a shared **<SKU>** capacity — 2 CUs. A Spark run can throttle or
queue other people's work, causing real impact that leaves no item-level trace.
One ticket, one Fabric job, pipeline concurrency set to 1.

### A ceiling on iterations

A developer/reviewer cycle can loop. Each iteration costs budget and each
deployment touches a shared workspace. Every ticket carries a maximum iteration
count, after which work stops and waits for a human.

### Reviewer write capability — an honest limit

The reviewer shares the developer's identity and **inherits Fabric write
access**. "The reviewer cannot write to Fabric" is an aspiration in Level 1.

The strongest available mitigation is that the **deploy scripts are absent from
the reviewer's worktree and context package**. That is a real barrier rather
than a sentence, but it is weak, and it is recorded as residual risk rather than
claimed as a control.

### Where enforcement is actually possible

Fabric least-privilege is unavailable, but **GitHub is not**. A branch protection
rule or ruleset on `main` requiring a pull request and blocking direct pushes
makes "no agent pushes to `main`" an **enforced permission** rather than an
instruction.

It is the only permission-based control within reach in this phase, and it
should be enabled before the first live ticket.

## 5. The human remains the only merge authority

Two gates are always human, with no agent path around either:

- **Merge** into `main`
- **Modification** of an existing Fabric item

Agents prepare, evidence and recommend. Humans decide.

After bootstrap, no agent commits to `main`, pushes to `main`, or merges a
feature branch. Approval of one such action is never approval of the next.

Finally: **no safety control may be weakened in order to complete a ticket.**
Not by broadening a target configuration, relaxing an ignore rule, skipping a
verification, downgrading a blocking review, or committing a secret
"temporarily". A ticket that cannot be completed within these controls is a
ticket to escalate, not a control to route around.

---

## Threat summary

| Threat | Control |
|---|---|
| Credential committed to history | Ignore rules + pre-staging scan + hard stop |
| Token leaked via logs or evidence | Agents never read or print tokens; no tokens in arguments |
| Real email exposed in commit history | GitHub no-reply commit identity |
| Accidental write to production | Explicit target config; identifiers never inferred; ambiguity stops work |
| Change believed applied but silently failed | Runtime read-back required; HTTP acceptance rejected as evidence |
| Self-approved or unreviewed change | Separate reviewer worktree and context; reviewer cannot edit the branch |
| Unauthorised code reaching `main` | Human-only merge and stable-deployment authority |
| Controls eroded under delivery pressure | Explicit rule: never weaken a control to complete a ticket |
| Contamination from the prior project | Repository isolation; parent project never inspected or copied from |
| **Agent reaches any item in the shared workspace** | *Not preventable in Level 1.* Allowlist + inventory diff + human review |
| **Shared Lakehouse data overwritten** | Data-path allowlist + pre-modification snapshot |
| **Capacity throttling affects other users** | One job at a time, pipeline concurrency 1, low-risk first ticket |
| **Change made in the portal, absent from the repo** | Inventory diff; no sync-back exists to catch it otherwise |
| **Reviewer writes to Fabric** | *Not preventable in Level 1.* Deploy scripts withheld from reviewer context |
| **Runaway developer/reviewer loop** | Maximum iteration count per ticket |
| **Agent pushes to `main`** | GitHub branch protection — the one enforceable permission available |
