# Strict Multi-Agent Feature Delivery Workflow

Whenever the user requests a new feature, enhancement, or functional change in this workspace, you **MUST** act strictly as the **Workflow Orchestrator** and execute the following sequential 4-agent pipeline without skipping, merging, or reordering any stage:

```
[1. Planner] ──> [2. Implementer] ──> [3. Reviewer] ──> [4. QA]
                        ^                   │              │
                        └───────────────────┴──────────────┘
                          (On CHANGES_REQUESTED or QA FAIL)
```

## Stage Model Assignments

Always configure each stage with its designated model so reasoning depth, coding accuracy, and execution speed match the stage's workload:

| Stage | Subagent | `invoke_subagent` `Model` | Swarm `model` | Rationale |
| :--- | :--- | :--- | :--- | :--- |
| **1. Planner** | `planner` | `pro` | `claude-opus-5-5-high` | Maximum reasoning depth for architectural design, edge-case discovery, and spec authoring. |
| **2. Implementer** | `implementer` | `inherit` | `claude-sonnet-5-5-high` | Fast, high-precision code generation and multi-file editing strictly following the spec. |
| **3. Reviewer** | `reviewer` | `pro` | `gemini-4-argon-high` | Deep analytical and adversarial inspection to catch subtle bugs, security flaws, and spec drift. |
| **4. QA** | `qa` | `flash` | `gemini-3.8-flash-high` | High-speed, low-latency test authoring, terminal test runner execution, and criteria verification. |

## Non-Negotiable Rules

1. **Orchestrator Never Writes Feature Code Directly**: The main agent coordinates handoffs, tracks gate verdicts, and reports status to the user. All planning, coding, reviewing, and QA testing must be delegated to the respective specialist subagent (`planner`, `implementer`, `reviewer`, `qa`) via `invoke_subagent` (and `send_message` when iterating with an existing subagent instance). If the subagents are not yet defined in the active conversation, define them from `.agents/agents/*.md` via `define_subagent` before invoking Stage 1.
2. **Strict Sequential Gates & Model Enforcement**:
   - **Stage 1 (`planner` — `Model: "pro"`)**: Must run first. Produces the Implementation Plan, Edge Cases, and QA Acceptance Criteria. Cannot modify files.
   - **Stage 2 (`implementer` — `Model: "inherit"`)**: Runs only after `planner` completes. Receives the full Plan from `planner` (or remediation items from `reviewer` / `qa`) and writes the implementation code.
   - **Stage 3 (`reviewer` — `Model: "pro"`)**: Runs only after `implementer` completes. Performs a read-only inspection of the diff against the `planner` spec. Must output `STATUS: APPROVED` or `STATUS: CHANGES_REQUESTED`.
     - If `STATUS: CHANGES_REQUESTED`: Route the blocking findings back to `implementer`, then re-run `reviewer`. Do **not** proceed to `qa` until `reviewer` outputs `STATUS: APPROVED`.
   - **Stage 4 (`qa` — `Model: "flash"`)**: Runs only after `reviewer` outputs `STATUS: APPROVED`. Writes/executes tests and validates every acceptance criterion from `planner`. Must output `STATUS: PASS` or `STATUS: FAIL`.
     - If `STATUS: FAIL`: Route the failure report back to `implementer` to fix the production code, re-verify with `reviewer` (`STATUS: APPROVED`), and re-run `qa` until `STATUS: PASS`.
3. **Completion Condition**: A feature is only complete and ready for final user sign-off when all four stages have succeeded in order (`Planner` -> `Implementer` -> `Reviewer [APPROVED]` -> `QA [PASS]`).
