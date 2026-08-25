# Agentic DevOps for Microsoft Fabric

A control plane for running a governed development lifecycle against Microsoft
Fabric with AI agents — where a GitHub Issue authorises the work, an agent
implements it in isolation, evidence is produced at runtime, an independent
reviewer checks it, and **only a human merges**.

> **This is a proof of concept.** It demonstrates a lifecycle pattern. It is not
> production tooling and makes no claim to be.

## The problem it addresses

Agents that write data-platform code are easy. Agents you can *trust* with a
data platform are not. The gap is governance: what authorised the change, what
proves it worked, who checked it, and who decided to ship it.

This repository is an attempt at that governance layer, built under real
constraints — no Azure DevOps, no native Fabric Git integration, no service
principal, no dedicated workspace.

## Lifecycle

```
GitHub Issue (ticket)
  → developer dispatcher claims it
    → feature branch + isolated worktree
      → developer agent implements, deploys, validates
        → evidence package + pull request
          → deterministic checks
            → context-isolated reviewer agent
              → APPROVED / CHANGES REQUESTED / BLOCKED
                → HUMAN merge decision
```

Ticket state lives on the Issue as **labels** — the external source of truth. Not
in a local file, not in an agent's memory. A label is visible to any human with
repository access, survives a dispatcher crash, and can be corrected from a
phone. Ambiguous label combinations are **refused, not resolved**.

Both dispatchers **default to dry-run**. Live mode requires an explicit
`-Mode Live`, so a careless invocation cannot write to GitHub or Fabric.

## What makes it different from "an agent with API access"

| Control | Why |
|---|---|
| Per-ticket target authorisation, resolved to a folder GUID and verified before writing | An agent must never infer where to deploy |
| Allowlist covering **data paths** as well as items | Items live in folders; Lakehouse tables do not. An item-only allowlist lets an inventory look clean while tables were overwritten |
| Pre/post folder inventory diff | Without Git sync-back, this is the only detector of a change made outside the repository |
| Definition snapshot before modification | A reversal plan for a modification without a prior snapshot is a wish |
| Terminal-status polling | HTTP 202 means accepted, not done. A timeout reports `Unknown`, never success |
| Independent evidence read-back | Evidence retrieved through a different API and token audience than the deployment call |
| Reversal plan written before deployment | Deletion never executed automatically; cleanup is human |
| One job at a time, pipeline concurrency 1 | Shared capacity — a parallel run can throttle other users |
| Iteration ceiling per ticket | An unbounded developer/reviewer loop is a cost and blast-radius risk |
| Human-only merge | The gap between *approved* and *merged* has no agent in it |

## Repository layout

| Path | Purpose |
|---|---|
| `.github/` | Issue and pull-request templates |
| `config/` | Workflow, dispatcher and agent-context configuration |
| `docs/` | Standards, architecture, environment constraints |
| `scripts/` | Deterministic dispatchers and Fabric operations |
| `tests/` | Automated checks of the control plane's own invariants |
| `reviews/` | Review records and evidence packages |
| `src/` | Fabric item definitions, once a ticket produces them |
| `worktrees/` | Ephemeral per-agent workspaces (contents untracked) |

## Configuration and identifiers

**This repository is public. It contains no real environment identifiers.**

`config/environment.json` is a tracked template of placeholders. Real values —
workspace, capacity, folder, GUIDs — live in `config/environment.local.json`,
which is gitignored and never committed.

Scripts read the local file and **fail loudly if it is missing**. They never fall
back to the placeholders, because a placeholder that silently "works" is how a
wrong target gets written to.

To use this yourself: copy `config/environment.json` to
`config/environment.local.json` and fill it in.

## Honest limitations

Stated plainly, because the interesting question about agentic development is
what it *doesn't* guarantee:

- **Isolation is organizational, not enforced.** Work is filed in a folder inside
  a shared workspace. A folder is not a security, Git, capacity or permission
  boundary.
- **No service principal.** Agents run under a delegated user identity and
  inherit its permissions. **Every Fabric restriction here is therefore an
  instruction, not a permission.** An agent that ignores a rule is not stopped by
  anything at the identity layer.
- **No native Fabric Git integration** in the target tenant. Deployment goes
  through the REST API from committed definitions, and there is **no sync-back** —
  anything existing only in Fabric is invisible to review, which is why the
  inventory diff exists.
- **Review is context-isolated, not cross-vendor.** The reviewer runs as a
  separate process with a clean context and no developer scratchpad, but on the
  same model provider. Correlated blind spots are not excluded.
- **Not unattended.** Dispatchers are invoked deliberately.

See [`docs/environment-and-constraints.md`](docs/environment-and-constraints.md)
for the full limitation register, compensating controls, residual risk and the
maturity path out.

## Key documents

| File | Contents |
|---|---|
| [`CLAUDE.md`](CLAUDE.md) | Standing safety rules binding every agent session |
| [`AGENTS.md`](AGENTS.md) | Developer and reviewer roles, and their hard limits |
| [`docs/environment-and-constraints.md`](docs/environment-and-constraints.md) | Environment, limitations, residual risk, maturity levels |
| [`docs/agentic-workflow.md`](docs/agentic-workflow.md) | Label state model, valid and invalid transitions |
| [`docs/security-model.md`](docs/security-model.md) | What is enforced, and what cannot be |
| [`docs/review-standard.md`](docs/review-standard.md) | Verdict criteria and severity definitions |
| [`docs/review-evidence-standard.md`](docs/review-evidence-standard.md) | What an evidence package must contain |
| [`docs/agent-toolbox.md`](docs/agent-toolbox.md) | Contract for deterministic Fabric commands |

## Requirements

- Git and the GitHub CLI, authenticated
- Azure CLI, signed in with access to a Fabric workspace
- Windows PowerShell 5.1 or later
- A Fabric capacity you are permitted to create items in
