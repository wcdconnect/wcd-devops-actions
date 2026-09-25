<#
.SYNOPSIS
  Generate a Graphviz DOT (+ SVG) dependency graph for wcd-* NuGet packages.

.DESCRIPTION
  Reads project.assets.json (after restore) and the project's PackageReference
  list to emit a DOT graph of packages matching -PackagePrefix (default: wcd-).
  Optionally renders SVG via `dot` (Graphviz must be on PATH).

.PARAMETER Filename
  Output path stem or .dot path. Writes <stem>.dot and <stem>.svg next to it.

.PARAMETER Ignore
  Colon-separated package IDs to omit from nodes and edges.
  Example: wcd-library-targets  or  wcd-library-targets:wcd-installer

.PARAMETER Project
  Path to the .csproj to analyze. Required unless -AssetsPath is supplied and
  direct PackageReferences are not needed (direct refs still need -Project).

.PARAMETER AssetsPath
  Optional explicit path to project.assets.json. Default: <projectDir>/obj/project.assets.json

.PARAMETER PackagePrefix
  Only include package IDs starting with this prefix (case-insensitive). Default: wcd-

.PARAMETER DotExecutable
  Graphviz executable name or full path. Default: dot (must be on PATH).

.PARAMETER SkipSvg
  If set, write .dot only (do not invoke Graphviz).

.EXAMPLE
  .\create-dependency-graph.ps1 docs/app/dependency-graph `
    --Project src/my-app/my-app.csproj `
    --ignore wcd-library-targets

.NOTES
  Exit codes:
    0  success
    1  usage / validation error
    2  assets / project parse error
    3  Graphviz (dot) missing or failed
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $Filename,

    [Parameter(Mandatory = $false)]
    [string] $Ignore = '',

    [Parameter(Mandatory = $false)]
    [string] $Project = '',

    [Parameter(Mandatory = $false)]
    [string] $AssetsPath = '',

    [Parameter(Mandatory = $false)]
    [string] $PackagePrefix = 'wcd-',

    [Parameter(Mandatory = $false)]
    [string] $DotExecutable = 'dot',

    [Parameter(Mandatory = $false)]
    [switch] $SkipSvg,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $RemainingArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info {
    param([string] $Message)
    Write-Host "[dependency-graph] $Message" -ForegroundColor Cyan
}

function Write-Err {
    param([string] $Message)
    Write-Host "[dependency-graph] ERROR: $Message" -ForegroundColor Red
}

function Resolve-CliOverrides {
    param(
        [string[]] $Args,
        [string] $IgnoreIn,
        [string] $ProjectIn
    )
    $ignoreOut = $IgnoreIn
    $projectOut = $ProjectIn
    if (-not $Args) {
        return @{ Ignore = $ignoreOut; Project = $projectOut }
    }
    for ($i = 0; $i -lt $Args.Count; $i++) {
        $token = $Args[$i]
        if ($token -eq '--ignore' -or $token -eq '-Ignore') {
            if ($i + 1 -ge $Args.Count) {
                throw "Missing value after $token. Expected colon-separated package IDs (e.g. wcd-library-targets:wcd-installer)."
            }
            $ignoreOut = $Args[$i + 1]
            $i++
            continue
        }
        if ($token -like '--ignore=*') {
            $ignoreOut = $token.Substring('--ignore='.Length)
            continue
        }
        if ($token -eq '--Project' -or $token -eq '-Project' -or $token -eq '--project') {
            if ($i + 1 -ge $Args.Count) {
                throw "Missing value after $token. Expected path to a .csproj."
            }
            $projectOut = $Args[$i + 1]
            $i++
            continue
        }
        if ($token -like '--Project=*' -or $token -like '--project=*') {
            $projectOut = $token.Substring($token.IndexOf('=') + 1)
            continue
        }
        if ($token -eq '--SkipSvg' -or $token -eq '-SkipSvg') {
            $script:SkipSvg = $true
            continue
        }
        throw "Unknown argument: $token. Supported: --ignore <id:id>, --Project <csproj>, --SkipSvg"
    }
    return @{ Ignore = $ignoreOut; Project = $projectOut }
}

