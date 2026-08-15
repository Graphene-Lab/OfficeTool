<#
.SYNOPSIS
    Vendor to OfficeTool updater AND adapter generator — fully automatic update of the
    OfficeTool plugin from the upstream STABLE release of OfficeCLI.

.DESCRIPTION
    The vendored engine is a separate Library project (ExternalDependencies/officecli)
    that the adapter references. The adapter (OfficeTool.cs) is a MINIMAL class whose
    public method surface is REGENERATED from the deterministic analysis of the vendored
    code: every command the shipped documentation mentions must exist as a method, and
    the script owns the method templates (bodies + XML docs). This is what makes a vendor
    update a one-command operation with no human intervention:

      1. sync-from-upstream.ps1   — download the release Source code (zip), replace the
                                    vendored engine byte-identical, convert the vendored
                                    officecli.csproj from console to Library
                                    (OutputType + InternalsVisibleTo), update VENDOR.md;
      2. Surface analysis         — parse the vendored CommandBuilder*.cs for commands
                                    (new Command("x") + Build*Command factory names), the
                                    view modes, and the load_skill entry point. This is
                                    the deterministic "which methods must be exposed" pass;
      3. Generation               — assemble the adapter surface block (methods + XML docs)
                                    from the template library below, emitting exactly the
                                    methods whose vendor command/mode exists, and patch
                                    OfficeTool.cs between its @@ADAPTER_SURFACE markers;
      4. Coherence checks         — every found command/view-mode must be mapped (template,
                                    excluded-with-reason, or a NEW-command warning), the
                                    generated LoadSkill surface must match the unified
                                    contract, and the vendored csproj embedded resources
                                    must equal the pristine upstream ones;
      5. Build the plugin         — surfaces engine API / adapter drift;
      6. Run OfficeTool.Tests     — the deterministic harness, --full
                                    (smoke + golden vendor regression + view/edits/skills/help);
      7. Optional: pack           — verify the NuGet package builds (adapter + engine dll).

    The report is written to sync-gap-report.md at the repo root (gitignored) and
    printed. Nothing is committed or pushed.

.PARAMETER Tag
    Release tag to sync (default: latest). Passed through to sync-from-upstream.ps1.

.PARAMETER UpstreamPath
    Offline sync from a local source tree. Passed through to sync-from-upstream.ps1.

.PARAMETER SkipSync / SkipBuild / SkipTests / SkipPack
    Skip individual pipeline stages (e.g. -SkipSync to re-analyze + regenerate an
    already-synced tree; -SkipBuild -SkipTests to only regenerate the adapter).

.EXAMPLE
    .\update-vendor.ps1                 # full update to the latest release
    .\update-vendor.ps1 -Tag v1.0.144   # update to a pinned release
    .\update-vendor.ps1 -SkipSync       # analysis + generation + build + tests on current tree
