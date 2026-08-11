# WCD DevOps Actions

Lightweight composite actions for org-wide WCD CI/CD (dependency graphs, shared tooling).

**This repository is auto-generated.** The source of truth lives in [wcd-devops](https://github.com/wcdconnect/wcd-devops) at [`.github/actions/wcd-actions/`](https://github.com/wcdconnect/wcd-devops/tree/main/.github/actions/wcd-actions). Changes are synced here automatically whenever those source files change on `main`.

Do not edit files in this repository directly. Submit changes to **wcd-devops** instead.

> Not to be confused with [`wcd-builds-actions`](https://github.com/wcdconnect/wcd-builds-actions), which is only for [WCD Builds](https://github.com/wcdconnect/wcd-builds) tracking/reporting.

## Actions

| Action | Purpose |
|--------|---------|
| **[wcd-dependency-graph](wcd-dependency-graph/)** | Generate `wcd-*` NuGet DOT + SVG dependency graphs; commit `docs/app/dependency-graph.*` by default (no GH Actions artifact upload) |

## Usage

```yaml
steps:
  - uses: actions/checkout@v4
    with:
      token: ${{ secrets.GITHUB_TOKEN }}   # needs contents: write to commit graphs

  - run: dotnet restore My.sln

  - uses: wcdconnect/wcd-devops-actions/wcd-dependency-graph@main
    with:
      project: src/my-app/my-app.csproj
      ignore: wcd-library-targets
```

Defaults: `commit_if_changed: true`, `upload_artifact: false`.

Full documentation: [wcd-devops-github-actions.md](https://github.com/wcdconnect/wcd-devops/blob/main/wcd-devops-github-actions.md#wcd-dependency-graph).