function Get-IgnoreSet {
    param([string] $IgnoreCsv)
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if (-not [string]::IsNullOrWhiteSpace($IgnoreCsv)) {
        foreach ($part in ($IgnoreCsv -split '[:;,]')) {
            $id = $part.Trim()
            if ($id) { [void]$set.Add($id) }
        }
    }
    # Prevent PowerShell from unwrapping a single-element HashSet to a string
    Write-Output -NoEnumerate $set
}

function Get-OutputPaths {
    param([string] $Filename)
    $path = $Filename.Trim()
    if ($path.EndsWith('.svg', [StringComparison]::OrdinalIgnoreCase)) {
        $path = $path.Substring(0, $path.Length - 4) + '.dot'
    }
    if (-not $path.EndsWith('.dot', [StringComparison]::OrdinalIgnoreCase)) {
        $path = $path + '.dot'
    }
    $fullDot = [System.IO.Path]::GetFullPath($path)
    $fullSvg = [System.IO.Path]::ChangeExtension($fullDot, '.svg')
    return @{ Dot = $fullDot; Svg = $fullSvg; Stem = [System.IO.Path]::GetFileNameWithoutExtension($fullDot) }
}

function Get-DirectPackageIds {
    param([string] $CsprojPath, [string] $Prefix)
    if (-not (Test-Path -LiteralPath $CsprojPath)) {
        throw "Project not found: $CsprojPath"
    }
    [xml] $xml = Get-Content -LiteralPath $CsprojPath -Raw
    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    # SDK-style projects usually have no default xmlns on PackageReference
    $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($node in $xml.SelectNodes('//PackageReference')) {
        $include = $node.GetAttribute('Include')
        if ([string]::IsNullOrWhiteSpace($include)) {
            $include = $node.GetAttribute('Update')
        }
        if ($include -and $include.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) {
            [void]$ids.Add($include)
        }
    }
    # Prevent PowerShell from unwrapping a single-element HashSet to a string
    Write-Output -NoEnumerate $ids
}

function Select-AssetsTarget {
    param($TargetsObject)
    $names = @($TargetsObject.PSObject.Properties | ForEach-Object { $_.Name })
    if ($names.Count -eq 0) {
        throw "project.assets.json has no targets. Restore may have failed."
    }
    # Prefer RID-specific target when present (e.g. net472/win)
    $withRid = @($names | Where-Object { $_ -match '/' })
    if ($withRid.Count -gt 0) {
        return $withRid[0]
    }
    return $names[0]
}

function Split-PackageKey {
    param([string] $Key)
    # "wcd-library/1.0.170"
    $idx = $Key.LastIndexOf('/')
    if ($idx -lt 1) {
        return @{ Id = $Key; Version = '' }
    }
    return @{
        Id      = $Key.Substring(0, $idx)
        Version = $Key.Substring($idx + 1)
    }
}

function Escape-DotLabel {
    param([string] $Text)
    # Node IDs are quoted; escape backslash and quote
    return ($Text -replace '\\', '\\' -replace '"', '\"')
}