#>
param(
    [string]$Tag,
    [string]$UpstreamPath,
    [switch]$SkipSync,
    [switch]$SkipBuild,
    [switch]$SkipTests,
    [switch]$SkipPack
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$reportPath = Join-Path $root 'sync-gap-report.md'
$report = New-Object System.Text.StringBuilder

function Write-Report([string]$Line) {
    Write-Host $Line
    [void]$report.AppendLine($Line)
}
function Read-Utf8([string]$Path) { return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) }
function Write-Utf8([string]$Path, [string]$Content) {
    [IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

# --- prereqs -----------------------------------------------------------------
foreach ($tool in @('git', 'dotnet')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required tool '$tool' not found on PATH." }
}
if (-not $UpstreamPath -and -not $SkipSync -and -not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "gh CLI not found on PATH (needed to resolve the release). Pass -UpstreamPath for offline sync."
}

Write-Report "=== OfficeTool vendor update pipeline ==="
Write-Report ("Start: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

$engineDir = Join-Path $root 'ExternalDependencies\officecli'
$toolPath = Join-Path $root 'OfficeTool.cs'
if (-not (Test-Path $engineDir)) { throw "Vendored engine not found at: $engineDir (run the sync stage first)." }
if (-not (Test-Path $toolPath)) { throw "OfficeTool.cs not found at: $toolPath" }

# --- 1. sync -----------------------------------------------------------------
if (-not $SkipSync) {
    $syncArgs = @{}
    if ($Tag) { $syncArgs['Tag'] = $Tag }
    if ($UpstreamPath) { $syncArgs['UpstreamPath'] = $UpstreamPath }
    & (Join-Path $root 'sync-from-upstream.ps1') @syncArgs
    if ($LASTEXITCODE -ne 0) { throw "sync-from-upstream.ps1 failed (exit $LASTEXITCODE)." }
}
else {
    Write-Report "(sync skipped)"
}

# =============================================================================
#  2. DETERMINISTIC SURFACE ANALYSIS (the vendored tree is the source of truth)
# =============================================================================
Write-Report ""
Write-Report "=== Surface analysis (vendored OfficeCLI commands) ==="

function Get-CliSurface([string]$EngineDir) {
    $cmds = [ordered]@{}
    Get-ChildItem (Join-Path $EngineDir 'CommandBuilder*.cs') -File |
        Where-Object { $_.Name -ne 'CommandBuilder.Plugins.cs' } | ForEach-Object {
        $text = Read-Utf8 $_.FullName
        # literal registrations: new Command("name", "description")
        foreach ($m in [regex]::Matches($text, 'new Command\("([A-Za-z0-9_\-]+)"')) {
            $cmds[$m.Groups[1].Value] = $true
        }
        # factory-built commands: BuildXCommand(jsonOption, "name") — the name-param default
        foreach ($m in [regex]::Matches($text, 'string name = "([A-Za-z0-9_\-]+)"')) {
            $cmds[$m.Groups[1].Value] = $true
        }
    }
    # view modes: the comma-separated list right after "View mode:" in CommandBuilder.View.cs
    $viewModes = New-Object System.Collections.Generic.List[string]
    $viewFile = Join-Path $EngineDir 'CommandBuilder.View.cs'
    if (Test-Path $viewFile) {
        $m = [regex]::Match((Read-Utf8 $viewFile), 'View mode:\s*([a-zA-Z]+(?:,\s*[a-zA-Z]+)*)')
        if ($m.Success) {
            $m.Groups[1].Value -split ',' | ForEach-Object {
                $v = $_.Trim()
                if ($v -and -not $viewModes.Contains($v)) { $viewModes.Add($v) }
            }
        }
    }
    # load_skill: early-dispatched in upstream Program.cs (excluded from the vendor);
    # its presence is detected from the vendored code/doc mentions.
    $hasLoadSkill = @(Get-ChildItem $EngineDir -Recurse -File -Filter *.cs |
        Select-String -Pattern 'load_skill' -List -ErrorAction SilentlyContinue).Count -gt 0
    # set --find/--replace: the canonical find/replace options of the set command
    # (CommandBuilder.Set.cs merges them into the props dict as find=/replace=, which the
    # engine handlers consume). The adapter exposes them as the find/replace parameters of
    # Set(); when upstream drops them, HasSetFindReplace goes false and the coherence check
    # below reports the mismatch (the params degrade gracefully at runtime).
    $hasSetFindReplace = $false
    $setFile = Join-Path $EngineDir 'CommandBuilder.Set.cs'
    if (Test-Path $setFile) {
        $setText = Read-Utf8 $setFile
        $hasSetFindReplace = ($setText -match '"--find"') -and ($setText -match '"--replace"')
    }
    return @{ Commands = $cmds; ViewModes = $viewModes; HasLoadSkill = $hasLoadSkill; HasSetFindReplace = $hasSetFindReplace }
}

$surface = Get-CliSurface $engineDir
$foundCmds = $surface.Commands
$foundModes = $surface.ViewModes
Write-Report ("CLI commands found:    " + $foundCmds.Count + " -> " + (($foundCmds.Keys | Sort-Object) -join ', '))
Write-Report ("View modes found:      " + ($foundModes -join ', '))
Write-Report ("load_skill entry:      " + $surface.HasLoadSkill)
Write-Report ("set --find/--replace:  " + $surface.HasSetFindReplace)

# Commands intentionally NOT exposed as methods (environment/infra ops, see OfficePorting.md §3).
$excludedCommands = @{
    'close'             = 'resident infra — instance state replaces it (Save()/Dispose())'
    '__resident-serve__' = 'internal CLI plumbing'
    'refresh'           = 'Word TOC/page refresh — backend candidate, not yet ported'
    'plugins'           = 'environment op (installer/plugins), not agent-facing'
    'install'           = 'environment op'
    'config'            = 'environment op'
    'mcp'               = 'environment op'
    'skills'            = 'environment op'
    'skill'             = 'environment op (alias of skills)'
    'view'              = 'container command — its modes are mapped individually'
    'view pdf'          = 'exporter plugin (installed plugin + subprocess), not agent-facing'
}

# =============================================================================
#  3. ADAPTER METHOD TEMPLATES (bodies + XML docs; the "intelligent" adapter logic)
#     Key: method name. Commands/modes = vendor surface this method serves; the method
#     is emitted only when ALL of them exist in the analyzed surface. Always = emitted
#     unconditionally (infra of the adapter itself, not a CLI command).
# =============================================================================
$Methods = [ordered]@{

    'Open' = @{
        Commands = @('open')
        Code = @'
        /// <summary>
        /// Opens an existing Office document (docx/xlsx/pptx) for editing and replaces the current one.
        /// </summary>
        /// <param name="filePath">Path to an existing .docx/.xlsx/.pptx file (Unix style, e.g. "/folder/file.docx"),
        /// relative to the workspace root.</param>
        /// <returns>"Opened '&lt;path&gt;'.", or "Error:" with the cause.</returns>
        public string Open(string filePath)
        {
            try
            {
                _handler?.Dispose();
                var resolved = SandboxPath.Resolve(filePath);
                _handler = DocumentHandlerFactory.Open(resolved, editable: true);
                _filePath = resolved;
                Log.LogStep($"OfficeTool.Open: opened '{resolved}'");
                return $"Opened '{SandboxPath.ToAgent(resolved)}'.";
            }
            catch (Exception ex)
            {
                _handler?.Dispose();
                _handler = null;
                _filePath = string.Empty;
                Log.LogStep($"OfficeTool.Open: failed '{filePath}': {ex.Message}");
                return $"Error: Cannot open '{filePath}'. {ex.Message}";
            }
        }
'@
    }

    'Create' = @{
        Commands = @('create')
        # Backup-Before-Write (guide policy): creating over an existing file would destroy
        # it — a numbered backup is made first and the backup name is returned to the agent
        # (same pattern as Save). Restore() recovers the previous version.
        Code = @'
        /// <summary>
        /// Creates a new blank Office document (docx/xlsx/pptx) on THIS instance and saves it.
        /// The format is determined by the file extension. If the target file already exists,
        /// it is backed up (numbered .bak) before being overwritten — Restore() recovers it.
        /// </summary>
        /// <param name="filePath">Path where the new document is saved (Unix style, e.g. "/folder/deck.pptx"),
        /// relative to the workspace root. Extension must be .docx, .xlsx or .pptx.</param>
        /// <returns>"Created '&lt;path&gt;'." plus the backup name when an existing file was overwritten,
        /// or "Error:".</returns>
        public string Create(string filePath)
        {
            try
            {
                var resolved = SandboxPath.Resolve(filePath);
                var ext = Path.GetExtension(resolved).ToLowerInvariant();
                if (ext is not (".docx" or ".xlsx" or ".pptx"))
                    return $"Error: Unsupported extension '{ext}' — use .docx, .xlsx or .pptx.";
                _handler?.Dispose();
                var backupName = CreateBackup(resolved);
                BlankDocCreator.Create(resolved, locale: null, minimal: false);
                _handler = DocumentHandlerFactory.Open(resolved, editable: true);
                _filePath = resolved;
                Log.LogStep(backupName == null
                    ? $"OfficeTool.Create: created '{resolved}'"
                    : $"OfficeTool.Create: created '{resolved}' (backed up existing as '{backupName}')");
                var agentPath = SandboxPath.ToAgent(resolved);
                return backupName == null
                    ? $"Created '{agentPath}'."
                    : $"Created '{agentPath}'. The previous version was backed up as '{backupName}'.";
            }
            catch (Exception ex)
            {
                _handler?.Dispose();
                _handler = null;
                _filePath = string.Empty;
                Log.LogStep($"OfficeTool.Create: failed '{filePath}': {ex.Message}");
                return $"Error: Cannot create '{filePath}'. {ex.Message}";
            }
        }
'@
    }

    'Save' = @{
        Commands = @('save')
        Code = @'
        /// <summary>
        /// Writes all pending changes to the current file path — an explicit checkpoint.
        /// Before saving, creates a numbered backup of the existing file (.001.bak, .002.bak, ...)
        /// so the original state can be restored later via <see cref="Restore"/>.
        /// </summary>
        /// <returns>A message with the backup file name, or an "Error:" string when no document is open.</returns>
        public string Save()
        {
            if (_handler == null) return NoDocumentError;
            try
            {
                var backupName = CreateBackup(_filePath);
                _handler.Save();
                Log.LogStep($"OfficeTool.Save: saved '{_filePath}', backup='{backupName}'");
                var agentPath = SandboxPath.ToAgent(_filePath);
                return backupName == null
                    ? $"Document saved to '{agentPath}'. (New file, no backup needed.)"
                    : $"Document saved to '{agentPath}'. The previous version was backed up as '{backupName}'.";
            }
            catch (CliException ex) { return FormatCliError(ex); }
            catch (Exception ex) { Log.LogStep($"OfficeTool.Save: FAILED — {ex.Message}"); return $"Error: Save failed: {ex.Message}"; }
        }
'@
    }

    'Restore' = @{
        Always = $true
        Code = @'
        /// <summary>
        /// Restores the document to its state from the most recent backup (.bak file).
        /// The current (modified) document is replaced with the backup copy, and the backup file
        /// is preserved (not deleted) for future rollbacks.
        /// </summary>
        /// <returns>A message describing the restore result.</returns>
        public string Restore()
        {
            if (_handler == null) return NoDocumentError;
            try
            {
                var dir = Path.GetDirectoryName(_filePath) ?? ".";
                var nameWithoutExt = Path.GetFileNameWithoutExtension(_filePath);
                var backupFiles = Directory.GetFiles(dir, $"{nameWithoutExt}.*.bak")
                    .OrderByDescending(f => f)
                    .ToList();
                if (backupFiles.Count == 0)
                    return "No backup file found. The document was never saved with backup enabled.";
                var latestBackup = backupFiles[0];
                var backupName = Path.GetFileName(latestBackup);
                _handler.Dispose();
                File.Copy(latestBackup, _filePath, overwrite: true);
                _handler = DocumentHandlerFactory.Open(_filePath, editable: true);
                Log.LogStep($"OfficeTool.Restore: restored '{_filePath}' from '{backupName}'");
                return $"Document restored from backup '{backupName}'. The backup file has been preserved.";
            }
            catch (CliException ex) { return FormatCliError(ex); }
            catch (Exception ex) { Log.LogStep($"OfficeTool.Restore: FAILED — {ex.Message}"); return $"Error: Restore failed: {ex.Message}"; }
        }
'@
    }

    'ViewOutline' = @{
        Commands = @('view outline')
        Code = @'
        /// <summary>
        /// Semantic outline of the document as JSON: the element tree (types, paths, text previews,
        /// child counts) without raw XML. Start here to understand the document structure before editing.
        /// </summary>
        /// <returns>JSON outline, or "Error:" when no document is open.</returns>
        public string ViewOutline()
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() => _handler!.ViewAsOutlineJson().ToJsonString());
        }
'@
    }

    'ViewText' = @{
        Commands = @('view text')
        Code = @'
        /// <summary>
        /// Document text as JSON (line-based). For xlsx a cell-range subset is available via <paramref name="range"/>.
        /// </summary>
        /// <param name="startLine">Optional 1-based first line to include.</param>
        /// <param name="endLine">Optional last line to include (inclusive).</param>
        /// <param name="maxLines">Optional maximum number of lines to return.</param>
        /// <param name="cols">Optional column filter (xlsx): cell references or column letters, e.g. ["A","C"].</param>
        /// <param name="range">Optional cell-range subset, xlsx only, e.g. "Sheet1!A1:C10" (or "/Sheet1/A1:C10").
        /// For docx/pptx use startLine/endLine instead — a range is rejected there.</param>
        /// <returns>JSON text view, or "Error:" (e.g. invalid range).</returns>
        public string ViewText(int? startLine = null, int? endLine = null, int? maxLines = null, string[]? cols = null, string? range = null)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() => _handler!.ViewAsTextJson(startLine, endLine, maxLines, ToHashSet(cols), range).ToJsonString());
        }
'@
    }

    'ViewAnnotated' = @{
        Commands = @('view annotated')
        Code = @'
        /// <summary>
        /// Annotated text view: document text with inline markers showing element boundaries and paths.
        /// </summary>
        /// <param name="startLine">Optional 1-based first line to include.</param>
        /// <param name="endLine">Optional last line to include (inclusive).</param>
        /// <param name="maxLines">Optional maximum number of lines to return.</param>
        /// <param name="cols">Optional column filter (xlsx).</param>
        /// <returns>Annotated text, or "Error:" when no document is open.</returns>
        public string ViewAnnotated(int? startLine = null, int? endLine = null, int? maxLines = null, string[]? cols = null)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() => _handler!.ViewAsAnnotated(startLine, endLine, maxLines, ToHashSet(cols)));
        }
'@
    }

    'ViewStats' = @{
        Commands = @('view stats')
        Code = @'
        /// <summary>
        /// Document statistics as JSON (paragraphs/cells/slides counts, page size, style usage...).
        /// </summary>
        /// <param name="pageCount">Optional (docx): also report the total page count as a "pages" field —
        /// via real Word repagination on Windows+Word (authoritative, slow), else the HTML preview's
        /// paginator (approximate). "Error:" when no backend is available.</param>
        /// <returns>JSON stats, or "Error:" when no document is open.</returns>
        public string ViewStats(bool pageCount = false)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() =>
            {
                var stats = _handler!.ViewAsStatsJson();
                if (pageCount && _handler is WordHandler)
                {
                    int? pages = null;
                    if (OperatingSystem.IsWindows())
                    {
                        try { pages = OfficeCli.Core.WordPdfBackend.GetPageCount(_filePath); } catch { pages = null; }
                    }
                    if (pages == null)
                    {
                        var tmp = Path.Combine(Path.GetTempPath(), $"oec_pc_{Guid.NewGuid():N}.html");
                        try
                        {
                            File.WriteAllText(tmp, CommandBuilder.RenderViaRegistry(_handler!, "docx",
                                new OfficeCli.Core.Rendering.RenderOptions())!);
                            pages = OfficeCli.Core.HtmlScreenshot.GetPageCountFromDom(tmp);
                        }
                        finally { try { File.Delete(tmp); } catch { /* ignore */ } }
                    }
                    if (pages == null)
                        throw new CliException("--page-count: failed to get page count (Word backend and HTML fallback both unavailable).")
                        { Code = "page_count_unavailable" };
                    stats["pages"] = pages.Value;
                }
                return stats.ToJsonString();
            });
        }
