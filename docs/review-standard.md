# Review standard

The criteria the Reviewer Agent applies, and the rules that decide which of the
three verdicts a ticket receives.

The reviewer's job is not to confirm that something was built. It is to
determine whether what was built is **correct, in scope, evidenced and
compliant** — and to say so from a clean context, without the developer's
reasoning available to fill in gaps.

Verdicts: **`APPROVED`**, **`CHANGES REQUESTED`**, **`BLOCKED`**. Exactly one.

> Only the human may merge. An `APPROVED` verdict unblocks a human decision; it
> is never authorisation for an agent to merge, push or deploy.

---

## 1. Evidence required for approval

Nothing is approved on assertion. Every claim must be supported by an artefact
in the review package.

| Requirement | What satisfies it |
|---|---|
| **Scope** | Diff touches only files listed in the ticket's *allowed files or components* |
| **Acceptance criteria** | Each criterion traceable to a specific change, test or evidence file |
| **Tests** | Present, executed, output recorded, and asserting the behaviour actually claimed |
| **Runtime evidence** | A **read-back of actual state** after the change |
| **Target correctness** | The environment written to matches the ticket's explicit target configuration |
| **Documentation** | Updated wherever the change made an existing document wrong |
| **Security** | No credential, token or secret introduced anywhere |
| **Reproducibility** | The reviewer can re-run the tests and reach the same result |

### Acceptance is not verification

A recorded `200`, `201` or `202` proves a request was **accepted**. It does not
prove the change took effect, the item is valid, the notebook runs, or the data
is correct.

Evidence that consists only of a response body is **missing evidence**, not weak
evidence. Fabric APIs routinely accept a request and then fail asynchronously,
which is precisely the failure this rule exists to catch.

Acceptable runtime evidence reads state back after the fact: the item exists
with the expected definition, the table has the expected schema and row count,
the pipeline run reached a terminal success state, the query returns the
expected result.

## 2. Severity levels

| Severity | Definition | Effect on verdict |
|---|---|---|
| **Critical** | Safety-rule violation, credential exposure, write to a stable or unauthorised environment, or protected-branch write. | **BLOCKED** |
| **High** | Acceptance criterion unmet, incorrect behaviour on a realistic path, missing required runtime evidence, or a claim unsupported by any artefact. | **CHANGES REQUESTED** (BLOCKED if it conceals a Critical) |
| **Medium** | Correct but fragile: unhandled edge case, non-idempotent repeat, silent partial failure, missing test for a stated criterion, documentation contradicting behaviour. | **CHANGES REQUESTED** |
| **Low** | Style, naming, clarity, minor duplication. No behavioural impact. | May be **APPROVED** with the findings recorded |

Severity describes **consequence if wrong**, not effort to fix. A one-character
change that writes to production is Critical.

## 3. Handling missing runtime evidence

If the ticket required runtime evidence and it is absent, unreadable, or shows
only an accepted API response:

1. Record it as **High** under *test-evidence assessment*.
2. Record any claim that depended on it under *unsupported claims*.
3. Return **CHANGES REQUESTED**.

The reviewer does **not** generate the missing evidence. Producing evidence is
the developer's responsibility, and a reviewer who runs the verification is no
longer independently checking it. The reviewer may read Fabric state read-only
to test whether existing evidence is *truthful* — that is verification, not
production.

Escalate to **BLOCKED** if evidence appears fabricated or contradicts observable
state. That is no longer a gap; it is a claim that cannot be trusted.

## 4. Handling scope violations

A scope violation is any change outside *allowed files or components*, or any
action listed under *prohibited actions*.

| Situation | Verdict |
|---|---|
| Unrelated files changed, no safety impact | **CHANGES REQUESTED** — split into a separate ticket |
| Opportunistic refactor bundled with the change | **CHANGES REQUESTED** — bundling defeats reviewability |
| Environment touched beyond the explicit target configuration | **BLOCKED** |
| A workspace, folder or item identifier was **inferred** rather than supplied | **BLOCKED** |
| Safety control weakened to make the ticket pass | **BLOCKED** |

Out-of-scope work is not rewarded for being useful. Its cost is that the diff
no longer matches the authorisation, and the reviewer can no longer tell what
was actually approved.

## 5. Handling security findings

Any of the following is **Critical** and **BLOCKED**, without exception:

- A credential, token, password, key, certificate, connection string or SAS
  token in source, config, docs, evidence, test fixtures or a commit message
