# Review evidence standard

Every developer-agent pull request must ship an evidence package that is both
**machine-readable** (`reviews/<ticket>/evidence.json`) and **human-readable**
(the pull-request body).

The reviewer judges the evidence, not the agent's description of it.

---

## The rule that matters most

**Acceptance is not verification.**

An HTTP `200`, `201` or `202` means a request was accepted. It does not mean the
change took effect, the item is valid, the notebook ran, or the numbers are
right. Fabric APIs routinely accept a request and then fail asynchronously —
which is precisely the failure this standard exists to catch.

Evidence consisting only of a response body is **missing evidence**, not weak
evidence, and is grounds for `CHANGES REQUESTED`.

Acceptable evidence **reads state back after the change**: the item exists with
the expected definition hash, the table has the expected schema and row count,
the job reached a terminal success state, the query returns the expected value.

> **Never fabricate a result.** Do not write an expected value into evidence as
> though it were observed, do not derive "expected" values from the run itself
> (which makes every run pass), and do not record a test as passing that was not
> executed. Fabricated evidence is a **BLOCKED** finding, not a correction — it
> makes every other claim in the package untrustworthy.

> **Never record a secret.** No token, password, connection string, SAS
> signature or authentication output belongs in an evidence file. Redact
> parameter values that carry credentials, and record `"<redacted>"`.

## Required contents

| # | Field | Meaning |
|---|---|---|
| 1 | Ticket ID | The GitHub Issue this evidence belongs to |
| 2 | Branch | Feature branch the work was produced on |
| 3 | Commit SHA | Exact commit the evidence was produced from |
| 4 | Changed artifacts | What changed, by type and path |
| 5 | Deployment target | Workspace, folder and items, resolved from the approved local environment configuration |
| 6 | Timestamps | Start and end, UTC, ISO 8601 |
| 7 | Runtime jobs and final statuses | Every job, its run id and its **terminal** status |
| 8 | Source and Gold reconciliation | Counts and deltas against tolerance |
| 9 | Semantic-model smoke tests | Query, expected, actual, verdict |
| 10 | Report validation results | PBIR findings by severity |
| 11 | Ontology validation results | Entity types, bindings, unresolved references (where applicable) |
| 12 | Errors encountered | Every error, including recovered ones |
| 13 | Recovery actions | What was done about each error, and residual risk |
| 14 | Human interventions | Any point a human acted, decided or unblocked |
| 15 | Unsupported claims | Claims the agent cannot support with an artefact |
| 16 | Rollback instructions | Exact steps to undo, repository **and** Fabric |
| 17 | **Allowlist check** | Every intended item and data path, declared vs actual |
| 18 | **Inventory before / after** | Folder baseline and post-deployment state |
| 19 | **Inventory diff** | Added, modified, removed — declared vs **undeclared** |
| 20 | **Definition snapshots** | Prior definition of anything modified, captured before the write |

### Fields 17–20 exist because isolation is not enforced

In Level 1 the agent runs under a delegated user identity in a **shared**
workspace, and the target folder is not a security boundary
([`environment-and-constraints.md`](environment-and-constraints.md)). These four fields are what
substitute for the sandbox the reference model has:

- **Allowlist check (17)** covers items *and data paths*. Items live in folders;
  **Lakehouse tables do not**. Without the data-path half, the inventory can
  come back clean while Gold tables were overwritten.
- **Inventory diff (19)** is the **only** mechanism that detects a change made
  outside the repository, because there is no Git sync-back. Any undeclared
  entry is a defect, not a note.
- **Snapshots (20)** are what make a modification reversible. Creating an item
  is undone by deleting it; modifying one is undone only if the prior definition
  was captured **first**. A reversal plan without a snapshot is a wish.

Fields 8–11 are `null` when genuinely not applicable — for a repository-only
change, for instance. `null` means "not applicable"; an **empty array** means
"applicable, and nothing was found". They are not interchangeable, and a
reviewer reads the difference.

### On field 12 — record recovered errors too

A clean-looking package that omits a mid-run failure misrepresents how the
change was produced. If a deployment failed twice and succeeded on the third
attempt, all three attempts belong in the record. The reviewer needs to judge
whether the eventual success was reliable or lucky.

### On field 15 — declare your own unsupported claims

The developer agent is expected to identify claims it cannot back with an
artefact and record them. This is not self-incrimination; it is the difference
between an honest package and one the reviewer must dismantle. An unsupported
claim the reviewer finds *after* the agent declared none is a materially worse
finding than one the agent flagged itself.

## JSON structure

Schema: [`../reviews/evidence.schema.json`](../reviews/evidence.schema.json)
Instance: `reviews/<ticket>/evidence.json`

