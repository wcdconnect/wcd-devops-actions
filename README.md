# WCD DevOps Actions

Public mirror for composite actions synced from [wcd-devops](https://github.com/wcdconnect/wcd-devops) (`.github/actions/wcd-actions/`).

Do not edit files in this repository directly. Submit changes to **wcd-devops** instead.

> Not to be confused with [`wcd-builds-actions`](https://github.com/wcdconnect/wcd-builds-actions), which is only for [WCD Builds](https://github.com/wcdconnect/wcd-builds) tracking/reporting.

## Actions

There are no composite actions published at the moment.

## Dependency graphs (local only)

NuGet dependency graphs are **not** generated in CI. Regenerate and commit `docs/app/dependency-graph.dot` / `.svg` locally when the graph changes:

```powershell
# From wcd-devops (or copy scripts/create-dependency-graph.ps1)
.\scripts\create-dependency-graph.ps1 docs/app/dependency-graph `
  --Project src/my-app/my-app.csproj `
  --ignore wcd-library-targets
```

Embed in README:

```markdown
![wcd-* NuGet dependency graph](docs/app/dependency-graph.svg)
```

Full documentation: [wcd-devops-github-actions.md — Dependency graphs](https://github.com/wcdconnect/wcd-devops/blob/main/wcd-devops-github-actions.md#dependency-graphs-local).