'@
    }

    'ViewIssues' = @{
        Commands = @('view issues')
        Code = @'
        /// <summary>
        /// Detected document issues (format/content/structure) as JSON: {count, issues}.
        /// Issues carry a stable machine-readable "subtype" the agent can filter on.
        /// </summary>
        /// <param name="issueType">Optional filter: "format" | "content" | "structure".</param>
        /// <param name="limit">Optional maximum number of issues to return.</param>
        /// <returns>JSON {count, issues}, or "Error:" when no document is open.</returns>
        public string ViewIssues(string? issueType = null, int? limit = null)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() =>
            {
                var issues = _handler!.ViewAsIssues(issueType, limit);
                return Json(new { count = issues.Count, issues });
            });
        }
'@
    }

    'Validate' = @{
        Commands = @('validate')
        Code = @'
        /// <summary>
        /// Validates the document against the OpenXML schema and returns any errors as JSON {count, errors}.
        /// </summary>
        /// <returns>JSON validation result, or "Error:" when no document is open.</returns>
        public string Validate()
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() =>
            {
                var errors = _handler!.Validate();
                return Json(new { count = errors.Count, errors });
            });
        }
'@
    }

    'ViewForms' = @{
        Commands = @('view forms')
        Code = @'
        /// <summary>
        /// Lists the content controls (form fields) of a Word document as JSON — officecli `view forms`.
        /// Each control reports its type and state (checkbox, dropdown, date, text, ...). DOCX only.
        /// </summary>
        /// <returns>JSON forms, or "Error:" (not a .docx, or no document open).</returns>
        public string ViewForms()
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() =>
            {
                if (_handler is not WordHandler word)
                    throw new CliException("Forms view is only supported for .docx files.") { Code = "unsupported_type" };
                return word.ViewAsFormsJson().ToJsonString(OfficeCli.Core.OutputFormatter.PublicJsonOptions);
            });
        }
'@
    }

    'Get' = @{
        Commands = @('get')
        Code = @'
        /// <summary>
        /// Reads an element (and children down to the given depth) at a document path, as JSON.
        /// Paths use officecli syntax: /slide[1]/shape[2], /body/p[1], /Sheet1/A1 (1-based), or a selector
        /// like paragraph[style=Heading1]. Use "/" for the document root.
        /// </summary>
        /// <param name="path">Document path in officecli syntax (produced by ViewOutline/Query).</param>
        /// <param name="depth">How many levels of children to include (default 1).</param>
        /// <param name="save">Optional: extract the binary payload backing an embedded node
        /// (picture/ole/media) to this workspace path — officecli `get --save`. Returns bytes +
        /// content type instead of the JSON DOM. Not every node has a payload.</param>
        /// <returns>JSON envelope {matches, results: [...]}, "Extracted N bytes (MIME) to '&lt;path&gt;'.",
        /// or "Error:".</returns>
        public string Get(string path, int depth = 1, string? save = null)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() =>
            {
                if (save != null)
                {
                    var dest = SandboxPath.Resolve(save);
                    var dir = Path.GetDirectoryName(dest);
                    if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                    if (!_handler!.TryExtractBinary(path, dest, out var contentType, out var byteCount))
                        return $"Error: Node at '{path}' has no binary payload to extract (only ole/picture/media/embedded nodes can be saved).";
                    Log.LogStep($"OfficeTool.Get: extracted '{path}' -> '{dest}' ({byteCount} bytes)");
                    return $"Extracted {byteCount} bytes ({(string.IsNullOrEmpty(contentType) ? "unknown type" : contentType)}) to '{SandboxPath.ToAgent(dest)}'.";
                }
                var node = _handler!.Get(path, depth);
                if (string.Equals(node.Type, "error", StringComparison.Ordinal))
                {
                    var err = node.Text ?? $"Path not found: {path}";
                    throw new CliException(err) { Code = "not_found" };
                }
                return Json(new { matches = 1, results = new[] { node } });
            });
        }
'@
    }

    'GetSelected' = @{
        Commands = @('get')
        NeedsSelectedPseudoPath = $true
        Code = @'
        /// <summary>
        /// Returns the elements currently selected in the watch browser(s), as JSON
        /// {matches, results} — officecli `get selected`.
        /// </summary>
        /// <param name="depth">How many levels of children to include (default 1).</param>
        /// <returns>JSON envelope, or "Error:" (no watch running).</returns>
        public string GetSelected(int depth = 1)
        {
            if (_handler == null) return NoDocumentError;
            if (!IsWatchAllowed) return WatchGatedError;
            return Exec(() =>
            {
                var paths = OfficeCli.Core.WatchNotifier.QuerySelection(_filePath);
                if (paths == null)
                    return "Error: No watch is running for this file. Call Watch() first.";
                var nodes = new List<DocumentNode>();
                foreach (var p in paths)
                {
                    try { var n = _handler!.Get(p, depth); if (n != null) nodes.Add(n); }
                    catch { /* path no longer resolves — drop */ }
                }
                var flat = new List<DocumentNode>();
                foreach (var n in nodes)
                {
                    if (n.Children.Count > 0 && n.Type is "column" or "row") flat.AddRange(n.Children);
                    else flat.Add(n);
                }
                return Json(new { matches = flat.Count, results = flat });
            });
        }
'@
    }

    'Query' = @{
        Commands = @('query')
        # Full vendor parity: find (text filter), compact (line format), fields (extra compact
        # columns). The pipeline lives in AdapterSupport (FilterSelector + MatchesTextFilter +
        # FormatNodesCompact) so vendor changes to query surface as build breaks, never drift.
        Code = @'
        /// <summary>
        /// Queries all elements matching a CSS-like selector, as JSON. Selectors address elements by type,
        /// attribute values and position, e.g. shape[text~=quarter], paragraph[style=Heading1], row[2];
        /// boolean expressions are supported (e.g. Dashboard!:has(formula), p[style=Heading1] > run[font!=Arial]).
        /// Count results cheaply with the "matches" field of the JSON envelope (no need to parse "results").
        /// Decision pattern for large documents: call Query(selector) first, read "matches", and when it is
        /// large switch to compact:true for the full listing — the envelope tells you the size deterministically,
        /// no guessing.
        /// </summary>
        /// <param name="selector">Selector in officecli syntax (see Help for the selector reference).</param>
        /// <param name="find">Find where text lives before editing: keeps only elements whose text contains
        /// this substring (case-insensitive). Use it to locate the elements that mention something
        /// (e.g. find:"Q3") and to prove something is absent (a 0-count envelope).</param>
        /// <param name="compact">Cheap whole-result overview: one line per element with a final
        /// "total: N of M elements" footer, instead of the full JSON tree. Use it when the result set is
        /// large: a full JSON tree over many elements is tens of fields of noise per node and can get
        /// truncated by observation limits, silently hiding matches — the compact footer proves you saw
        /// everything. Not supported for xlsx (use ViewText).</param>
        /// <param name="fields">Targeted checks in compact mode: comma-separated property keys appended
        /// as extra k=v columns (e.g. "x,y,width" to verify layout geometry). Ignored unless compact is true.</param>
        /// <returns>JSON envelope {matches, results, warnings?}, the compact text, or "Error:".</returns>
        public string Query(string selector, string? find = null, bool compact = false, string? fields = null)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() => AdapterSupport.Query(_handler!, selector, find, compact, fields));
        }
'@
    }

    'Set' = @{
        Commands = @('set')
        # find/replace are always exposed (parity with the vendored set command); the merge,
        # conflict and match-count logic lives in AdapterSupport (hand-maintained, never
        # regenerated) so the generated method stays thin. When upstream drops --find/--replace
        # the coherence check warns and the params degrade gracefully at runtime.
        Code = @'
        /// <summary>
        /// Modifies element properties at the given document path. Accepts selectors and Excel-native paths
        /// (parity with Get/Query). Any XML attribute is settable.
        /// Text substitution: pass find (+ replace) — use path "/" for whole-document scope.
        /// Call Help(format, element) first when unsure about property names or value formats.
        /// </summary>
        /// <param name="path">Document path in officecli syntax (e.g. /body/p[1], 1-based; or a selector
        /// like paragraph[style=Heading1]). Produced by Get()/Query(). Use "/" for whole-document scope.</param>
        /// <param name="props">Properties as 'key=value' strings, e.g. ["align=center", "style=Heading1"].
        /// Accepts aliases (align/alignment/halign) and value formats: colors (FF0000, red, accent1),
        /// dimensions (2cm, 1in, 72pt, EMU), spacing (12pt, 1.5x, 150%). Dotted aliases allowed
        /// (font.color=red, revision.author=Alice). Full property list: Help(format, element).</param>
        /// <param name="find">Optional: find this text (literal substring; the r"..." prefix enables regex,
        /// e.g. r"\d{4}") and apply props/replace only to its matches. With path "/" the scope is the
        /// whole document. Mutually exclusive with a 'find=' entry in props.</param>
        /// <param name="replace">Optional: replacement text for find matches (requires find). With path "/"
        /// this substitutes text across the whole document.</param>
        /// <param name="force">Optional: bypass document protection (.docx) — the vendor's --force. Without
        /// it, a protected document is rejected; Query("editable") lists the editable regions.</param>
        /// <returns>Confirmation with the path, the match count (or a 0-matched warning), or "Error:".</returns>
        public string Set(string path, string[]? props = null, string? find = null, string? replace = null, bool force = false)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() =>
            {
                var block = AdapterSupport.EnsureEditable(_handler!, path, force);
                if (block != null) return "Error: " + block;
                var result = AdapterSupport.Set(_handler!, path, ParseProps(props), find, replace);
                NotifyWatch();
                return result;
            });
        }
