# Symphony Helm chart

## Current scope

This chart currently deploys:
- one Symphony server `Deployment`
- one `ConfigMap` with a rendered `WORKFLOW.md`
- one `Service`

It does **not** yet deploy workers.

## Namespace

The chart is namespace-agnostic.

Example:

```bash
helm install symphony ./helm/symphony -n symphony --create-namespace
```

## Required secrets

For the current GitHub-backed workflow, Symphony should receive a GitHub token from an existing Kubernetes Secret.

Example values:

```yaml
secrets:
  githubToken:
    secretName: symphony-github
    key: GITHUB_TOKEN
  model:
    secretName: symphony-openai
    key: OPENAI_API_KEY
```

Example Secret manifests:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: symphony-github
stringData:
  GITHUB_TOKEN: <token>
---
apiVersion: v1
kind: Secret
metadata:
  name: symphony-openai
stringData:
  OPENAI_API_KEY: <token>
```

## Optional GitHub App secret

The chart can also mount GitHub App credentials for later app-based token brokering.

Example values:

```yaml
secrets:
  githubApp:
    secretName: symphony-github-app
    appIdKey: GITHUB_APP_ID
    installationIdKey: GITHUB_INSTALLATION_ID
    privateKeyKey: GITHUB_APP_PRIVATE_KEY
```

Expected Secret shape:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: symphony-github-app
stringData:
  GITHUB_APP_ID: "1234567"
  GITHUB_INSTALLATION_ID: "120103174"
  GITHUB_APP_PRIVATE_KEY: |
    -----BEGIN PRIVATE KEY-----
    ...
    -----END PRIVATE KEY-----
```

When configured, the chart exposes:
- `GITHUB_APP_ID`
- `GITHUB_INSTALLATION_ID`
- `GITHUB_APP_PRIVATE_KEY_PATH=/etc/symphony/github-app/app-private-key.pem`

## Storage

By default, the chart uses `emptyDir` for `/var/lib/symphony/workspaces`.

To enable persistence:

```yaml
persistence:
  enabled: true
  size: 10Gi
  storageClassName: ""
```

To use an existing PVC:

```yaml
persistence:
  enabled: true
  existingClaim: symphony-workspaces
```

## Image publishing

Images are published to GHCR by GitHub Actions and pulled in Kubernetes through Harbor's GHCR proxy.

Publish target:
- `ghcr.io/skroutz-internal/symphony:latest`

Helm pull target:
- `harbor.skroutz.gr/ghcr/skroutz-internal/symphony:latest`

The current workflow publishes only `latest` from `main` while we are prototyping.

## Logs and terminal dashboard

By default, the chart disables Symphony's terminal dashboard in the rendered workflow:

```yaml
observability:
  dashboard_enabled: false
```

The application now keeps Elixir's default console logger enabled, so `kubectl logs` shows application logs directly without a file-tail wrapper.

Symphony also keeps its rotating log file inside the pod at:
- `/var/lib/symphony/log/symphony.log.1`

## Current limitations

Current chart scope and limitations:

- server-only deployment; no worker StatefulSet yet
- no worker headless Service yet
- no SSH worker wiring yet
- no delegated per-run worker repo tokens yet
- GitHub Project v2 control remains a Symphony concern, not a worker concern
- the runtime still assumes `tracker.api_key` comes from `GITHUB_TOKEN` in the workflow/env
- GitHub App token brokering is planned but not wired into Symphony runtime yet
- default storage mode is still `emptyDir`, so workspace state is not preserved unless persistence is explicitly enabled
