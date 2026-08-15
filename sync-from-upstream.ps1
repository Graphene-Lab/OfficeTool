<#
.SYNOPSIS
    Sync the vendored OfficeCLI engine from the upstream STABLE release (Source Code zip).

.DESCRIPTION
    Downloads the "Source code (zip)" of the latest (or a pinned) GitHub release of
    iOfficeAI/OfficeCLI, extracts it, and copies the vendored trees
    (the officecli project into ExternalDependencies/officecli, skills/, schemas/help/)
    into this project byte-identical to the release. Then:

      * prunes vendored files that no longer exist in the release (mirror deletions);
      * converts the vendored officecli.csproj from console (Exe) to Library and grants
        InternalsVisibleTo to the adapter (OfficeTool) and its test harness — the ONLY
        structural change to the vendored project (see VENDOR.md, "Fidelity rules");
      * updates the version/commit/date rows in VENDOR.md;
      * reports byte-identical parity (hash of every copied file, excluding the
        transformed officecli.csproj);
      * prints `git diff --stat` as the change report.

    Syncing from the release zip (instead of the repository) means the vendor always
    tracks the STABLE release, never in-progress work on the upstream default branch.

.PARAMETER Tag
    Release tag to sync, e.g. "v1.0.144". Default: the latest release.

.PARAMETER UpstreamPath
    Optional: local path containing an OfficeCLI source tree (release zip extract or
    git checkout). Offline mode — skips the GitHub download. The version is read from
    the upstream officecli.csproj.

.PARAMETER Repo
    Upstream GitHub repository. Default "iOfficeAI/OfficeCLI".

.EXAMPLE
    .\sync-from-upstream.ps1                # sync to the latest release
    .\sync-from-upstream.ps1 -Tag v1.0.144  # pin a specific release
    .\sync-from-upstream.ps1 -UpstreamPath D:\tmp\OfficeCLI-v1.0.144