'@
    }

    'Add' = @{
        Commands = @('add')
        Code = @'
        /// <summary>
        /// Adds a new element of the given type under a parent path, and returns its path.
        /// </summary>
        /// <param name="parentPath">Parent document path (e.g. /slide[1], /body, /Sheet1).</param>
        /// <param name="type">Element type to add (e.g. paragraph, shape, cell, slide, sheet, picture, table).
        /// Full list per format: Help(format, element).</param>
        /// <param name="props">Properties as 'key=value' strings (same rules as Set).</param>
        /// <param name="after">Optional: insert after this sibling path.</param>
        /// <param name="before">Optional: insert before this sibling path.</param>
        /// <param name="index">Optional: insert at this 0-based position among siblings (officecli legacy — document
        /// paths are 1-based, this insertion index is 0-based as in the CLI).</param>
        /// <param name="from">Optional: instead of creating a blank element, copy an existing element from this path.</param>
        /// <param name="force">Optional: bypass document protection (.docx) — the vendor's --force. Without
        /// it, a protected document is rejected; Query("editable") lists the editable regions.</param>
        /// <returns>The path of the new element, or "Error:".</returns>
        public string Add(string parentPath, string type, string[]? props = null, string? after = null, string? before = null, int? index = null, string? from = null, bool force = false)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() =>
            {
                var block = AdapterSupport.EnsureEditable(_handler!, parentPath, force);
                if (block != null) return "Error: " + block;
                var position = InsertPositionFor(after, before, index);
                var dict = ParseProps(props);
                // picture/media/ole/video sources are workspace paths in agent terms — resolve
                // them to host paths before the engine opens them (the engine has no sandbox).
                if (type is "picture" or "media" or "ole" or "video")
                    foreach (var key in new[] { "src", "path" })
                        if (dict.TryGetValue(key, out var src) && src.StartsWith('/') && !src.StartsWith("//"))
                            dict[key] = SandboxPath.Resolve(src);
                var newPath = from != null
                    ? _handler!.CopyFrom(from, parentPath, position)
                    : _handler!.Add(parentPath, type, position, dict);
                NotifyWatch();
                return $"Added {newPath}.";
            });
        }
'@
    }

    'Remove' = @{
        Commands = @('remove')
        Code = @'
        /// <summary>
        /// Removes the element at the given document path.
        /// </summary>
        /// <param name="path">Document path to remove (e.g. /slide[2]/shape[3]).</param>
        /// <param name="props">Optional: for Word, trackChange.* keys record the removal as a revision
        /// (e.g. trackChange=on) instead of physically deleting.</param>
        /// <param name="shift">Optional: for xlsx single-cell removal, shift the remaining cells to fill the
        /// gap — "left" or "up" (mirrors Excel's Delete Cells > Shift cells). Excel cell path only.</param>
        /// <returns>Confirmation (with any warning), or "Error:".</returns>
        public string Remove(string path, string[]? props = null, string? shift = null)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() =>
            {
                string? warning;
                if (shift != null)
                {
                    if (_handler is not OfficeCli.Handlers.ExcelHandler xl)
                        throw new CliException("--shift is supported only for Excel cell paths (e.g. /Sheet1/B5).")
                        { Code = "invalid_argument" };
                    warning = xl.RemoveCellWithShift(path, shift);
                }
                else
                {
                    warning = _handler!.Remove(path, ParseProps(props));
                }
                var result = warning == null ? $"Removed {path}." : $"Removed {path}. {warning}";
                NotifyWatch();
                return result;
            });
        }
'@
    }

    'Move' = @{
        Commands = @('move')
        Code = @'
        /// <summary>
        /// Moves an element to another parent and/or position.
        /// </summary>
        /// <param name="path">Document path of the element to move.</param>
        /// <param name="to">Optional: target parent path to move the element into.</param>
        /// <param name="index">Optional: 0-based insertion position among the target's children.</param>
        /// <param name="after">Optional: insert after this sibling path.</param>
        /// <param name="before">Optional: insert before this sibling path.</param>
        /// <param name="props">Optional: properties for the move (e.g. trackChange for Word).</param>
        /// <returns>The new path of the moved element, or "Error:".</returns>
        public string Move(string path, string? to = null, int? index = null, string? after = null, string? before = null, string[]? props = null)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() =>
            {
                var result = _handler!.Move(path, to, InsertPositionFor(after, before, index), ParseProps(props));
                NotifyWatch();
                return result;
            });
        }
'@
    }

    'Swap' = @{
        Commands = @('swap')
        Code = @'
        /// <summary>
        /// Swaps two elements (slides, shapes, rows/cells, ...) in place.
        /// </summary>
        /// <param name="path1">First document path.</param>
        /// <param name="path2">Second document path.</param>
        /// <returns>Confirmation, or "Error:".</returns>
        public string Swap(string path1, string path2)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() =>
            {
                var result = _handler switch
                {
                    WordHandler word => word.Swap(path1, path2),
                    ExcelHandler excel => excel.Swap(path1, path2),
                    PowerPointHandler ppt => ppt.Swap(path1, path2),
                    _ => throw new CliException($"Swap is not supported for this document type.") { Code = "unsupported" },
                };
                NotifyWatch();
                return $"Swapped {path1} and {path2}. {result}".TrimEnd();
            });
        }
'@
    }

    'Batch' = @{
        Commands = @('batch')
        Code = @'
        /// <summary>
        /// Applies a batch of operations in one call — the officecli `batch` verb. Each item is
        /// {"command": "add|set|get|query|remove|move|swap|view|raw|raw-set|validate", ...} with the same
        /// fields as the single commands (parent/path/selector/type/props/to/after/before/path2).
        /// Items apply in memory on the open document; nothing is written until Save().
        /// Use it for repetitive edits (e.g. many cells/shapes) to save round-trips.
        /// </summary>
        /// <param name="commandsJson">JSON array of batch items (see above).</param>
        /// <param name="stopOnError">Optional: stop at the first failing item (default false: failures are
        /// reported per item and execution continues).</param>
        /// <param name="force">Optional: bypass document protection (.docx) for the whole batch — the vendor's
        /// batch --force. Without it a protected document rejects the batch (editable formfield/sdt regions
        /// stay allowed).</param>
        /// <returns>JSON envelope {success, data: {results, summary}} — outer success is true only when every
        /// step succeeded. Failures carry code+suggestion per item, or "Error:" when no document is open.</returns>
        public string Batch(string commandsJson, bool stopOnError = false, bool force = false)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() =>
            {
                var items = AdapterSupport.DeserializeBatchItems(commandsJson);
                if (!force)
                {
                    var block = OfficeCli.CommandBuilder.GetBatchProtectionBlock(_handler!, items);
                    if (block != null) return "Error: " + block;
                }
                var result = BatchExecutor.ExecuteBatch(_handler!, commandsJson, json: true, stopOnError);
                NotifyWatch();
                return result;
            });
        }
'@
    }

    'Raw' = @{
        Commands = @('raw')
        Code = @'
        /// <summary>
        /// Reads a raw OOXML part (document.xml, styles.xml, slide1.xml, sheet1.xml, ...) as XML text.
        /// Last resort when DOM operations cannot express the needed change.
        /// </summary>
        /// <param name="partPath">Part path, e.g. "/word/document.xml", "/ppt/slides/slide1.xml", "/xl/worksheets/sheet1.xml".</param>
        /// <param name="startRow">Optional: for sheet parts, first row to include.</param>
        /// <param name="endRow">Optional: for sheet parts, last row to include.</param>
        /// <param name="cols">Optional: for sheet parts, column filter (e.g. ["A","C"]).</param>
        /// <returns>The raw XML, or "Error:".</returns>
        public string Raw(string partPath, int? startRow = null, int? endRow = null, string[]? cols = null)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() => _handler!.Raw(partPath, startRow, endRow, ToHashSet(cols)));
        }
'@
    }

    'RawSet' = @{
        Commands = @('raw-set')
        Code = @'
        /// <summary>
        /// Applies an XPath mutation to a raw OOXML part. Actions: set-text, set-attr, remove-attr, remove-node.
        /// </summary>
        /// <param name="partPath">Part path (see Raw).</param>
        /// <param name="xpath">XPath selecting the target node(s) inside the part.</param>
        /// <param name="action">"set-text" | "set-attr" | "remove-attr" | "remove-node".</param>
        /// <param name="xml">Optional payload for the action (new text/attribute value).</param>
        /// <returns>Confirmation with affected node count, or "Error:".</returns>
        public string RawSet(string partPath, string xpath, string action, string? xml = null)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() =>
            {
                _handler!.RawSet(partPath, xpath, action, xml);
                NotifyWatch();
                return $"Applied {action} on '{xpath}' in {partPath}.";
            });
        }
