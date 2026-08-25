# Repository structure

Purpose of every top-level path in this control plane.

---

## `.github/`

GitHub-native governance: the Fabric development Issue template
(`ISSUE_TEMPLATE/fabric-development.yml`) and the pull-request template
(`pull_request_template.md`).

The Issue template asks for an **outcome** and its acceptance criteria, and
deliberately does not ask the author to prescribe an implementation. It requires
an explicit Fabric target whenever deployment is permitted, because an agent
must stop rather than infer one.

The pull-request template carries the developer self-assessment, the reviewer
verdict and the human merge checklist in one artefact.

## `config/`

Environment target definitions and agent configuration.

Holds workflow conventions, dispatcher settings and the agent context packages.

`environment.json` is a **tracked placeholder template**. Real identifiers live
in `environment.local.json`, which is gitignored and never committed. Scripts
read the local file and fail loudly if it is absent — they never fall back to
placeholders, because a placeholder that silently "works" is how a wrong target
gets written to.

The authorised deployment target is supplied **per ticket**, never standing.

**Never contains:** connection strings, secrets, tokens or credentials.
Configuration names *what* to act on; authentication is resolved at runtime
from OS-level credential storage.

## `docs/`

Standards, architecture notes and verification records.

The written rules that the Reviewer Agent checks work against, plus the
durable record of the environment's constraints and residual risk — including
`environment-and-constraints.md` and this file.

## `scripts/`

Deterministic, re-runnable Fabric operations.

Any Fabric operation performed more than once belongs here as a parameterised
script rather than being re-improvised each session. Scripts are idempotent
where the API allows, fail loudly rather than partially, and verify runtime
state after mutating it.

The purpose is repeatability: the same script, the same inputs, the same
outcome — reviewable as source rather than reconstructed from a transcript.

## `tests/`

Automated checks and runtime verification.

Tests assert against **actual runtime state in Fabric**, not against the API
responses that accepted a change. A test that only confirms a `202` was
returned proves that a request was accepted, not that anything works.

## `reviews/`

Reviewer Agent findings and approval records.

One record per review: the verdict (approve / request changes / block), what
was checked, and what evidence supported the conclusion. This is the audit
trail showing that no change reached `main` unexamined.

Written by the Reviewer Agent. Never modified by the Developer Agent.

## `worktrees/`

Ephemeral per-agent workspaces.

Each agent works in its own Git worktree so that the Developer Agent and the
Reviewer Agent never share a filesystem or a context. Isolation here is what
makes the review independent.

**Contents are untracked** — `.gitignore` excludes `worktrees/*` while keeping
`worktrees/.gitkeep`, so the directory survives a clone but no agent's scratch
state is ever committed.

---|---|
| a new GitHub Issue | Defined but not started. Newly discovered out-of-scope work lands here rather than expanding an active ticket. |
| the `agent-in-progress` label | Assigned to a Developer Agent and actively being implemented. |
| the `blocked` label | Halted — ambiguous target, safety-rule conflict, missing authorisation, or a reviewer block. Requires human input to move. |
| the `ready-for-review` label | Implemented and evidenced, awaiting the Reviewer Agent's independent verdict. |
| a closed Issue | Approved, human-merged and closed. |

Flow: `backlog` → `in-progress` → `review` → `done`, with `blocked` reachable
from any active state and `review` able to return work to `in-progress`.

---

## Root files

| File | Purpose |
|---|---|
| `README.md` | What this repository is, its isolation guarantees and operating model. |
| `CLAUDE.md` | Standing safety rules binding every agent session. |
| `docs/environment-and-constraints.md` | **Verified** Fabric environment, limitations, compensating controls, residual risk, maturity ladder and open design decisions. Read this before any Fabric work. |
| `docs/security-model.md` | How secrets, authentication, deployment boundaries and review separation are enforced — and what cannot be enforced in this phase. |
| `docs/agentic-workflow.md` | GitHub-Issue-driven state model, allowed and invalid label transitions. |
| `docs/agent-toolbox.md` | Contract for the deterministic Fabric commands the developer agent will use (specified, not yet implemented). |
| `docs/review-evidence-standard.md` | Required contents and JSON structure of a developer-agent evidence package. |
| `reviews/evidence.schema.json` | JSON Schema for `reviews/<ticket>/evidence.json`. |
| `config/dispatcher.json` | Dispatcher configuration: repository, polling, labels, invalid label combinations, permissions. |
| `config/developer-context.json` | What the developer agent is given before it starts. |
| `config/reviewer-context.json` | What the reviewer agent is given — and, importantly, what it is denied. |
| `AGENTS.md` | Developer and Reviewer Agent role definitions and hard limits. |
| `src/` | Fabric item definitions produced by tickets. Empty until a ticket creates one. |
| `config/environment.json` | Tracked placeholder template. Real values live in the gitignored `config/environment.local.json`. |
| `.gitignore` | Secret, state and artefact exclusions, plus explicit protection for tracked Fabric source. |

---

## What is deliberately tracked

Fabric source artefacts are **first-class version-controlled source**, not
build output. The `.gitignore` carries explicit negations so that broad
patterns (`*.key`, `*.token`, archive rules) never swallow them:

- Notebooks — `*.Notebook/`, `notebook-content.py`, `*.ipynb`
- Pipelines — `*.DataPipeline/`, `pipeline-content.json`
- Semantic models — `*.SemanticModel/`, `*.tmdl`, `model.bim`
- Reports — `*.Report/`, PBIP / PBIR definitions
- Ontology definitions — `*.Ontology/`
- Data Agent configuration — `*.DataAgent/`
- Platform metadata — `.platform`
- Documentation, tests, deployment scripts and configuration

## What is never tracked

Credentials, tokens, client secrets, API keys, passwords, private keys and
certificates; cloud CLI authentication state; GitHub CLI and Claude Code local
state; Python and Node dependencies; runtime output, logs and raw API
responses; diagnostic archives and dumps; temporary and machine-specific
files; worktree contents; Power BI Desktop scratch, caches and per-machine
settings; IDE and operating-system files.
