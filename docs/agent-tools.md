# Agent-visible tools for GitHub Project workflows

This document describes the **tools as the agent sees them**.

These tools are intentionally narrow:

- they operate on the **current run's issue only**
- they operate on the **configured tracker project only**
- they are **executed by Symphony**, not by the worker directly
- the agent does **not** provide project owner, project number, item ids, field ids, or option ids
- the agent should **not hardcode project status/column names**

This keeps repo work on the worker, while keeping GitHub Project v2 mutations on Symphony.

---

## Tool: `github_project_get_status_options`

### Description
Get the available status/column names for the configured GitHub Project workflow.

Use this before choosing a target state. Do not assume that different projects use the same names.

### What the agent needs to know
- No input is required.
- The tool automatically uses the configured project.
- The returned names are the source of truth for valid move targets.

### Input
```json
{}
```

### Example tool call
```json
{
  "tool": "github_project_get_status_options",
  "arguments": {}
}
```

### Example result
```json
{
  "ok": true,
  "project": {
    "owner_type": "org",
    "owner": "skroutz-internal",
    "number": 47
  },
  "status_options": [
    "Todo",
    "In Progress",
    "Human Review",
    "Merging",
    "Rework",
    "Done",
    "Closed"
  ]
}
```

### When to use it
- before moving a card in a new workflow
- when valid target names are unclear
- whenever you would otherwise be guessing a status name

---

## Tool: `github_project_get_current_item`

### Description
Get the current GitHub Project item for the issue being handled in this run.

Use this when you want to know the current project status before deciding what to do next.

### What the agent needs to know
- No input is required.
- The tool automatically uses the current issue and the configured project.
- The agent should not try to pass issue ids, project ids, or repository names.

### Input
```json
{}
```

### Example tool call
```json
{
  "tool": "github_project_get_current_item",
  "arguments": {}
}
```

### Example result
```json
{
  "ok": true,
  "issue_id": "skroutz-internal/rehersal#2",
  "status": "In Progress",
  "project": {
    "owner_type": "org",
    "owner": "skroutz-internal",
    "number": 47
  }
}
```

### When to use it
- before moving a card
- when the current state is unclear
- when you want to confirm Symphony and the agent agree on the current board state

---

## Tool: `github_project_move_current_item`

### Description
Move the current run's GitHub Project item to a new status.

Optionally also add a comment to the current issue.

### What the agent needs to know
- The tool only works on the **current run's issue**.
- The tool only works on the **configured project**.
- The agent supplies only the **target state** and an optional **comment**.
- The target state must come from `github_project_get_status_options`.
- The comment is intended for a short human-facing note, for example: `"all done!"`

### Input
```json
{
  "state": "Human Review",
  "comment": "Implementation is complete and pushed on PR #3. Awaiting human review."
}
```

### Fields
- `state` — required string
  - the target project status/column name
  - must match one of the names returned by `github_project_get_status_options`
- `comment` — optional string
  - if provided, Symphony also posts this as a comment on the current issue

### Example tool call
```json
{
  "tool": "github_project_move_current_item",
  "arguments": {
    "state": "Human Review",
    "comment": "all done!"
  }
}
```

### Example result
```json
{
  "ok": true,
  "issue_id": "skroutz-internal/rehersal#2",
  "from": "In Progress",
  "to": "Human Review",
  "comment": {
    "attempted": true,
    "posted": true
  }
}
```

### When to use it
- when moving the current issue to a new status in the configured project
- after choosing a valid target state from `github_project_get_status_options`
- when optionally leaving a short issue comment along with the transition

### Notes for the agent
- Do not use this tool to move unrelated issues.
- Do not guess project ids, field ids, or status names.
- Do not use this tool to bypass workflow guardrails.
- If you include a comment, keep it short and relevant to the status change.

---

## Recommended usage pattern

### Discover valid status names first
```json
{
  "tool": "github_project_get_status_options",
  "arguments": {}
}
```

### Optionally check the current item state
```json
{
  "tool": "github_project_get_current_item",
  "arguments": {}
}
```

### Then move using one of the returned names
```json
{
  "tool": "github_project_move_current_item",
  "arguments": {
    "state": "Human Review",
    "comment": "Implementation is complete and pushed on PR #3. Awaiting human review."
  }
}
```

---

## Summary

The agent-facing surface should stay small:

- `github_project_get_status_options`
- `github_project_get_current_item`
- `github_project_move_current_item`

That is enough for the first version of project status automation while keeping control-plane permissions in Symphony.