#>
param(
    [string]$Tag,
    [string]$UpstreamPath,
    [string]$Repo = "iOfficeAI/OfficeCLI"
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

# Where the officecli project lives in THIS repo (upstream keeps it at src/officecli).
$engineRel = 'ExternalDependencies\officecli'
$engineDst = Join-Path $root $engineRel

# UTF-8 (no BOM) I/O helpers — PowerShell 5.1's Get/Set-Content corrupt UTF-8 files.
function Read-Utf8([string]$Path) { return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) }
function Write-Utf8([string]$Path, [string]$Content) {
    [IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Test-Dir([string]$Path, [string]$What) {
    if (-not (Test-Path $Path -PathType Container)) { throw "Required $What not found at: $Path" }
}

# --- exclude list from sync-exclude.txt (patterns relative to the officecli project root) ---
$excludes = @(Get-Content (Join-Path $root 'sync-exclude.txt') |
    Where-Object { $_ -and -not $_.TrimStart().StartsWith('#') })

function Match-Exclude([string]$RelPath) {
    $r = $RelPath.Replace('\', '/').TrimStart('/')
    foreach ($pattern in $excludes) {
        $p = $pattern.Trim().Replace('\', '/').TrimEnd('/')
        if ($p -eq '') { continue }
        if ($r -eq $p) { return $true }
        if ($r.StartsWith($p + '/')) { return $true }
        if ($p -like '*') { if ($r -like $p) { return $true } }
    }
    return $false
}

function Is-BuildArtifact([string]$Rel) {
    return $Rel -like 'bin\*' -or $Rel -like 'obj\*' -or $Rel -like 'bin/*' -or $Rel -like 'obj/*'
}

# Resolve the commit SHA a release tag points to (dereferences annotated tags).
# target_commitish on the release is often a branch NAME ("main"), not a SHA.
function Resolve-TagCommit([string]$Repo, [string]$TagName) {
    $ref = gh api "repos/$Repo/git/ref/tags/$TagName" 2>$null | ConvertFrom-Json
    if (-not $ref) { return $TagName }
    if ($ref.object.type -eq 'commit') { return $ref.object.sha }
    $tag = gh api "repos/$Repo/git/tags/$($ref.object.sha)" 2>$null | ConvertFrom-Json
    return if ($tag) { $tag.object.sha } else { $ref.object.sha }
}

# Convert the vendored officecli.csproj from console (Exe) to Library and grant
# InternalsVisibleTo to the adapter plugin + its test harness. This is the ONLY
# structural divergence from the upstream project (VENDOR.md fidelity rule): the
# engine source files stay byte-identical. Idempotent: a second run is a no-op.
function Convert-CsprojToLibrary([string]$Path) {
    if (-not (Test-Path $Path)) { throw "Vendored project file not found at: $Path" }
    $text = Read-Utf8 $Path
    $orig = $text

    if ($text -match '<OutputType>') {
        $text = $text -replace '<OutputType>[^<]*</OutputType>', '<OutputType>Library</OutputType>'
    }
    else {
        $text = $text -replace '(<TargetFramework>[^<]*</TargetFramework>)', "`$1`r`n    <OutputType>Library</OutputType>"
    }
    # Console-only publish settings (single-file, self-contained, trimming) have no
    # meaning for an in-process library and would leak into host publish pipelines.
    foreach ($prop in 'PublishSingleFile', 'SelfContained', 'PublishTrimmed', 'CETCompat') {
        $text = [regex]::Replace($text, "(?m)^[ \t]*<$prop>[^<]*</$prop>[ \t]*`r?`n", '')
    }
    if ($text -notmatch 'InternalsVisibleTo') {
        $ivt = @'

  <ItemGroup>
    <!-- Friend assemblies: the adapter plugin and its test harness use internal engine
         APIs (Watch*, TemplateMerger, SchemaHelpLoader, SkillInstaller, CommandBuilder,
         BatchTypes, ...). This grant + the Exe->Library conversion are the ONLY changes
         to the vendored project; the engine sources stay byte-identical to upstream. -->
    <InternalsVisibleTo Include="OfficeTool" />
    <InternalsVisibleTo Include="OfficeTool.Tests" />
  </ItemGroup>
'@
        $text = $text -replace '</Project>', ($ivt + "`r`n</Project>")
    }

    if ($text -notmatch '<OutputType>Library</OutputType>') {
        throw "csproj transform failed: OutputType is not Library after conversion."
    }
    if ($text -ne $orig) {
        Write-Utf8 $Path $text
        return $true
    }
    return $false
}

# --- resolve upstream source -------------------------------------------------
$upstream = $null
$releaseTag = $Tag
$releaseCommit = '(not recorded)'

if ($UpstreamPath) {
    $upstream = (Resolve-Path $UpstreamPath).Path
    Write-Host "==> Offline mode: syncing from local path $upstream"
    $csproj = Join-Path $upstream 'src\officecli\officecli.csproj'
    if (Test-Path $csproj) {
        $m = [regex]::Match((Read-Utf8 $csproj), '<Version>([^<]+)</Version>')
        if ($m.Success) { $releaseTag = $m.Groups[1].Value; $releaseCommit = "(local checkout — not recorded)" }
    }
    Test-Dir (Join-Path $upstream 'src\officecli') 'src\officecli'
    Test-Dir (Join-Path $upstream 'skills') 'skills'
    Test-Dir (Join-Path $upstream 'schemas\help') 'schemas\help'
}
else {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "gh CLI not found on PATH. Install GitHub CLI or pass -UpstreamPath for offline sync."
    }
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        throw "curl.exe not found (required for the release zip download)."
    }

    if ($Tag) {
        Write-Host "==> Querying release $Tag ..."
        $rel = gh api "repos/$Repo/releases/tags/$Tag" --jq '{tag_name, target_commitish, zipball_url}'
    }
    else {
        Write-Host "==> Querying latest release of $Repo ..."
        $rel = gh api "repos/$Repo/releases/latest" --jq '{tag_name, target_commitish, zipball_url}'
    }
    if (-not $rel) { throw "No release found for tag '$Tag' in $Repo (or no releases at all)." }
    $info = $rel | ConvertFrom-Json
    $releaseTag = $info.tag_name
    $releaseCommit = Resolve-TagCommit $Repo $releaseTag
    Write-Host "  release: $releaseTag (commit $releaseCommit)"

    $work = Join-Path $env:TEMP "OfficeTool-sync"
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $work | Out-Null

    $zip = Join-Path $work "source.zip"
    Write-Host "==> Downloading Source code (zip): $($info.zipball_url)"
    curl.exe -L -sS -o $zip $info.zipball_url
    if ($LASTEXITCODE -ne 0) { throw "curl download failed (exit $LASTEXITCODE)" }
    if (-not (Test-Path $zip) -or (Get-Item $zip).Length -eq 0) { throw "Downloaded archive is empty." }

    Write-Host "==> Extracting ..."
    Expand-Archive -Path $zip -DestinationPath $work -Force
    $top = Get-ChildItem $work -Directory | Where-Object { $_.Name -ne 'source.zip' } | Select-Object -First 1
    if (-not $top) { throw "Release zip has no top-level directory." }
    $upstream = $top.FullName
    Write-Host "  extracted to $upstream"
}

# --- copy vendored trees (byte-identical, mirroring deletions) ---------------
# Upstream layout: src/officecli (the project), skills/, schemas/ at the repo root.
# Our layout:      ExternalDependencies/officecli (the project), skills/, schemas/.
$copied = 0; $pruned = 0; $skipped = 0
foreach ($sub in @(@{ Up = 'src\officecli'; Dst = $engineRel }, @{ Up = 'skills'; Dst = 'skills' }, @{ Up = 'schemas'; Dst = 'schemas' })) {
    Write-Host "==> Syncing $($sub.Up) -> $($sub.Dst)"
    $src = Join-Path $upstream $sub.Up
    $dst = Join-Path $root $sub.Dst
    Test-Dir $src $sub.Up
    if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Force -Path $dst | Out-Null }

    Get-ChildItem $src -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($src.Length + 1)
        if (Is-BuildArtifact $rel) { return }
        if ($sub.Up -eq 'src\officecli' -and (Match-Exclude $rel)) { $script:skipped++; return }
        $target = Join-Path $dst $rel
        New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
        Copy-Item $_.FullName $target -Force
        $script:copied++
    }

    # mirror deletions: remove vendored files absent from the release
    Get-ChildItem $dst -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($dst.Length + 1)
        if (Is-BuildArtifact $rel) { return }
        if ($sub.Up -eq 'src\officecli' -and (Match-Exclude $rel)) { return }
        if (-not (Test-Path (Join-Path $src $rel))) {
            Remove-Item $_.FullName -Force
            Write-Host "  removed (gone in release): $rel"
            $script:pruned++
        }
    }
}
Write-Host "  $copied files copied, $pruned removed, $skipped excluded"