- A secret passed as a command-line argument
- Authentication output or keyring content recorded anywhere
- A write to a protected branch, or a merge performed by an agent
- A stable environment modified without an approved ticket and explicit target
- Any safety control in `CLAUDE.md` relaxed, bypassed or "temporarily" disabled

Reporting rules: record the **file path, line number and category only**. Never
reproduce the secret value in the review, the ticket, or any commit — a leaked
credential quoted into a review document is leaked twice.

A secret that reached a commit is not resolved by deleting it in a later commit.
Git history is permanent; escalate to the human immediately, because the
credential must be treated as compromised and rotated.

## 6. Handling unsupported claims

An unsupported claim is any assertion — in the ticket, commit messages,
documentation or evidence — not backed by an artefact in the review package.

The reviewer does not receive the developer's private scratchpad. This is
deliberate: if a claim is true only because of reasoning the reviewer cannot
see, then nobody has actually checked it.

Common forms:

- "Tested and working" with no test output
- "Deployed successfully" evidenced only by an HTTP status code
- "No impact on existing items" with no read-back demonstrating it
- Documentation describing intended behaviour rather than actual behaviour
- A commit message asserting a fix that the diff does not make

Handling: list each under *unsupported claims* with why it is unsupported and
the impact if false. **High** → `CHANGES REQUESTED`. If the claim concerns
safety, environment targeting or credential handling → **BLOCKED**.

## 7. Conditions requiring BLOCKED

Return **BLOCKED** when any of these hold:

- Any **Critical** security finding (section 5)
- A stable or unauthorised environment was modified
- A workspace, folder or item identifier was inferred rather than supplied
- A safety rule in `CLAUDE.md` or a role limit in `AGENTS.md` was violated
- An agent committed to `main`, pushed to a protected branch, or merged
- Evidence appears fabricated, or contradicts observable runtime state
- The ticket lacks the explicit target configuration required for what it did
- A control was weakened in order to make the ticket pass

`BLOCKED` means work cannot resume until a **human** decides. The ticket moves
to the `blocked` label. The reviewer does not clear its own block.

## 8. Conditions requiring CHANGES REQUESTED

Return **CHANGES REQUESTED** when the work is fixable by the developer within
the existing authorisation:

- One or more acceptance criteria unmet
- Incorrect behaviour on a realistic input or failure path
- Required tests missing, failing, or asserting nothing meaningful
- Required runtime evidence missing or insufficient (section 3)
- Unsupported claims with no safety dimension (section 6)
- Scope violation without safety impact (section 4)
- Required documentation missing or contradicting actual behaviour
- Medium-severity fragility: non-idempotent repeat, silent partial failure,
  unhandled edge case

Each finding must be **specific and actionable**: what to change, and how the
reviewer will confirm it. "Improve error handling" is not a finding. The
reviewer states the correction; it does not apply it.

## 9. Conditions allowing APPROVED

Return **APPROVED** only when **all** hold:

- [ ] Every acceptance criterion met and traceable to an artefact
- [ ] Diff confined to *allowed files or components*
- [ ] No prohibited action taken
- [ ] Environment written to matches the explicit target configuration exactly
- [ ] Required tests present, passing, and asserting the claimed behaviour
- [ ] Runtime evidence shows **verified state**, not an accepted API response
- [ ] Evidence reproducible by the reviewer
- [ ] No credential, token or secret introduced — all security checks pass
- [ ] No safety control weakened or bypassed
- [ ] Required documentation updated and matching actual behaviour
- [ ] No unsupported claims remain
- [ ] No Critical, High or Medium defects outstanding

Low-severity findings may remain, recorded in the review.

**Uncertainty is not approval.** If the reviewer cannot determine whether a
criterion is met, that is a finding — `CHANGES REQUESTED` — not a benefit of the
doubt. Approving something not understood transfers risk to the human who
merges it, which is exactly what the review exists to prevent.

---

## Verdict summary

| | APPROVED | CHANGES REQUESTED | BLOCKED |
|---|---|---|---|
| Trigger | All checks pass | Fixable defect within authorisation | Safety violation or untrustworthy evidence |
| Ticket moves to | awaiting **human** merge | the `agent-in-progress` label | the `blocked` label |
| Cleared by | Human merge decision | Developer, then re-review | **Human only** |
| Agent may merge | **No** | No | No |

The verdict is recorded in `reviews/<ticket-id>/review.md` after the
`Final result:` marker. the human merge step reads that marker and
proceeds only on `APPROVED`; an unset, malformed or unrecognised value is never
treated as approval.