'@
    }

    'AddPart' = @{
        Commands = @('add-part')
        Code = @'
        /// <summary>
        /// Creates a new part (chart, header, footer, ...) and returns its relationship ID and path.
        /// </summary>
        /// <param name="parentPath">Parent part path, e.g. "/word/document.xml", "/ppt/presentation.xml", "/xl/workbook.xml".</param>
        /// <param name="partType">Part type to create (e.g. chart, header, footer, tableStyles). Full list per format: Help(format, element).</param>
        /// <param name="props">Optional properties as 'key=value' strings.</param>
        /// <returns>JSON {relId, path}, or "Error:".</returns>
        public string AddPart(string parentPath, string partType, string[]? props = null)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() =>
            {
                var (relId, partPath) = _handler!.AddPart(parentPath, partType, ParseProps(props));
                return Json(new { relId, path = partPath });
            });
        }
'@
    }

    'ViewHtml' = @{
        Commands = @('view html')
        Code = @'
        /// <summary>
        /// Renders the document to HTML (the same preview officecli `view html` produces) so the agent
        /// can inspect layout. Writes the HTML to <paramref name="filePath"/> when given and returns the
        /// workspace path; otherwise returns the HTML inline.
        /// </summary>
        /// <param name="filePath">Optional: where to save the .html (Unix style, e.g. "/out/doc.html").</param>
        /// <param name="page">Optional: for pptx, slide number or range to render (e.g. "1", "1-3"); for docx, page filter.</param>
        /// <returns>The workspace path of the saved HTML (or the HTML itself when filePath is null), or "Error:".</returns>
        public string ViewHtml(string? filePath = null, string? page = null)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() =>
            {
                var formatId = Path.GetExtension(_filePath).TrimStart('.').ToLowerInvariant();
                var html = CommandBuilder.RenderViaRegistry(_handler!, formatId, BuildRenderOptions(formatId, page));
                if (html == null)
                    throw new CliException("HTML preview is only supported for .pptx, .xlsx and .docx files.")
                    { Code = "unsupported_type" };
                if (string.IsNullOrWhiteSpace(filePath)) return html;
                var resolved = SandboxPath.Resolve(filePath);
                var dir = Path.GetDirectoryName(resolved);
                if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                File.WriteAllText(resolved, html);
                Log.LogStep($"OfficeTool.ViewHtml: wrote '{resolved}'");
                return $"HTML preview saved to '{SandboxPath.ToAgent(resolved)}'. Open it in a browser to inspect the layout.";
            });
        }
'@
    }

    'Merge' = @{
        Commands = @('merge')
        Code = @'
        /// <summary>
        /// Fills a document template with data and saves the result to a new file — officecli `merge`.
        /// Template placeholders (e.g. {{name}}) are replaced by the data values; the result is a new file.
        /// </summary>
        /// <param name="templatePath">Path of the template document (Unix style).</param>
        /// <param name="outputPath">Path where the merged document is saved (Unix style).</param>
        /// <param name="dataJson">JSON object mapping placeholder keys to values, e.g. {"name": "Acme", "amount": "1200"}.</param>
        /// <returns>Confirmation with the number of replacements (and unresolved placeholders, if any), or "Error:".</returns>
        public string Merge(string templatePath, string outputPath, string dataJson)
        {
            try
            {
                var template = SandboxPath.Resolve(templatePath);
                var output = SandboxPath.Resolve(outputPath);
                var data = JsonSerializer.Deserialize<Dictionary<string, string>>(dataJson)
                    ?? throw new CliException("Invalid data JSON: expected an object of key/value strings.") { Code = "invalid_value" };
                var result = TemplateMerger.Merge(template, output, data, force: false);
                var msg = $"Merged '{SandboxPath.ToAgent(output)}': {result.ReplacedCount} placeholder(s) replaced.";
                if (result.UnresolvedPlaceholders.Count > 0)
                    msg += $" Unresolved placeholders: {string.Join(", ", result.UnresolvedPlaceholders)}.";
                return msg;
            }
            catch (CliException ex) { return FormatCliError(ex); }
            catch (Exception ex) { return $"Error: {ex.Message}"; }
        }
'@
    }

    'Dump' = @{
        Commands = @('dump')
        Code = @'
        /// <summary>
        /// Serializes the open document into a reproducible batch-JSON blueprint (officecli `dump`).
        /// The output can be replayed on a blank file via Batch() to clone or adapt the document.
        /// </summary>
        /// <param name="path">Optional: document path to dump (default: whole document).</param>
        /// <returns>JSON array of batch items (starts with the meta item), or "Error:".</returns>
        public string Dump(string? path = null)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() =>
            {
                List<BatchItem> items = _handler switch
                {
                    WordHandler w => WordBatchEmitter.EmitWordWithWarnings(w, path).Items,
                    PowerPointHandler p => PptxBatchEmitter.EmitPptx(p, path).Items,
                    ExcelHandler e => ExcelBatchEmitter.EmitExcel(e, path).Items,
                    _ => throw new CliException("Dump is not supported for this document type.") { Code = "unsupported" },
                };
                var wire = new List<BatchItem> { BatchCompat.MetaItem() };
                wire.AddRange(items);
                return JsonSerializer.Serialize(wire, BatchJsonContext.Default.ListBatchItem);
            });
        }
'@
    }

    'Import' = @{
        Commands = @('import')
        Code = @'
        /// <summary>
        /// Imports a CSV/TSV file into a worksheet (officecli `import`).
        /// </summary>
        /// <param name="parentPath">Worksheet path, e.g. "/Sheet1".</param>
        /// <param name="csvPath">Path of the CSV/TSV source file (Unix style, in the workspace).</param>
        /// <param name="format">Optional: "csv" (default) or "tsv". When omitted, inferred from the file extension.</param>
        /// <param name="header">Optional: first row is a header — sets an AutoFilter and freezes the header row (default false).</param>
        /// <param name="startCell">Optional: starting cell (default "A1").</param>
        /// <returns>Confirmation with the number of imported cells/rows, or "Error:".</returns>
        public string Import(string parentPath, string csvPath, string? format = null, bool header = false, string startCell = "A1")
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() =>
            {
                if (_handler is not ExcelHandler excel)
                    throw new CliException("Import is only supported for xlsx workbooks.") { Code = "unsupported_type" };
                var resolved = SandboxPath.Resolve(csvPath);
                var content = File.ReadAllText(resolved);
                var fmt = (format ?? Path.GetExtension(csvPath).ToLowerInvariant()) switch
                {
                    "tsv" or ".tsv" => "tsv",
                    _ => "csv",
                };
                var delimiter = fmt == "tsv" ? '\t' : ',';
                var result = excel.Import(parentPath, content, delimiter, header, startCell);
                NotifyWatch();
                return result;
            });
        }