# --- convert the vendored project: console -> library ------------------------
Write-Host ""
Write-Host "==> Converting vendored officecli.csproj (Exe -> Library + InternalsVisibleTo):"
$vendoredCsprojPath = Join-Path $engineDst 'officecli.csproj'
# Keep a pristine copy of the upstream csproj next to the vendored one (gitignored):
# update-vendor.ps1 uses it as the reference for the EmbeddedResource parity check.
Copy-Item $vendoredCsprojPath (Join-Path $engineDst 'officecli.csproj.upstream') -Force
$transformed = Convert-CsprojToLibrary $vendoredCsprojPath
if ($transformed) { Write-Host "  transformed OK (idempotent on re-run)." }
else { Write-Host "  already Library — no change." }

# --- byte-identical parity check (excludes: build artifacts + sync-exclude +
#     the transformed officecli.csproj) ---------------------------------------
Write-Host ""
Write-Host "==> Parity check (hash of every vendored file vs release):"
$total = 0; $bad = 0
foreach ($sub in @(@{ Up = 'src\officecli'; Dst = $engineRel }, @{ Up = 'skills'; Dst = 'skills' }, @{ Up = 'schemas'; Dst = 'schemas' })) {
    $src = Join-Path $upstream $sub.Up
    $dst = Join-Path $root $sub.Dst
    Get-ChildItem $src -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($src.Length + 1)
        if (Is-BuildArtifact $rel) { return }
        if ($sub.Up -eq 'src\officecli' -and (Match-Exclude $rel)) { return }
        # officecli.csproj is intentionally transformed (Exe->Library + InternalsVisibleTo).
        if ($rel -eq 'officecli.csproj') { return }
        $script:total++
        $target = Join-Path $dst $rel
        if (-not (Test-Path $target)) { Write-Host "  MISSING: $rel"; $script:bad++; return }
        $h1 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
        $h2 = (Get-FileHash $target -Algorithm SHA256).Hash
        if ($h1 -ne $h2) { Write-Host "  DIFFERS: $rel"; $script:bad++ }
    }
}
if ($bad -eq 0) { Write-Host "  OK — $total files byte-identical to $releaseTag (officecli.csproj excluded: transformed)." }
else { Write-Host "  DRIFT: $bad of $total files differ from the release. Investigate before committing." }

# --- update VENDOR.md version/commit/date rows -------------------------------
$vendorPath = Join-Path $root 'VENDOR.md'
if (Test-Path $vendorPath) {
    $content = Read-Utf8 $vendorPath
    $today = Get-Date -Format 'yyyy-MM-dd'
    $content = [regex]::Replace($content, '(?m)^\| Upstream version \|.*$', ('| Upstream version | ' + $releaseTag + ' |'))
    $content = [regex]::Replace($content, '(?m)^\| Upstream commit \|.*$', ('| Upstream commit | ' + $releaseCommit + ' |'))
    $content = [regex]::Replace($content, '(?m)^\| Sync date \|.*$', ('| Sync date | ' + $today + ' |'))
    Write-Utf8 $vendorPath $content
    Write-Host ""
    Write-Host "==> VENDOR.md updated: version=$releaseTag commit=$releaseCommit date=$today"
}

# --- change report -----------------------------------------------------------
Write-Host ""
Write-Host "==> git diff --stat (vendored changes vs last sync):"
git -C $root diff --stat -- ExternalDependencies skills schemas VENDOR.md
Write-Host ""
Write-Host "==> git status --short (new/untracked vendored files are NOT in the diff):"
git -C $root status --short -- ExternalDependencies skills schemas VENDOR.md
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Review the diff and the parity line above (must say byte-identical)."
Write-Host "  2. Build:  dotnet build OfficeTool.csproj -c Release"
Write-Host "  3. Run the full update (surface analysis + generation + build + tests):  .\update-vendor.ps1"
Write-Host "  4. Update NOTICE.md version, commit the result, push (CI publishes NuGet)."
