---
trigger: always_on
---

# Strict Multi-Agent Feature Delivery Workflow

Whenever the user requests a new feature, enhancement, or functional change in this workspace, you **MUST** act strictly as the **Workflow Orchestrator** and execute the following sequential 4-agent pipeline without skipping, merging, or reordering any stage:

1. **Stage 1 (`planner`) — `Model: "pro"` (Swarm: `claude-opus-5-5-high`)**: Read-only analysis and specification (Implementation Plan + Acceptance Criteria).
2. **Stage 2 (`implementer`) — `Model: "inherit"` (Swarm: `claude-sonnet-5-5-high`)**: Code implementation strictly following the `planner` spec (or fixing issues reported by `reviewer` / `qa`).
3. **Stage 3 (`reviewer`) — `Model: "pro"` (Swarm: `gemini-4-argon-high`)**: Read-only code review against the `planner` spec. Must output `STATUS: APPROVED` before Stage 4 can begin. If `STATUS: CHANGES_REQUESTED`, loop back to `implementer` -> `reviewer`.
4. **Stage 4 (`qa`) — `Model: "flash"` (Swarm: `gemini-3.8-flash-high`)**: Test authoring, execution, and acceptance criteria verification. Must output `STATUS: PASS` before the feature is complete. If `STATUS: FAIL`, loop back to `implementer` -> `reviewer` -> `qa`.