'@
    }

    'Watch' = @{
        Commands = @('watch')
        Code = @'
        /// <summary>
        /// Starts a live HTML preview server for the open document (officecli `watch`):
        /// the preview updates in the browser as the document is edited, so the user can
        /// watch the agent work. Requires a local desktop session (isLocalUser): on a
        /// server/headless host use ViewHtml() instead.
        /// </summary>
        /// <param name="port">Optional HTTP port (default 26315).</param>
        /// <returns>The preview URL, or "Error:".</returns>
        public string Watch(int port = 26315)
        {
            if (_handler == null) return NoDocumentError;
            if (!IsWatchAllowed) return WatchGatedError;
            return Exec(() =>
            {
                if (_watch != null)
                    return $"Already watching at http://localhost:{port}. Call Unwatch() to stop.";
                var formatId = Path.GetExtension(_filePath).TrimStart('.').ToLowerInvariant();
                var html = CommandBuilder.RenderViaRegistry(_handler!, formatId, new OfficeCli.Core.Rendering.RenderOptions());
                _watchCts = new CancellationTokenSource();
                var server = new OfficeCli.Core.WatchServer(_filePath, port, initialHtml: html);
                _watch = server;
                _watchTask = Task.Run(() => server.RunAsync(_watchCts.Token));
                Log.LogStep($"OfficeTool.Watch: started on port {port} for '{_filePath}'");
                return $"Watching http://localhost:{port} — the preview refreshes live as the document is edited. " +
                       "Call Unwatch() to stop.";
            });
        }
'@
    }

    'Unwatch' = @{
        Commands = @('unwatch')
        Code = @'
        /// <summary>
        /// Stops the watch preview server started by <see cref="Watch"/>.
        /// </summary>
        /// <returns>Confirmation, or "Error:".</returns>
        public string Unwatch()
        {
            if (_watch == null) return "Error: No watch is running. Call Watch() first.";
            return Exec(() =>
            {
                StopWatch();
                return "Watch stopped.";
            });
        }
'@
    }

    'Goto' = @{
        Commands = @('goto')
        Code = @'
        /// <summary>
        /// Scrolls the watch preview(s) to the given document path (officecli `goto`).
        /// </summary>
        /// <param name="path">Document path to scroll to (e.g. /body/p[3], /Sheet1/A10).</param>
        /// <returns>Confirmation, or "Error:" (no watch running / path not found).</returns>
        public string Goto(string path)
        {
            if (_handler == null) return NoDocumentError;
            if (!IsWatchAllowed) return WatchGatedError;
            return Exec(() =>
            {
                var result = OfficeCli.Core.WatchNotifier.TryScroll(_filePath, path);
                return result.Kind switch
                {
                    OfficeCli.Core.ScrollResult.K.Ok => $"Scrolled to '{path}' in the watch preview.",
                    OfficeCli.Core.ScrollResult.K.NotFound => $"Error: {result.Error}",
                    _ => "Error: No watch is running for this file. Call Watch() first.",
                };
            });
        }
'@
    }

    'Mark' = @{
        Commands = @('mark')
        Code = @'
        /// <summary>
        /// Attaches an advisory mark to a document path in the watch preview (officecli `mark`):
        /// a visible annotation (color/note) flagging an element for human review. Marks are pure
        /// metadata — nothing in the document changes until a human acts on them.
        /// </summary>
        /// <param name="path">Document path to mark.</param>
        /// <param name="props">Optional 'key=value' strings: color, note, tofix, find.</param>
        /// <returns>The mark id, or "Error:".</returns>
        public string Mark(string path, string[]? props = null)
        {
            if (_handler == null) return NoDocumentError;
            if (!IsWatchAllowed) return WatchGatedError;
            return Exec(() =>
            {
                var req = new OfficeCli.Core.MarkRequest { Path = path };
                foreach (var (k, v) in ParseProps(props))
                {
                    switch (k.ToLowerInvariant())
                    {
                        case "find": req.Find = v; break;
                        case "color": req.Color = v; break;
                        case "note": req.Note = v; break;
                        case "tofix": req.Tofix = v; break;
                    }
                }
                var id = OfficeCli.Core.WatchNotifier.AddMark(_filePath, req);
                if (id == null)
                    return "Error: No watch is running for this file. Call Watch() first.";
                return $"Mark added (id {id}) at '{path}'. Advisory only — the document is unchanged until a human reviews it.";
            });
        }
'@
    }

    'Unmark' = @{
        Commands = @('unmark')
        Code = @'
        /// <summary>
        /// Removes marks (officecli `unmark`).
        /// </summary>
        /// <param name="path">Optional: remove only marks on this path.</param>
        /// <param name="all">Optional: remove all marks (default false).</param>
        /// <returns>Confirmation with the removed count, or "Error:".</returns>
        public string Unmark(string? path = null, bool all = false)
        {
            if (_handler == null) return NoDocumentError;
            if (!IsWatchAllowed) return WatchGatedError;
            return Exec(() =>
            {
                var removed = OfficeCli.Core.WatchNotifier.RemoveMarks(_filePath, new OfficeCli.Core.UnmarkRequest { Path = path, All = all });
                if (removed == null)
                    return "Error: No watch is running for this file. Call Watch() first.";
                return removed.Value == 0 ? "No marks to remove." : $"Removed {removed.Value} mark(s).";
            });
        }
'@
    }

    'GetMarks' = @{
        Commands = @('get-marks')
        Code = @'
        /// <summary>
        /// Lists the current watch marks as JSON {count, marks} (officecli `get-marks`).
        /// </summary>
        /// <returns>JSON marks, or "Error:" (no watch running).</returns>
        public string GetMarks()
        {
            if (_handler == null) return NoDocumentError;
            if (!IsWatchAllowed) return WatchGatedError;
            return Exec(() =>
            {
                var marks = OfficeCli.Core.WatchNotifier.QueryMarks(_filePath);
                if (marks == null)
                    return "Error: No watch is running for this file. Call Watch() first.";
                return Json(new { count = marks.Length, marks });
            });
        }
'@
    }

    'ViewScreenshot' = @{
        Commands = @('view screenshot')
        Code = @'
        /// <summary>
        /// Renders the document to a PNG screenshot via a headless Chrome-family browser
        /// (Chrome/Edge/Chromium), closing the render→observe→correct loop for layout issues.
        /// </summary>
        /// <param name="filePath">Optional: where to save the .png (Unix style, e.g. "/out/issue1.png").
        /// When omitted, the PNG is saved under "/out/" with a generated name — the returned path
        /// always tells you where the screenshot is.</param>
        /// <param name="page">Optional: page/slide to capture (e.g. "1", "1-3").</param>
        /// <param name="width">Optional: target width in px (default 1600, capped at 1920).</param>
        /// <param name="height">Optional: target height in px (default 1200).</param>
        /// <param name="grid">Optional: tile the whole document into a thumbnail contact sheet
        /// (pptx/docx; "auto" picks the column count, a number forces it — e.g. "3"). Use it for a
        /// one-shot visual pass: pagination, blank pages, heading rhythm. Ignored for xlsx.</param>
        /// <returns>The PNG path, or "Error:" (no browser available).</returns>
        public string ViewScreenshot(string? filePath = null, string? page = null, int width = 1600, int height = 1200, string? grid = null)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() =>
            {
                var outPng = string.IsNullOrWhiteSpace(filePath)
                    ? SandboxPath.Resolve($"/out/oec_shot_{Guid.NewGuid():N}.png")
                    : SandboxPath.Resolve(filePath);
                var dir = Path.GetDirectoryName(outPng);
                if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                if (grid != null && _handler is not OfficeCli.Handlers.ExcelHandler)
                {
                    AdapterSupport.ViewScreenshotGrid(_handler!, grid, outPng, width, height);
                    Log.LogStep($"OfficeTool.ViewScreenshot: wrote '{outPng}' (grid {grid})");
                    return $"Screenshot saved to '{SandboxPath.ToAgent(outPng)}'.";
                }
                var formatId = Path.GetExtension(_filePath).TrimStart('.').ToLowerInvariant();
                var html = CommandBuilder.RenderViaRegistry(_handler!, formatId, BuildRenderOptions(formatId, page));
                if (html == null)
                    throw new CliException("Screenshot is only supported for .pptx, .xlsx and .docx files.")
                    { Code = "unsupported_type" };
                var tmpHtml = Path.Combine(Path.GetTempPath(), $"oec_shot_{Guid.NewGuid():N}.html");
                File.WriteAllText(tmpHtml, html);
                try
                {
                    // The PNG always lands inside the workspace: an explicit path is resolved
                    // against the sandbox root, an omitted one defaults to /out/ with a generated
                    // name. The agent is always told where the file is (a screenshot nobody can
                    // reference is useless) and never sees a host path.
                    var result = OfficeCli.Core.HtmlScreenshot.Capture(tmpHtml, outPng, width, height);
                    if (!result.Ok)
                        throw new CliException(
                            $"Screenshot failed: {result.Error}. Requires a Chrome-family browser (Chrome/Edge/Chromium) installed on the host.")
                        { Code = "screenshot_unavailable" };
                    Log.LogStep($"OfficeTool.ViewScreenshot: wrote '{outPng}'");
                    return $"Screenshot saved to '{SandboxPath.ToAgent(outPng)}'.";
                }
                finally { File.Delete(tmpHtml); }
            });
        }
'@
    }

    'ViewSvg' = @{
        Commands = @('view svg')
        Code = @'
        /// <summary>
        /// Renders a slide of a PPTX document to SVG — officecli `view svg`.
        /// Returns the SVG markup for the requested slide, useful for inspecting precise
        /// geometry/layout before editing. PPTX only. The page filter uses the same format as
        /// the other view modes ("3", "2-4" — the first slide of the range is rendered, like
        /// the CLI --page).
        /// </summary>
        /// <param name="page">Optional page filter, e.g. "3" or "2-4" (renders the first slide of a range; default 1).</param>
        /// <returns>SVG markup, or "Error:" (not a .pptx, or no document open).</returns>
        public string ViewSvg(string? page = null)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() =>
            {
                if (_handler is not PowerPointHandler)
                    throw new CliException("SVG rendering is only supported for .pptx files.") { Code = "unsupported_type" };
                int slideNum = 1;
                if (!string.IsNullOrWhiteSpace(page))
                {
                    var firstTok = page.Split(',')[0].Split('-')[0].Trim();
                    if (!int.TryParse(firstTok, out var p) || p <= 0)
                        return $"Error: Invalid page '{page}': expected a positive slide number.";
                    slideNum = p;
                }
                var formatId = Path.GetExtension(_filePath).TrimStart('.').ToLowerInvariant();
                var svg = CommandBuilder.RenderViaRegistry(_handler!, formatId,
                    new OfficeCli.Core.Rendering.RenderOptions
                    { Output = OfficeCli.Core.Rendering.RenderOutputKind.Svg, StartPage = slideNum });
                return svg ?? throw new CliException("SVG rendering is not available for this document.")
                {
                    Code = "unsupported_type",
                    ValidValues = ["pptx"],
                };
            });
        }
