# Symphony Helm chart

## Current scope

This chart currently deploys:
- one Symphony server `Deployment`
- one `ConfigMap` with a rendered `WORKFLOW.md`
- one `Service`
- optional `Secret` resources for model and GitHub credentials

It does **not** yet deploy workers.

## Namespace

The chart is namespace-agnostic.

Example:

```bash
helm install symphony ./helm/symphony -n symphony --create-namespace
```

## Secret management modes

The chart supports two modes.

### 1) Reference existing Kubernetes Secrets

Example values:

```yaml
secrets:
  model:
    secretName: symphony-openai
    key: OPENAI_API_KEY
  githubApp:
    secretName: symphony-github-app
    appIdKey: GITHUB_APP_ID
    installationIdKey: GITHUB_INSTALLATION_ID
    privateKeyKey: GITHUB_APP_PRIVATE_KEY
```

### 2) Let Helm create the Secrets

This is convenient for local/prototype deployments when the secret material comes from files outside the repo.

Example private values file kept outside git:

```yaml
secrets:
  model:
    create: true
    value: [REDACTED]
  githubApp:
    create: true
    appId: "1234567"
    installationId: "120103174"
```

Then pass the private key from a local file with `--set-file`:

```bash
helm upgrade --install symphony ./helm/symphony \
  -n symphony \
  -f ~/.config/symphony/helm/private-values.yaml \
  --set-file secrets.githubApp.privateKey=$HOME/.config/symphony/github-app/symphony-minions.pem
```

When `create: true` is set and `secretName` is empty, the chart creates default Secret names:
- model: `<fullname>-model`
- GitHub token: `<fullname>-github-token`
- GitHub app: `<fullname>-github-app`

## GitHub App wiring

When GitHub App credentials are configured, the chart exposes:
- `GITHUB_APP_ID`
- `GITHUB_INSTALLATION_ID`
- `GITHUB_APP_PRIVATE_KEY_PATH=/etc/symphony/github-app/app-private-key.pem`

The private key is mounted as a Secret volume file.

The rendered workflow sets:

```yaml
tracker:
  api_key: "!/opt/symphony/bin/github-installation-token"
```

So Symphony mints a short-lived installation token on demand from the mounted app credentials.

## Optional static GitHub token

A static `GITHUB_TOKEN` secret can still be used through `secrets.githubToken`.
That is no longer the default GitHub tracker path.

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
- the token is currently minted on demand via `!/opt/symphony/bin/github-installation-token`
- there is no retry-on-401 or token refresh flow yet once a previously minted token expires during a long-running process
- if Helm creates Secrets, the secret material becomes part of Helm-managed release state
- default storage mode is still `emptyDir`, so workspace state is not preserved unless persistence is explicitly enabled