```json
{
  "schemaVersion": 1,
  "ticketId": "42",
  "ticketUrl": "https://github.com/<owner>/<repo>/issues/42",
  "branch": "feature/issue-42-add-margin-gold",
  "commitSha": "0000000000000000000000000000000000000000",
  "generatedUtc": "2026-08-25T00:00:00Z",
  "startedUtc": "2026-08-25T00:00:00Z",
  "completedUtc": "2026-08-25T00:00:00Z",

  "deploymentTarget": {
    "modifiesExistingItems": [],
    "workspace": "<workspace>",
    "folder": "<folder>",
    "items": ["<item>"],
    "targetSuppliedByTicket": true,
    "identifiersInferred": false
  },

  "changedArtifacts": [
    { "path": "src/<item>", "type": "notebook", "change": "added" }
  ],

  "jobs": [
    {
      "name": "<pipeline>",
      "runId": "<run-id>",
      "submittedUtc": "2026-08-25T00:00:00Z",
      "completedUtc": "2026-08-25T00:00:00Z",
      "terminalStatus": "Succeeded",
      "durationSeconds": 0,
      "verifiedByReadBack": true
    }
  ],

  "reconciliation": {
    "sourceRowCount": 0,
    "goldRowCount": 0,
    "delta": 0,
    "tolerance": 0,
    "withinTolerance": true,
    "method": "<query or description>"
  },

  "smokeTests": [
    { "name": "<test>", "expected": "<value>", "actual": "<value>", "verdict": "pass", "durationMs": 0 }
  ],

  "reportValidation": {
    "validated": true,
    "findings": [ { "severity": "low", "message": "<finding>" } ]
  },

  "ontologyValidation": null,

  "errors": [
    {
      "whenUtc": "2026-08-25T00:00:00Z",
      "phase": "deployment",
      "message": "<error>",
      "recovered": true
    }
  ],

  "recoveryActions": [
    { "forError": 0, "action": "<what was done>", "residualRisk": "<risk>" }
  ],

  "humanInterventions": [
    { "whenUtc": "2026-08-25T00:00:00Z", "who": "human", "action": "<decision>", "reason": "<why>" }
  ],

  "unsupportedClaims": [
    { "claim": "<claim>", "whyUnsupported": "<reason>", "impactIfFalse": "<impact>" }
  ],

  "rollback": {
    "repository": ["<step>"],
    "fabric": ["<step>"],
    "irreversibleSteps": [],
    "dataLossRisk": "none"
  },

  "attestations": {
    "noCredentialsRecorded": true,
    "noFabricatedResults": true,
    "allMutationsVerifiedByReadBack": true,
    "noIdentifiersInferred": true,
    "agentDidNotMerge": true,
    "agentDidNotPushToProtectedBranch": true
  }
}
```

## Attestations

The `attestations` block is a set of explicit statements, each of which a
reviewer can independently falsify from the diff and the package. They exist so
that a violation is a **false statement** rather than an omission — an omission
is ambiguous, a false attestation is not.

Any attestation recorded as `false`, or found to be false, is a **BLOCKED**
finding.

## How the reviewer uses this

| Reviewer question | Evidence field |
|---|---|
| Was the stated scope delivered? | `changedArtifacts` vs the ticket |
| Did it go where the ticket said? | `deploymentTarget`, `identifiersInferred` |
| Did it actually work? | `jobs[].terminalStatus`, `verifiedByReadBack` |
| Are the numbers right? | `reconciliation`, `smokeTests` |
| What went wrong along the way? | `errors`, `recoveryActions` |
| What can't be trusted? | `unsupportedClaims` |
| Can this be undone? | `rollback`, `irreversibleSteps` |
| Were the rules followed? | `attestations` |

Verdict criteria are in [`review-standard.md`](review-standard.md).

## Open decision 1 — reconciliation is now producible

`reconciliation` and `smokeTests` can be produced. The mechanism, implemented by
Issue #2: the workload writes a machine-readable audit file to the lakehouse file
area, and the deployment script retrieves it over the **OneLake DFS endpoint**
with a different token audience than the one that wrote it. See
[`agent-toolbox.md`](agent-toolbox.md) §9.

`reconciliation` may be `null` **only** when the ticket explicitly requires no
data assertion, or when no data was moved at all. It must never be `null` on a
ticket that moved data; that is a missing-evidence finding, not an exemption.

A package reporting no runtime jobs must say so in `unsupportedClaims` rather
than leaving the absence to be inferred.

## Current phase

The target is the shared `<FABRIC_WORKSPACE>` workspace under a delegated user
identity with no service principal. Isolation is **organizational, not
enforced**, which is precisely why fields 17–20 are mandatory rather than
advisory.

Issue #2 is the first ticket to produce an evidence package against this
standard. It stopped at its deployment authorisation gate, so that package
records a planned-but-not-deployed state: `jobs` is empty, `reconciliation` is
`null`, and both facts are declared in `unsupportedClaims`.

That is the shape an honest blocked package takes. Expected values must never be
written into evidence as though they had been observed.
