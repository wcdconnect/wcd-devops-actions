# WCD Dependency Graph action

Composite action that generates a Graphviz **DOT** + **SVG** graph of `wcd-*` NuGet dependencies for a `.csproj`.

**Repeatable output path (default):** `docs/app/dependency-graph.dot` + `docs/app/dependency-graph.svg`

**Soft-fail:** Graphviz missing, missing assets, script errors, or git push issues emit a GitHub **warning** and **do not fail** the job.

**Commit back (default):** `commit_if_changed: true` commits and pushes changed graph files with `[skip ci]` so the README image resolves on GitHub.

**No GH Actions artifacts by default:** `upload_artifact` defaults to `false` (avoids accumulating storage cost). Prefer commit-back.

Hub docs: [wcd-devops-github-actions.md — wcd-dependency-graph](https://github.com/wcdconnect/wcd-devops/blob/main/wcd-devops-github-actions.md#wcd-dependency-graph)

## Prerequisites

| Requirement | Details |
|-------------|---------|
| Checkout | Consuming repo checked out with a token that can push (`contents: write`) |
| Restore | `dotnet restore` already run — needs `obj/project.assets.json` |
| **Graphviz** | `dot` on **PATH** for SVG ([download](https://graphviz.org/download/)) |

## Usage (public — preferred)

```yaml
- name: Generate wcd-* dependency graph
  uses: wcdconnect/wcd-devops-actions/wcd-dependency-graph@main
  with:
    project: src/my-app/my-app.csproj
    ignore: wcd-library-targets   # optional
    # commit_if_changed defaults to true
    # upload_artifact defaults to false
```

Source of truth: `wcd-devops` (`.github/actions/wcd-actions/wcd-dependency-graph/`). Published to public [`wcd-devops-actions`](https://github.com/wcdconnect/wcd-devops-actions) via sync (same pattern as `wcd-builds` → `wcd-builds-actions`).

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `project` | _(required)_ | Path to `.csproj` |
| `filename` | `docs/app/dependency-graph` | Output stem |
| `ignore` | | Colon-separated package IDs to omit |
| `commit_if_changed` | `true` | Commit/push `.dot`/`.svg` with `[skip ci]` |
| `upload_artifact` | `false` | Upload workflow artifact (avoid — use commit-back) |

## Local script

```powershell
.\scripts\create-dependency-graph.ps1 docs/app/dependency-graph `
  --Project src/my-app/my-app.csproj `
  --ignore wcd-library-targets
```