'@
    }

    'LoadSkill' = @{
        Commands = @('load_skill')
        Code = @'
        /// <summary>
        /// Loads a specialized skill (officecli `load_skill`): the SKILL.md guidance for a
        /// domain workflow (pitch-deck, financial-model, academic-paper, data-dashboard,
        /// word-form, docx/xlsx/pptx, ...). Skills bundle the strategy, decision rules and
        /// reference files that make the agent work well on that kind of document.
        /// When skill is omitted, returns the catalog of all available skills (name + what
        /// each one is for) — the same help the vendor serves for `load_skill` with no name.
        /// When skill starts with "/", it is treated as a path to a bundled reference file
        /// of a skill, e.g. "/pitch-deck/reference/decision-rules.md" (first segment = skill
        /// name, rest = file inside the skill). Paths are confined to the skill folder,
        /// exactly like the vendor: no "..", no absolute paths, binary assets rejected.
        /// </summary>
        /// <param name="skill">Skill name (e.g. "pitch-deck"); omit to list the available skills;
        /// or a "/&lt;skill&gt;/&lt;relpath&gt;" reference file inside a skill.</param>
        /// <returns>The skill content (SKILL.md + reference manifest), the reference file, the
        /// catalog, or "Error:" with the available skills.</returns>
        public override string LoadSkill(string? skill = null)
        {
            try
            {
                if (string.IsNullOrEmpty(skill))
                    return OfficeCli.Core.SkillInstaller.BuildSkillCatalog();
                if (skill[0] == '/')
                {
                    var parts = skill.TrimStart('/').Split(new[] { '/' }, 2);
                    var rel = parts.Length > 1 ? parts[1] : "";
                    if (rel.Length == 0)
                        return $"Error: path for skill '{parts[0]}' is empty — use /<skill>/<relpath>, e.g. /pitch-deck/reference/decision-rules.md";
                    return AdapterSupport.TranslateSkillSyntax(OfficeCli.Core.SkillInstaller.LoadSkillFile(parts[0], rel));
                }
                // The vendor skill text is CLI-syntax; the on-the-fly translation rewrites the
                // clean invocations into this session's method vocabulary (AdapterSupport owns
                // the mapping — hand-maintained, never regenerated).
                return AdapterSupport.TranslateSkillSyntax(OfficeCli.Core.SkillInstaller.LoadSkillContent(skill));
            }
            catch (ArgumentException ex) { return $"Error: {ex.Message}"; }
            catch (Exception ex) { return $"Error: {ex.Message}"; }
        }
'@
    }

    'Help' = @{
        Commands = @('help')
        Code = @'
        /// <summary>
        /// Returns the property schema for an element type of a format — the same embedded help schemas
        /// officecli serves via `help`: property names, aliases, value formats, examples, readback and
        /// get/set/add support. Call this before Set/Add whenever unsure about property names or values.
        /// </summary>
        /// <param name="format">Optional: "docx" (alias word), "xlsx" (excel), "pptx" (ppt). When omitted,
        /// lists the formats and their element types.</param>
        /// <param name="element">Optional: element type, e.g. "paragraph", "shape", "cell", "slide", "table".
        /// When omitted with a format, lists the element types available for that format.</param>
        /// <returns>The schema JSON (verbatim from the embedded schemas/help tree), the element list, or "Error:".</returns>
        public string Help(string? format = null, string? element = null)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(format))
                {
                    var formats = SchemaHelpLoader.ListFormats();
                    var sb = new StringBuilder();
                    sb.AppendLine("Office formats: " + string.Join(", ", formats));
                    sb.AppendLine("Aliases: word=docx, excel=xlsx, ppt/powerpoint=pptx.");
                    sb.AppendLine("Call Help(\"docx\") to list elements, Help(\"docx\", \"paragraph\") for a property schema.");
                    return sb.ToString();
                }
                var canonical = SchemaHelpLoader.NormalizeFormat(format);
                if (string.IsNullOrWhiteSpace(element))
                {
                    var elements = SchemaHelpLoader.ListElements(canonical);
                    return Json(new { format = canonical, elements });
                }
                using var doc = SchemaHelpLoader.LoadSchema(canonical, element);
                return doc.RootElement.ToString();
            }
            catch (CliException ex) { return FormatCliError(ex); }
            catch (Exception ex) { return $"Error: {ex.Message}"; }
        }
'@
    }

}

# =============================================================================
#  4. SURFACE DECISION + GENERATION
# =============================================================================
Write-Report ""
Write-Report "=== Adapter surface generation ==="

$commandToMethod = @{}
$viewModeToMethod = @{}
foreach ($kv in $Methods.GetEnumerator()) {
    foreach ($c in @($kv.Value.Commands | Where-Object { $_ })) { $commandToMethod[$c] = $kv.Key }
    foreach ($c in @($kv.Value.Commands | Where-Object { $_ })) {
        if ($c.StartsWith('view ')) { $viewModeToMethod[$c.Substring(5)] = $kv.Key }
    }
}

# Decide emission per template.
$emitted = New-Object System.Collections.Generic.List[string]
$dropped = New-Object System.Collections.Generic.List[string]
foreach ($kv in $Methods.GetEnumerator()) {
    $name = $kv.Key; $tpl = $kv.Value
    $ok = $true
    if ($tpl.Always) { $ok = $true }
    else {
        foreach ($c in @($tpl.Commands | Where-Object { $_ })) {
            if ($c.StartsWith('view ')) {
                if ($foundModes -notcontains $c.Substring(5)) { $ok = $false; break }
            }
            elseif ($c -eq 'load_skill') {
                if (-not $surface.HasLoadSkill) { $ok = $false; break }
            }
            else {
                if (-not $foundCmds.Contains($c)) { $ok = $false; break }
            }
        }
        if ($ok -and $tpl.NeedsSelectedPseudoPath) {
            $getFile = Join-Path $engineDir 'CommandBuilder.GetQuery.cs'
            if (Test-Path $getFile) {
                $ok = (Read-Utf8 $getFile) -match 'selected'
            }
        }
    }
    if ($ok) { [void]$emitted.Add($name) }
    else { [void]$dropped.Add($name) }
}
Write-Report ("Emitted methods:      " + $emitted.Count + " -> " + (($emitted[($emitted.Count-1)..0]) -join ', '))
if ($dropped.Count -gt 0) { Write-Report ("Dropped (vendor surface lacks their command/mode): " + ($dropped -join ', ')) }

# Coherence: every found command and view mode must be handled (method, excluded, or new).
$newCmds = @(); $newModes = @()
foreach ($c in $foundCmds.Keys) {
    if ($commandToMethod.ContainsKey($c) -or $excludedCommands.ContainsKey($c)) { continue }
    $newCmds += $c
}
foreach ($m in $foundModes) {
    if ($viewModeToMethod.ContainsKey($m) -or $excludedCommands.ContainsKey("view $m")) { continue }
    $newModes += $m
}
$missingMethods = @()
foreach ($kv in $Methods.GetEnumerator()) {
    if (-not $emitted.Contains($kv.Key)) { continue }
    foreach ($c in @($kv.Value.Commands | Where-Object { $_ })) {
        if ($c.StartsWith('view ')) {
            if ($foundModes -notcontains $c.Substring(5)) { $missingMethods += "$($kv.Key) (view $($c.Substring(5)))" }
        }
        elseif ($c -eq 'load_skill') {
            if (-not $surface.HasLoadSkill) { $missingMethods += "$($kv.Key) (load_skill)" }
        }
        else {
            if (-not $foundCmds.Contains($c)) { $missingMethods += "$($kv.Key) ($c)" }
        }
    }
}

if ($newCmds.Count -eq 0) { Write-Report "OK — no new CLI commands." }
else { Write-Report ("WARNING — NEW CLI command(s) without a template: " + ($newCmds -join ', ')) }
if ($newModes.Count -eq 0) { Write-Report "OK — no new view modes." }
else { Write-Report ("WARNING — NEW view mode(s) without a template: " + ($newModes -join ', ')) }
if ($missingMethods.Count -eq 0) { Write-Report "OK — every emitted method's command/mode exists in the vendor." }
else { Write-Report ("WARNING — emitted method whose command/mode is missing: " + ($missingMethods -join ', ')) }

# set find/replace coherence: the adapter always exposes Set(find, replace) (the merge and
# match-count logic lives in AdapterSupport, hand-maintained); when the vendored set command
# loses the canonical --find/--replace options the params degrade to "Skipped unsupported
# properties" at runtime — this line keeps the gap visible in the report.
if ($emitted -contains 'Set') {
    if ($surface.HasSetFindReplace) {
        Write-Report "OK — Set find/replace parameters match the vendored set command (--find/--replace)."
    }
    else {
        Write-Report "WARNING — vendored set has no --find/--replace; Set(find, replace) params degrade to 'Skipped unsupported properties' at runtime."
    }
}

# --- embedded-resource parity (upstream csproj vs the transformed vendored one) ---
Write-Report ""
Write-Report "=== Embedded-resource parity ==="
function Get-EmbeddedBlocks([string]$Path) {
    $text = Read-Utf8 $Path
    $blocks = New-Object System.Collections.Generic.List[string]
    # self-closing: <EmbeddedResource ... /> ; block form: <EmbeddedResource ...>...</EmbeddedResource>
    $pattern = '<EmbeddedResource[^>]*/>|<EmbeddedResource[^>]*>(?:(?!</EmbeddedResource>).)*</EmbeddedResource>'
    foreach ($m in [regex]::Matches($text, $pattern)) {
        if (-not $blocks.Contains($m.Value)) { $blocks.Add($m.Value) }
    }
    return $blocks
}
# The transform (sync-from-upstream.ps1) only rewrites OutputType/publish props and appends
# InternalsVisibleTo — it must NEVER touch the EmbeddedResource wiring. The pristine upstream
# csproj is saved next to the vendored one at sync time (officecli.csproj.upstream, gitignored)
# as the comparison reference; the shape check below is the fallback when it is absent.
$vendoredCsproj = Join-Path $engineDir 'officecli.csproj'
$upstreamRef = Join-Path $engineDir 'officecli.csproj.upstream'
$vBlocks = Get-EmbeddedBlocks $vendoredCsproj
if (Test-Path $upstreamRef) {
    $uBlocks = Get-EmbeddedBlocks $upstreamRef
    $missing = @($uBlocks | Where-Object { -not $vBlocks.Contains($_) })
    $extra = @($vBlocks | Where-Object { -not $uBlocks.Contains($_) })
    if ($missing.Count -eq 0 -and $extra.Count -eq 0) {
        Write-Report ("OK — " + $uBlocks.Count + " EmbeddedResource blocks identical to the upstream csproj.")
    }
    else {
        if ($missing.Count -gt 0) { Write-Report ("WARNING — upstream resource block(s) LOST by the transform: "); $missing | ForEach-Object { Write-Report ("           " + $_) } }
        if ($extra.Count -gt 0) { Write-Report ("WARNING — resource block(s) ADDED by the transform: "); $extra | ForEach-Object { Write-Report ("           " + $_) } }
    }
}
elseif ($vBlocks.Count -gt 0) {
    $vText = Read-Utf8 $vendoredCsproj
    $okRes = ($vText -match '<OutputType>Library</OutputType>') -and ($vBlocks.Count -ge 6)
    if ($okRes) { Write-Report ("OK — vendored csproj carries " + $vBlocks.Count + " EmbeddedResource blocks (preview/watch, cx-gallery, chartex, EffectTemplates, skills, schemas); upstream reference absent.") }
    else { Write-Report "WARNING — vendored csproj EmbeddedResource wiring looks incomplete." }
}
else { Write-Report "WARNING — no EmbeddedResource blocks found in the vendored csproj (resources would be missing at runtime)." }

