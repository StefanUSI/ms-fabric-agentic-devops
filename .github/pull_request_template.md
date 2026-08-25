<!--
  Developer agent: fill sections 1-13. Leave section 14 for the reviewer agent
  and section 15 for the human.

  Never paste a credential, token, password, device code or authentication
  output into a pull request. Pull requests are permanent.
-->

## 1. Ticket reference

Closes #<issue-number>

| Field | Value |
|---|---|
| Ticket | #<issue-number> |
| Branch | `feature/issue-<number>-<short-name>` |
| Base | `main` |
| Fabric deployment permitted | Yes (feature) / Yes (stable) / No |

## 2. Summary

*What outcome now exists that did not before? Two or three sentences, stated as
a result rather than a list of edits.*

## 3. Architecture decisions

*Decisions taken and why, including alternatives rejected. A decision recorded
only in the agent's reasoning is not reviewable — record it here.*

| Decision | Alternatives considered | Why this one |
|---|---|---|
| | | |

## 4. Changed files

*Grouped by purpose, not a raw file dump. Anything outside the ticket's allowed
scope must be called out explicitly.*

| File | Change | In ticket scope |
|---|---|---|
| | | Yes / **No** |

## 5. Fabric items affected

*Every workspace, folder and item written to, with its identifier exactly as
supplied by the ticket. Write "None" if no Fabric access occurred.*

| Workspace | Folder | Item | Operation | Environment class |
|---|---|---|---|---|
| | | | create / update / none | feature / stable / none |

- [ ] Every target above appears verbatim in the ticket's explicit target configuration
- [ ] No identifier was inferred, guessed or matched by name

## 6. Deployment evidence

*Verified runtime state read back **after** the change. An HTTP 200, 201 or 202
proves a request was accepted, not that anything works — a response body alone
does not belong here.*

| Check | Method | Result |
|---|---|---|
| | | |

Evidence package: `reviews/<ticket>/evidence.json`

## 7. Test evidence

| Test | Asserts | Result |
|---|---|---|
| | | |

- [ ] Tests actually assert the behaviour claimed, not merely that code ran
- [ ] Test output is committed and reproducible by the reviewer

## 8. Documentation changes

| Document | Change |
|---|---|
| | |

- [ ] Documentation describes actual behaviour, not intended behaviour

## 9. Assumptions

*State assumptions explicitly so the reviewer can challenge them.*

| # | Assumption | Impact if wrong |
|---|---|---|
| 1 | | |

## 10. Errors encountered and recovery actions

*Including failures that were recovered from. A clean-looking PR that hides a
mid-run failure misrepresents how the change was produced.*

| Error | Cause | Recovery | Residual risk |
|---|---|---|---|
| | | | |

## 11. Security review

| Check | Result |
|---|---|
| No credential, token, key or secret introduced anywhere | ☐ Pass ☐ **Fail** |
| No secret in code, config, docs, evidence or commit messages | ☐ Pass ☐ **Fail** |
| No credential passed as a command-line argument | ☐ Pass ☐ **Fail** |
| No write to a protected branch; no merge performed | ☐ Pass ☐ **Fail** |
| No safety control in `CLAUDE.md` weakened or bypassed | ☐ Pass ☐ **Fail** |
| No stable environment modified without explicit approval | ☐ Pass ☐ N/A ☐ **Fail** |

Any **Fail** is an automatic **BLOCKED**.

## 12. Rollback procedure

*Exact steps to undo this change, for both the repository and any Fabric state.
"Revert the commit" is not sufficient when items were deployed.*

1.

## 13. Unresolved limitations

*What this change does not do, known gaps, and anything deferred to a new
ticket.*

-

## 14. Developer-agent self-assessment

- [ ] All acceptance criteria met and traceable to an artefact
- [ ] Changes confined to the ticket's allowed files or components
- [ ] No prohibited action taken
- [ ] Required tests present and passing
- [ ] Runtime evidence shows verified state, not an accepted API response
- [ ] Required documentation updated
- [ ] No credentials committed
- [ ] I did not merge, and I did not push to `main`

*Anything not ticked must be explained under unresolved limitations.*

---

## 15. Reviewer-agent verdict

*Completed by the reviewer agent from a separate clean worktree. The reviewer
does not receive the developer's scratchpad and does not modify this branch.*

| Section | Assessment |
|---|---|
| Ticket compliance | |
| Architecture | |
| Correctness | |
| Security | |
| Test evidence | |
| Documentation | |
| Unsupported claims | |

**Final result:** `<APPROVED | CHANGES REQUESTED | BLOCKED>`

Full review: `reviews/<ticket>/review.md`

Criteria: [`docs/review-standard.md`](../docs/review-standard.md)

---

## 16. Human merge checklist

> **Only a human may merge.** An `APPROVED` verdict is a recommendation that
> unblocks a human decision. It is never authorisation for an agent to merge,
> push to `main`, or deploy to a stable environment.

- [ ] Reviewer verdict is `APPROVED`
- [ ] I have read the diff myself, not only the summary
- [ ] Deployment evidence shows verified state, and I find it convincing
- [ ] Fabric targets match the ticket exactly
- [ ] Security section is all Pass
- [ ] Rollback procedure is workable
- [ ] Any stable-environment deployment is separately and explicitly approved
- [ ] I accept responsibility for this merge