try {
    $cli = Resolve-CliOverrides -Args $RemainingArguments -IgnoreIn $Ignore -ProjectIn $Project
    $Ignore = $cli.Ignore
    $Project = $cli.Project

    Write-Info "Starting dependency graph generation"
    Write-Info "Filename : $Filename"
    Write-Info "Project  : $(if ($Project) { $Project } else { '(not set)' })"
    Write-Info "Ignore   : $(if ($Ignore) { $Ignore } else { '(none)' })"
    Write-Info "Prefix   : $PackagePrefix"
    Write-Info "SkipSvg  : $SkipSvg"

    if ([string]::IsNullOrWhiteSpace($Project) -and [string]::IsNullOrWhiteSpace($AssetsPath)) {
        Write-Err "Either -Project <csproj> or -AssetsPath <project.assets.json> is required."
        Write-Host @"

Usage:
  .\create-dependency-graph.ps1 <filename> --Project <path.csproj> [--ignore pkg1:pkg2]

Examples:
  .\create-dependency-graph.ps1 docs/app/dependency-graph ``
    --Project src/my-app/my-app.csproj ``
    --ignore wcd-library-targets

Remediation:
  - Pass --Project with a relative or absolute path to the consuming .csproj
  - Run 'dotnet restore' on that project first so obj/project.assets.json exists
"@
        exit 1
    }

    $outputs = Get-OutputPaths -Filename $Filename
    $ignoreSet = Get-IgnoreSet -IgnoreCsv $Ignore
    $outDir = [System.IO.Path]::GetDirectoryName($outputs.Dot)
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        Write-Info "Created output directory: $outDir"
    }

    $projectFull = $null
    if ($Project) {
        $projectFull = [System.IO.Path]::GetFullPath($Project)
        if (-not (Test-Path -LiteralPath $projectFull)) {
            Write-Err "Project file not found: $projectFull"
            Write-Host "Remediation: check --Project path relative to the repo root / working directory ($(Get-Location))."
            exit 1
        }
    }

    if ([string]::IsNullOrWhiteSpace($AssetsPath)) {
        $AssetsPath = Join-Path ([System.IO.Path]::GetDirectoryName($projectFull)) 'obj\project.assets.json'
    }
    else {
        $AssetsPath = [System.IO.Path]::GetFullPath($AssetsPath)
    }

    if (-not (Test-Path -LiteralPath $AssetsPath)) {
        Write-Err "project.assets.json not found: $AssetsPath"
        Write-Host @"
Remediation:
  1. Run:  dotnet restore `"$projectFull`"
  2. Confirm obj/project.assets.json exists under the project directory
  3. Re-run this script
"@
        exit 2
    }

    Write-Info "Assets   : $AssetsPath"

    $assetsJson = Get-Content -LiteralPath $AssetsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $assetsJson.targets) {
        Write-Err "Invalid assets file (no 'targets' property): $AssetsPath"
        exit 2
    }

    $targetName = Select-AssetsTarget -TargetsObject $assetsJson.targets
    Write-Info "Target   : $targetName"
    $targetLibs = $assetsJson.targets.$targetName

    $directIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if ($projectFull) {
        $directIds = Get-DirectPackageIds -CsprojPath $projectFull -Prefix $PackagePrefix
        Write-Info "Direct $PackagePrefix* PackageReferences: $($directIds.Count)"
    }

    # Resolve package id -> resolved version, and collect edges
    $resolved = @{}  # id -> version
    $edges = New-Object System.Collections.Generic.List[object]

    foreach ($prop in $targetLibs.PSObject.Properties) {
        $parts = Split-PackageKey -Key $prop.Name
        $pkgId = $parts.Id
        $pkgVer = $parts.Version
        if (-not $pkgId.StartsWith($PackagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if ($ignoreSet.Contains($pkgId)) {
            continue
        }
        $resolved[$pkgId] = $pkgVer

        if ($prop.Value.dependencies) {
            foreach ($dep in $prop.Value.dependencies.PSObject.Properties) {
                $depId = $dep.Name
                if (-not $depId.StartsWith($PackagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }
                if ($ignoreSet.Contains($depId)) {
                    continue
                }
                $declared = [string] $dep.Value
                $edges.Add([pscustomobject]@{
                        From     = $pkgId
                        To       = $depId
                        Declared = $declared
                    }) | Out-Null
            }
        }
    }

    # Ensure direct refs appear even if somehow missing from target (shouldn't happen)
    foreach ($id in $directIds) {
        if ($ignoreSet.Contains($id)) { continue }
        if (-not $resolved.ContainsKey($id)) {
            Write-Host "[dependency-graph] WARNING: Direct PackageReference '$id' not found in assets target '$targetName'." -ForegroundColor Yellow
        }
    }

    if ($resolved.Count -eq 0) {
        Write-Err "No packages matching prefix '$PackagePrefix' found after applying ignore list."
        Write-Host @"
Remediation:
  - Confirm the project references $PackagePrefix* packages
  - Narrow --ignore (current: $(if ($Ignore) { $Ignore } else { '(none)' }))
  - Inspect: $AssetsPath
"@
        exit 2
    }

    $rootName = if ($projectFull) {
        [System.IO.Path]::GetFileNameWithoutExtension($projectFull)
    }
    else {
        'project'
    }

    $omitNote = if ($ignoreSet.Count -gt 0) {
        $ignoredList = ($ignoreSet | Sort-Object) -join ', '
        "`n(omitted: $ignoredList)"
    }
    else { '' }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("// Auto-generated by create-dependency-graph.ps1 — do not edit by hand.")
    [void]$sb.AppendLine("// Project: $Project")
    [void]$sb.AppendLine("// Target: $targetName")
    [void]$sb.AppendLine("// Prefix: $PackagePrefix*")
    if ($ignoreSet.Count -gt 0) {
        [void]$sb.AppendLine("// Ignored: $(($ignoreSet | Sort-Object) -join ', ')")
    }
    [void]$sb.AppendLine("// Solid edges from root = direct PackageReference; dashed = transitive nuspec deps.")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("digraph WcdDependencyGraph {")
    [void]$sb.AppendLine('  graph [')
    [void]$sb.AppendLine('    rankdir=TB')
    [void]$sb.AppendLine('    labelloc=t')
    $graphLabel = Escape-DotLabel "$rootName — $PackagePrefix* NuGet dependency graph$omitNote"
    [void]$sb.AppendLine("    label=`"$graphLabel`"")
    [void]$sb.AppendLine('    fontsize=14')
    [void]$sb.AppendLine('    fontname="Segoe UI"')
    [void]$sb.AppendLine('    nodesep=0.35')
    [void]$sb.AppendLine('    ranksep=0.6')
    [void]$sb.AppendLine('  ];')
    [void]$sb.AppendLine('  node [')
    [void]$sb.AppendLine('    shape=box')
    [void]$sb.AppendLine('    style="rounded,filled"')
    [void]$sb.AppendLine('    fontname="Consolas"')
    [void]$sb.AppendLine('    fontsize=10')
    [void]$sb.AppendLine('  ];')
    [void]$sb.AppendLine('  edge [')
    [void]$sb.AppendLine('    fontname="Consolas"')
    [void]$sb.AppendLine('    fontsize=8')
    [void]$sb.AppendLine('  ];')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("  `"$(Escape-DotLabel $rootName)`" [")
    [void]$sb.AppendLine('    fillcolor="#1a365d"')
    [void]$sb.AppendLine('    fontcolor=white')
    [void]$sb.AppendLine('    style="rounded,filled,bold"')
    [void]$sb.AppendLine('  ];')
    [void]$sb.AppendLine('')

    $nodeLabel = @{}
    foreach ($id in ($resolved.Keys | Sort-Object)) {
        $nodeLabel[$id] = $id
        $isDirect = $directIds.Contains($id)
        $fill = if ($isDirect) { '#c6f6d5' } else { '#e2e8f0' }
        [void]$sb.AppendLine("  `"$(Escape-DotLabel $id)`" [fillcolor=`"$fill`"];")
    }

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('  // Direct PackageReference edges')
    foreach ($id in ($directIds | Sort-Object)) {
        if ($ignoreSet.Contains($id)) { continue }
        if (-not $nodeLabel.ContainsKey($id)) { continue }
        [void]$sb.AppendLine("  `"$(Escape-DotLabel $rootName)`" -> `"$(Escape-DotLabel $nodeLabel[$id])`" [color=`"#276749`" penwidth=1.5];")
    }

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('  // Transitive package dependencies')
    foreach ($e in ($edges | Sort-Object From, To)) {
        if (-not $nodeLabel.ContainsKey($e.From)) { continue }
        if (-not $nodeLabel.ContainsKey($e.To)) { continue }
        [void]$sb.AppendLine("  `"$(Escape-DotLabel $nodeLabel[$e.From])`" -> `"$(Escape-DotLabel $nodeLabel[$e.To])`" [style=dashed color=`"#4a5568`"];")
    }

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('  subgraph cluster_legend {')
    [void]$sb.AppendLine('    label="Legend";')
    [void]$sb.AppendLine('    fontsize=10;')
    [void]$sb.AppendLine('    style=dashed;')
    [void]$sb.AppendLine('    color="#a0aec0";')
    [void]$sb.AppendLine('    node [width=0.3 height=0.3];')
    [void]$sb.AppendLine('    legend_direct [label="direct PackageReference" fillcolor="#c6f6d5"];')
    [void]$sb.AppendLine('    legend_trans  [label="transitive only" fillcolor="#e2e8f0"];')
    [void]$sb.AppendLine("    legend_root   [label=`"$(Escape-DotLabel $rootName)`" fillcolor=`"#1a365d`" fontcolor=white];")
    [void]$sb.AppendLine('  }')
    [void]$sb.AppendLine('}')

    $dotText = $sb.ToString()
    [System.IO.File]::WriteAllText($outputs.Dot, $dotText, [System.Text.UTF8Encoding]::new($false))
    Write-Info "Wrote DOT : $($outputs.Dot)"

    $directCount = @($directIds | Where-Object { -not $ignoreSet.Contains($_) -and $resolved.ContainsKey($_) }).Count
    $transCount = $resolved.Count - $directCount
    Write-Info "Packages : $($resolved.Count) total ($directCount direct, $transCount transitive-only)"
    Write-Info "Edges    : $($edges.Count) package→package"

    if (-not $SkipSvg) {
        $dotCmd = Get-Command $DotExecutable -ErrorAction SilentlyContinue
        if (-not $dotCmd) {
            Write-Err "Graphviz executable not found: '$DotExecutable'"
            Write-Host @"
Remediation:
  - Graphviz should be installed and 'dot' on PATH on all WCD runners
  - Locally: install Graphviz and reopen the shell, or pass -DotExecutable with a full path
  - DOT file was still written: $($outputs.Dot)
"@
            exit 3
        }
        Write-Info "Rendering SVG with: $($dotCmd.Source)"
        $dotArgs = @('-Tsvg', $outputs.Dot, '-o', $outputs.Svg)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $dotCmd.Source
        $psi.Arguments = ($dotArgs | ForEach-Object {
                if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ }
            }) -join ' '
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) {
            Write-Err "dot failed with exit code $($proc.ExitCode)"
            if ($stdout) { Write-Host "dot stdout:`n$stdout" }
            if ($stderr) { Write-Host "dot stderr:`n$stderr" }
            Write-Host "Remediation: open $($outputs.Dot) and validate Graphviz syntax; re-run with -SkipSvg to inspect DOT only."
            exit 3
        }
        if (-not (Test-Path -LiteralPath $outputs.Svg)) {
            Write-Err "dot exited 0 but SVG missing: $($outputs.Svg)"
            exit 3
        }
        Write-Info "Wrote SVG : $($outputs.Svg)"
    }
    else {
        Write-Info "SkipSvg set — SVG not generated"
    }

    # Machine-readable lines for CI action parsing
    Write-Host "DOT_PATH=$($outputs.Dot)"
    Write-Host "SVG_PATH=$(if (Test-Path -LiteralPath $outputs.Svg) { $outputs.Svg } else { '' })"
    Write-Host "PACKAGE_COUNT=$($resolved.Count)"
    Write-Host "DIRECT_COUNT=$directCount"
    Write-Host "EDGE_COUNT=$($edges.Count)"
    Write-Info "Done."
    exit 0
}
catch {
    Write-Err $_.Exception.Message
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    Write-Host @"
Remediation:
  - Ensure 'dotnet restore' succeeded for the project
  - Re-run with explicit --Project and check working directory
  - See script comment-based help: Get-Help .\create-dependency-graph.ps1 -Full
"@
    exit 2
}