# --- assemble the adapter surface block -------------------------------------
$surfaceCode = New-Object System.Text.StringBuilder
# Reversed order: the method template library is authored discovery-first but keyed in
# hashtable order; emitting in reverse puts the discovery methods (Help, LoadSkill, views)
# at the top of the generated surface, where the agent sees them first.
for ($i = $emitted.Count - 1; $i -ge 0; $i--) {
    $name = $emitted[$i]
    [void]$surfaceCode.AppendLine($Methods[$name].Code.TrimEnd("`r", "`n"))
    [void]$surfaceCode.AppendLine()
}

$markerBegin = '// @@ADAPTER_SURFACE_BEGIN@@'
$markerEnd = '// @@ADAPTER_SURFACE_END@@'
$current = Read-Utf8 $toolPath
$bi = $current.IndexOf($markerBegin)
$ei = $current.IndexOf($markerEnd)
if ($bi -lt 0 -or $ei -lt 0 -or $ei -le $bi) {
    throw "OfficeTool.cs is missing the @@ADAPTER_SURFACE markers — it is not the minimal adapter this pipeline owns."
}
$generated = @"
        // ══════════════════════════════════════════════════════════════════════
        //  ADAPTER SURFACE — GENERATED by update-vendor.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        //  (deterministic analysis of the vendored OfficeCLI commands; do not edit
        //   by hand — the next run regenerates this block)
        // ══════════════════════════════════════════════════════════════════════
"@
$newFile = $current.Substring(0, $bi + $markerBegin.Length) + "`r`n" + $generated + "`r`n" +
           $surfaceCode.ToString().TrimEnd("`r", "`n") + "`r`n" +
           $markerEnd + $current.Substring($ei + $markerEnd.Length)
Write-Utf8 $toolPath $newFile
Write-Report ("OfficeTool.cs regenerated: " + $emitted.Count + " public method(s) between the surface markers.")

# --- LoadSkill surface check (unified contract) ------------------------------
Write-Report ""
Write-Report "=== LoadSkill surface check ==="
$skillSource = $newFile
$skillSig = [regex]::Match($skillSource, 'public\s+override\s+string\s+LoadSkill\s*\(\s*string\?\s*skill\s*=\s*null')
$skillDoc = [regex]::Match($skillSource, '<param\s+name="skill">')
$hasCatalog = $skillSource -match 'BuildSkillCatalog\(\)'
$hasFile    = $skillSource -match 'LoadSkillFile\('
$hasContent = $skillSource -match 'LoadSkillContent\('
$hasNoList  = -not ($skillSource -match 'public\s+string\s+ListSkills\s*\(')
$hasNoFile  = -not ($skillSource -match 'public\s+string\s+LoadSkillFile\s*\(')
$skillOk = $skillSig.Success -and $skillDoc.Success -and $hasCatalog -and $hasFile -and $hasContent -and $hasNoList -and $hasNoFile
if ($skillOk) {
    Write-Report "OK — unified LoadSkill (override, string? skill = null) with catalog/file/content branches; ListSkills/LoadSkillFile not exposed."
}
else {
    Write-Report "WARNING — LoadSkill surface is missing or broken. Expected shape:"
    Write-Report '    public override string LoadSkill(string? skill = null)'
    Write-Report '    {'
    Write-Report '        if (string.IsNullOrEmpty(skill)) return OfficeCli.Core.SkillInstaller.BuildSkillCatalog();'
    Write-Report "        if (skill[0] == '/') { ... LoadSkillFile(parts[0], rel); }"
    Write-Report '        return OfficeCli.Core.SkillInstaller.LoadSkillContent(skill);'
    Write-Report '    }'
    Write-Report ("         signature override: " + $skillSig.Success + " | <param name=`"skill`">: " + $skillDoc.Success +
        " | catalog: " + $hasCatalog + " | file: " + $hasFile + " | content: " + $hasContent +
        " | ListSkills removed: " + $hasNoList + " | LoadSkillFile removed: " + $hasNoFile)
}

# --- write report ------------------------------------------------------------
[IO.File]::WriteAllText($reportPath, $report.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Report ""
Write-Report ("Report written to: $reportPath")

# --- 5. build plugin ---------------------------------------------------------
if (-not $SkipBuild) {
    Write-Report ""
    Write-Report "=== Build OfficeTool plugin (Release) ==="
    dotnet build (Join-Path $root 'OfficeTool.csproj') -c Release -v m -nologo
    if ($LASTEXITCODE -ne 0) { throw "Plugin build failed (exit $LASTEXITCODE). Fix engine API/resource drift or the generated adapter surface first." }
    Write-Report "Plugin build OK."
}
else { Write-Report "(build skipped)" }

# --- 6. harness --------------------------------------------------------------
if (-not $SkipTests) {
    $harness = Join-Path $root 'OfficeTool.Tests\OfficeTool.Tests.csproj'
    if (Test-Path $harness) {
        Write-Report ""
        Write-Report "=== OfficeTool.Tests (deterministic harness, --full) ==="
        dotnet run --project $harness -c Debug -- --full
        if ($LASTEXITCODE -ne 0) { throw "OfficeTool.Tests failed (exit $LASTEXITCODE)." }
        Write-Report "Harness OK."
        # Agent-view: dumps EXACTLY what the agent sees (API mode tool definitions + CLI mode
        # command prompt) into out/agent-view-*.md and fails on doc regressions that would
        # deceive the agent (missing summaries, non-string returns, sandbox/type/path leaks).
        Write-Report ""
        Write-Report "=== OfficeTool agent view (API mode definitions + CLI mode prompt) ==="
        dotnet run --project $harness -c Debug -- --agent-view
        if ($LASTEXITCODE -ne 0) { throw "Agent-view check failed (exit $LASTEXITCODE)." }
        Write-Report "Agent view OK (dumps: out/agent-view-api.md, out/agent-view-cli.md)."
    }
    else { Write-Report "(harness not found — OfficeTool.Tests skipped)" }
}
else { Write-Report "(tests skipped)" }

# --- 7. pack ----------------------------------------------------------------
if (-not $SkipPack) {
    Write-Report ""
    Write-Report "=== Pack (verifies the NuGet pipeline, no push) ==="
    dotnet pack (Join-Path $root 'OfficeTool.csproj') -c Release -o (Join-Path $root 'out') -p:SkipNuGetPush=true -v m -nologo
    if ($LASTEXITCODE -ne 0) { throw "Pack failed (exit $LASTEXITCODE)." }
    $pkg = Get-ChildItem (Join-Path $root 'out') -Filter '*.nupkg' | Select-Object -First 1
    if ($pkg) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($pkg.FullName)
        try {
            $entries = @($zip.Entries | ForEach-Object { $_.FullName })
            $hasOfficeTool = ($entries | Where-Object { $_ -match 'lib/net10\.0/OfficeTool\.dll$' }).Count -gt 0
            $hasOfficeCli  = ($entries | Where-Object { $_ -match 'lib/net10\.0/officecli\.dll$' }).Count -gt 0
            Write-Report ("Package lib/net10.0 contains OfficeTool.dll: " + $hasOfficeTool + " | officecli.dll: " + $hasOfficeCli)
            if (-not ($hasOfficeTool -and $hasOfficeCli)) {
                Write-Report "WARNING — the nupkg must carry BOTH assemblies (adapter + engine)."
            }
            # The engine must NOT appear as a NuGet dependency (it is vendored, not on NuGet).
            $nuspec = $zip.Entries | Where-Object { $_.FullName -match '\.nuspec$' } | Select-Object -First 1
            if ($nuspec) {
                $reader = New-Object IO.StreamReader($nuspec.Open())
                try { $nuspecText = $reader.ReadToEnd() } finally { $reader.Dispose() }
                if ($nuspecText -match 'id="officecli"') {
                    Write-Report "WARNING — the nuspec declares a dependency on 'officecli' (vendored, never on NuGet): PrivateAssets=all is missing on the ProjectReference."
                }
                else { Write-Report "OK — nuspec has no 'officecli' dependency (engine ships in lib, PrivateAssets=all)." }
            }
        }
        finally { $zip.Dispose() }
    }
    Write-Report "Pack OK."
}
else { Write-Report "(pack skipped)" }

# --- final checklist ---------------------------------------------------------
Write-Report ""
Write-Report "=== Next steps (manual) ==="
Write-Report "  1. Review sync-gap-report.md and the git diff (sync verified byte-identical parity; the generated adapter is in OfficeTool.cs)."
Write-Report "  2. If the report lists new commands/view modes: add a template to update-vendor.ps1 (Commands + Code) — nothing else."
Write-Report "  3. Update NOTICE.md (version) if the release tag changed."
Write-Report "  4. Commit and push to Graphene-Lab/OfficeTool — the CI workflow publishes the NuGet package."
Write-Report "     (Hosts pick it up via PackageReference 1.* where the sibling project is absent; the package ships OfficeTool.dll + officecli.dll.)"
Write-Report "Done: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
