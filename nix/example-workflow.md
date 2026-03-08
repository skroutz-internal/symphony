---
# Example Symphony workflow — adapt this file for your own project.
# This example targets the `cowsay` CLI toy as a stand-in for a real repo.
tracker:
  kind: linear
  project_slug: "your-project-slug-here"
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
    - Cancelled
polling:
  interval_ms: 10000
workspace:
  root: /var/lib/symphony/workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/piuccio/cowsay .
    npm install
  before_remove: |
    echo "workspace removed"
agent:
  max_concurrent_agents: 2
  max_turns: 10
codex:
  command: codex
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

You are working on Linear ticket `{{ issue.identifier }}`: {{ issue.title }}

{% if attempt %}
This is retry attempt #{{ attempt }}. Resume from current workspace state.
{% endif %}

Issue: {{ issue.url }}
Status: {{ issue.state }}

{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

## Instructions

1. This is an unattended session. Do not ask a human for follow-up actions.
2. Only stop early for a true blocker (missing auth/secrets/permissions).
3. Final message must report completed actions and blockers only.

## Flow

- `Todo` → move to `In Progress`, implement, open PR, move to `Human Review`.
- `In Progress` → continue from workpad state.
- `Human Review` → wait for approval; do not modify code.
- `Merging` → merge the PR, move to `Done`.
- `Done` / `Cancelled` → do nothing and shut down.

## Guardrails

- Work only inside the provided workspace directory.
- Commit and push all changes before moving to `Human Review`.
- Do not expand scope; file separate issues for out-of-scope improvements.
