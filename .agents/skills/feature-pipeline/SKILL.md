---
name: feature-pipeline
description: >-
  Executes the strict 4-stage multi-agent feature pipeline (Planner -> Implementer -> Reviewer -> QA)
  with stage-optimized models. Use this skill whenever the user requests a new feature, enhancement, or functional change.
---

# Feature Pipeline Runbook (`Planner` -> `Implementer` -> `Reviewer` -> `QA`)

Follow these exact steps and model assignments for every feature request:

## Stage Model Matrix

| Stage | Subagent Type | `invoke_subagent` `Model` | Swarm `model` (if running via Swarm) | Purpose |
| :--- | :--- | :--- | :--- | :--- |
| **Stage 1** | `planner` | `"pro"` | `"claude-opus-5-5-high"` | Deep architectural planning, edge-case identification, and testable spec design |
| **Stage 2** | `implementer` | `"inherit"` | `"claude-sonnet-5-5-high"` | High-accuracy code generation and multi-file edits following the approved plan |
| **Stage 3** | `reviewer` | `"pro"` | `"gemini-4-argon-high"` | Adversarial read-only code review, security audit, and spec compliance verification |
| **Stage 4** | `qa` | `"flash"` | `"gemini-3.8-flash-high"` | Fast, iterative test authoring, command execution, and acceptance criteria validation |

## Step 0: Ensure Subagents Are Registered
Verify that `planner`, `implementer`, `reviewer`, and `qa` are available as subagent types. If starting a fresh conversation where they are not yet registered in runtime tool definitions, call `define_subagent` using the definitions in:
- [.agents/agents/planner.md](../../agents/planner.md)
- [.agents/agents/implementer.md](../../agents/implementer.md)
- [.agents/agents/reviewer.md](../../agents/reviewer.md)
- [.agents/agents/qa.md](../../agents/qa.md)

## Step 1: Stage 1 — Planner (`planner`)
1. Invoke `planner` via `invoke_subagent`:
   - `TypeName`: `"planner"`
   - `Role`: `"Feature Planner"`
   - `Model`: `"pro"`
   - `Prompt`: Include the user's feature request and ask for the complete 5-part Implementation Specification.
2. Wait for `planner` to return the specification before starting Stage 2.

## Step 2: Stage 2 — Implementer (`implementer`)
1. Invoke `implementer` via `invoke_subagent` (or `send_message` if reusing the active implementer in a remediation loop):
   - `TypeName`: `"implementer"`
   - `Role`: `"Feature Implementer"`
   - `Model`: `"inherit"`
   - `Prompt`: Pass the complete `planner` specification (and any remediation items from `reviewer` or `qa` if in a fix cycle).
2. Wait for `implementer` to finish all file changes and return its handoff report.

## Step 3: Stage 3 — Reviewer (`reviewer`)
1. Invoke `reviewer` via `invoke_subagent` (or `send_message` on re-review):
   - `TypeName`: `"reviewer"`
   - `Role`: `"Code Reviewer"`
   - `Model`: `"pro"`
   - `Prompt`: Pass the `planner` specification and the `implementer` handoff report. Instruct `reviewer` to inspect the actual files on disk and return `STATUS: APPROVED` or `STATUS: CHANGES_REQUESTED`.
2. **Gate Check**:
   - If `STATUS: CHANGES_REQUESTED`: Send the blocking issues back to `implementer` (Step 2), then re-run `reviewer` (Step 3).
   - If `STATUS: APPROVED`: Proceed to Step 4 (`qa`).

## Step 4: Stage 4 — QA (`qa`)
1. Invoke `qa` via `invoke_subagent` (or `send_message` on re-test):
   - `TypeName`: `"qa"`
   - `Role`: `"QA Engineer"`
   - `Model`: `"flash"`
   - `Prompt`: Pass the `planner` Acceptance Criteria and the approved implementation summary. Instruct `qa` to write/run tests, verify all criteria, and return `STATUS: PASS` or `STATUS: FAIL`.
2. **Gate Check**:
   - If `STATUS: FAIL`: Send the defect report back to `implementer` (Step 2), re-verify with `reviewer` (Step 3), and re-run `qa` (Step 4).
   - If `STATUS: PASS`: Present the final summary (Plan, Implementation, Review Verdict, and QA Matrix) to the user.
