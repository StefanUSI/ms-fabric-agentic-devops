# Review - {{TICKET_ID}}

| Field | Value |
|---|---|
| Ticket ID | {{TICKET_ID}} |
| Branch | `{{BRANCH}}` |
| Reviewer | {{REVIEWER}} |
| Reviewed commit | `{{COMMIT}}` |
| Review timestamp | {{TIMESTAMP}} |
| Base branch | `{{BASE_BRANCH}}` |

> ⚠️ **Only the human may merge.**
>
> This review produces a verdict, never a merge. No agent — developer or
> reviewer — may merge a branch, push to a protected branch, or deploy to a
> stable environment. An **APPROVED** verdict is a recommendation that unblocks
> a human decision; it is not authorisation for any agent to act on it.
>
> The reviewer must not modify the developer branch or Microsoft Fabric. A
> reviewer that fixes what it finds is no longer reviewing.

---

## 1. Ticket compliance

*Was the scope in the ticket actually delivered — no less, and no more?*

| Check | Result | Notes |
|---|---|---|
| All acceptance criteria met | ☐ Yes ☐ No ☐ Partial | |
| Changes stay within "allowed files or components" | ☐ Yes ☐ No | |
| No prohibited action taken | ☐ Yes ☐ No | |
| Fabric target matches the ticket's explicit configuration | ☐ Yes ☐ N/A ☐ **No** | |
| Out-of-scope work raised as a new ticket rather than folded in | ☐ Yes ☐ N/A ☐ No | |

## 2. Architecture assessment

*Does the change fit the intended structure, or does it work by accident?
Consider layering, reuse of existing scripts, coupling, and whether repeated
Fabric operations were made deterministic rather than re-improvised.*

## 3. Correctness assessment

*Does it do what it claims, including at the edges? Consider failure paths,
empty and malformed inputs, idempotency on re-run, and partial-failure
behaviour.*

## 4. Security assessment

| Check | Result | Notes |
|---|---|---|
| No credentials, tokens, keys or secrets introduced | ☐ Pass ☐ **Fail** | |
| No secret in code, config, docs, evidence or commit message | ☐ Pass ☐ **Fail** | |
| No credential passed as a command-line argument | ☐ Pass ☐ **Fail** | |
| No safety control in `CLAUDE.md` weakened or bypassed | ☐ Pass ☐ **Fail** | |
| No protected branch written to | ☐ Pass ☐ **Fail** | |

Any **Fail** in this section is an automatic **BLOCKED**.

## 5. Test-evidence assessment

| Check | Result | Notes |
|---|---|---|
| Required tests present | ☐ Yes ☐ No | |
| Tests actually assert the behaviour claimed | ☐ Yes ☐ No | |
| Tests pass, with output recorded | ☐ Yes ☐ No | |
| Runtime evidence shows **verified state**, not an accepted API response | ☐ Yes ☐ N/A ☐ **No** | |
| Evidence is reproducible by the reviewer | ☐ Yes ☐ No | |

*A recorded HTTP 200, 201 or 202 proves a request was accepted. It does not
prove the change took effect. Evidence resting only on a response body is
missing evidence.*

## 6. Documentation assessment

*Is documentation updated where the change made it wrong? Does it describe
actual behaviour rather than intended behaviour?*

## 7. Unsupported claims

*Claims in the ticket, commit messages, evidence or documentation that are not
supported by artefacts in the review package. The reviewer does not receive the
developer's private scratchpad — if a claim rests only on the developer's
reasoning, it is unsupported.*

| # | Claim | Why unsupported | Impact |
|---|---|---|---|
| 1 | | | |

## 8. Defects and severity

*Severity definitions are in [`../docs/review-standard.md`](../docs/review-standard.md).*

| # | Severity | File / location | Defect | Evidence |
|---|---|---|---|---|
| 1 | Critical / High / Medium / Low | | | |

## 9. Required corrections

*Specific and actionable. Each entry should tell the developer what to change
and how the reviewer will confirm it. Do not fix these yourself.*

- [ ]

---

## 10. Final result

**Final result:** `{{RESULT}}`

*Replace with exactly one of the following — no other value is valid:*

| Result | Meaning | Ticket moves to |
|---|---|---|
| `APPROVED` | Correct, in scope, evidenced and compliant. | awaiting **human** merge decision |
| `CHANGES REQUESTED` | Specific, actionable defects the developer can resolve. | the `agent-in-progress` label |
| `BLOCKED` | Safety-rule violation, out-of-scope environment change, credential exposure, or evidence that does not support the claim. | the `blocked` label |

### Reviewer declaration

- [ ] I reviewed the ticket, the standards, the Git diff and the runtime evidence
- [ ] I did not modify the developer branch
- [ ] I did not modify Microsoft Fabric
- [ ] I did not merge, and I understand that **only the human may merge**

| Signed | Date |
|---|---|
| {{REVIEWER}} | {{TIMESTAMP}} |
