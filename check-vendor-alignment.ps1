<#
.SYNOPSIS
    Vendor alignment check: compares the options of each vendored officecli command with the
    parameters of the corresponding adapter methods, and writes a review report.

.DESCRIPTION
    For every CommandBuilder*.cs in the vendored engine:
      * extracts the command options (new Option<...>("--name") declarations);
      * maps the file to the adapter method(s) that implement those commands;
      * lists the adapter method parameters;
      * flags vendor options with no plausible adapter parameter (exact name, or a known
        alias) as "REVIEW" so a human can classify them: covered-by-doc / excluded-on-purpose
        / REAL GAP.

    Output: out/vendor-alignment.md (relative to the repo root).

.NOTES
    This is a REVIEW TOOL, not a gate: option extraction is lexical and some options are
    handled inside the engine rather than declared (e.g. --json), so a REVIEW flag is not
    automatically a bug. It exists to make the per-option parity check systematic instead of
    by-memory.
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$engine = Join-Path $root 'ExternalDependencies\officecli'
$adapter = Join-Path $root 'OfficeTool.cs'

# File -> adapter methods that implement the commands defined in that file.
$map = @{
    'CommandBuilder.Add.cs'            = @('Add', 'Remove', 'Move')
    'CommandBuilder.Batch.cs'          = @('Batch')
    'CommandBuilder.Check.cs'          = @('Validate')
    'CommandBuilder.Dump.cs'           = @('Dump')
    'CommandBuilder.GetQuery.cs'       = @('Get', 'Query')
    'CommandBuilder.Goto.cs'           = @('Goto', 'GetSelected')
    'CommandBuilder.Help.cs'           = @('Help')
    'CommandBuilder.Import.cs'         = @('Import', 'Create', 'Merge')
    'CommandBuilder.IntegrationStubs.cs' = @('(excluded: __resident-serve__)')
    'CommandBuilder.Mark.cs'           = @('Mark', 'Unmark', 'GetMarks')
    'CommandBuilder.Plugins.cs'        = @('LoadSkill')
    'CommandBuilder.Raw.cs'            = @('Raw', 'RawSet', 'AddPart')
    'CommandBuilder.Refresh.cs'        = @('(excluded: refresh)')
    'CommandBuilder.Save.cs'           = @('Save', 'Restore')
    'CommandBuilder.Set.cs'            = @('Set')
    'CommandBuilder.View.cs'           = @('ViewText', 'ViewAnnotated', 'ViewOutline', 'ViewStats', 'ViewIssues', 'ViewHtml', 'ViewSvg', 'ViewScreenshot', 'ViewForms', 'Validate')
    'CommandBuilder.Watch.cs'          = @('Watch', 'Unwatch')
}

# Known option -> adapter parameter name equivalences (option kebab-case vs param camelCase).
$aliases = @{
    'type' = 'type'; 'from' = 'from'; 'index' = 'index'; 'after' = 'after'; 'before' = 'before'
    'parent' = 'parentPath'; 'path' = 'path'; 'to' = 'to'; 'start-line' = 'startLine'
    'end-line' = 'endLine'; 'max-lines' = 'maxLines'; 'cols' = 'cols'; 'range' = 'range'
    'page' = 'page'; 'width' = 'width'; 'height' = 'height'; 'file' = 'filePath'
    'output' = 'outputPath'; 'template' = 'templatePath'; 'data' = 'dataJson'
    'commands' = 'commandsJson'; 'stop-on-error' = 'stopOnError'; 'format' = 'format'
    'header' = 'header'; 'start-cell' = 'startCell'; 'depth' = 'depth'; 'find' = 'find'
    'replace' = 'replace'; 'compact' = 'compact'; 'fields' = 'fields'; 'selector' = 'selector'
    'part' = 'partPath'; 'xpath' = 'xpath'; 'action' = 'action'; 'xml' = 'xml'
    'csv' = 'csvPath'; 'skill' = 'skill'; 'element' = 'element'; 'issue-type' = 'issueType'
    'limit' = 'limit'; 'all' = 'all'; 'props' = 'props'; 'port' = 'port'
    'shift' = 'shift'; 'force' = 'force'; 'prop' = 'props'
    'out' = 'filePath'; 'screenshot-width' = 'width'; 'screenshot-height' = 'height'
}

# Extract the option declarations from a file: new Option<...>("--name") and legacy "--name" keys.
function Get-Options([string]$Path) {
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $opts = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($text, 'new Option<[^>]+>\("--([a-z0-9-]+)"')) { $opts.Add($m.Groups[1].Value) }
    foreach ($m in [regex]::Matches($text, '"(?!--[a-z0-9-]+ )--([a-z0-9-]+)"')) { $opts.Add($m.Groups[1].Value) }
    return @($opts | Sort-Object -Unique)
}

# Extract the parameters of an adapter method (from the generated surface block).
function Get-Params([string]$Text, [string]$MethodName) {
    $m = [regex]::Match($Text, 'public (?:override )?string ' + [regex]::Escape($MethodName) + '\((.*?)\)\s*\{')
    if (-not $m.Success) { return @() }
    $params = @()
    foreach ($p in [regex]::Matches($m.Groups[1].Value, '([A-Za-z0-9_?\[\]]+)\s+([A-Za-z0-9_]+)(\s*=[^,)]*)?(?:[,)]|$)')) {
        if ($p.Groups[2].Value -eq 'this') { continue }
        $params += $p.Groups[2].Value
    }
    return @($params)
}

$adapterText = [IO.File]::ReadAllText($adapter, [Text.Encoding]::UTF8)
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('# OfficeTool — vendor alignment review (options per command vs adapter params)')
[void]$sb.AppendLine()
[void]$sb.AppendLine('Generated by check-vendor-alignment.ps1. REVIEW flags need a human classification:')
[void]$sb.AppendLine('covered-by-doc (the option is passed inside props or handled by the engine) /')
[void]$sb.AppendLine('excluded-on-purpose (server plumbing, no agent value) / REAL GAP (fix the template).')
[void]$sb.AppendLine()

$flags = @()
foreach ($file in ($map.Keys | Sort-Object)) {
    $path = Join-Path $engine $file
    if (-not (Test-Path $path)) {
        [void]$sb.AppendLine("## $file  (FILE MISSING in the vendored tree)")
        [void]$sb.AppendLine()
        continue
    }
    $opts = Get-Options $path
    $methods = $map[$file]
    [void]$sb.AppendLine("## $file -> $($methods -join ', ')")
    if ($opts.Count -eq 0) { [void]$sb.AppendLine('(no option declarations found)') }
    foreach ($opt in $opts) {
        # find a plausible adapter parameter across the mapped methods
        $found = $false
        foreach ($mn in $methods) {
            if ($mn.StartsWith('(')) { continue }
            foreach ($p in (Get-Params $adapterText $mn)) {
                if ($p -eq $opt) { $found = $true; break }
                if ($aliases.ContainsKey($opt) -and $aliases[$opt] -eq $p) { $found = $true; break }
                # fuzzy: camelCase(opt) as prefix (start -> startLine/startRow) or suffix
                # (type -> partType/issueType, data -> dataJson)
                $camel = ($opt -split '-') -join ''
                if ($p.StartsWith($camel, [StringComparison]::OrdinalIgnoreCase)) { $found = $true; break }
                if ($p.EndsWith($camel, [StringComparison]::OrdinalIgnoreCase)) { $found = $true; break }
                if ($opt -eq 'type' -and $p.EndsWith('Type')) { $found = $true; break }
            }
            if ($found) { break }
        }
        $status = if ($found) { 'OK' } else { 'REVIEW' }
        if ($status -eq 'REVIEW') { $flags += "$file --$opt" }
        [void]$sb.AppendLine("- \`--$opt\` -> $status")
    }
    [void]$sb.AppendLine()
}

[void]$sb.AppendLine("## REVIEW flags: $($flags.Count)")
foreach ($f in $flags) { [void]$sb.AppendLine("- $f") }
[void]$sb.AppendLine()
[void]$sb.AppendLine('## Notes')
[void]$sb.AppendLine('- Options like --json / --out / --page of view html are handled inside the engine or are covered by the method contract; a REVIEW flag here is the trigger to CHECK, not a verdict.')
[void]$sb.AppendLine('- Server plumbing (resident-serve, refresh, close) is intentionally not exposed (OfficePorting.md §3).')
[void]$sb.AppendLine()
[void]$sb.AppendLine('## Classification of remaining REVIEW flags (2026-08-15, verified against the vendored code)')
[void]$sb.AppendLine()
[void]$sb.AppendLine('| Option | Verdict | Why |')
[void]$sb.AppendLine('|---|---|---|')
[void]$sb.AppendLine('| batch --best-effort | excluded-on-purpose | CLI file-level atomicity (temp copy + promote) cannot map to an in-process open document; the adapter default (failures reported per item, execution continues) matches the vendor best-effort semantics and is documented in the Batch docs |')
[void]$sb.AppendLine('| batch --input | excluded-on-purpose | JSON-file/stdin source — transport plumbing; the agent passes commandsJson inline |')
[void]$sb.AppendLine('| dump --format / --out | excluded-on-purpose | output shape (json/jsonl) and file sink — the adapter always returns the batch-JSON envelope the agent consumes |')
[void]$sb.AppendLine('| get --save | excluded-on-purpose | writes the queried XML to a file; the adapter returns the data directly |')
[void]$sb.AppendLine('| help --help / --jsonl | excluded-on-purpose | System.CommandLine global plumbing |')
[void]$sb.AppendLine('| create/import --force | covered-by-design | "overwrite existing file" — the adapter Create does Backup-Before-Write instead (strictly safer, DECISIONS D14) |')
[void]$sb.AppendLine('| create --locale / --minimal | excluded-on-purpose | blank-doc baseline options; the adapter Create uses the vendor defaults (locale: null, minimal: false) |')
[void]$sb.AppendLine('| import --stdin | excluded-on-purpose | data-from-stdin transport; the agent passes a workspace CSV path |')
[void]$sb.AppendLine('| create --type | covered-by-design | the adapter infers docx/xlsx/pptx from the file extension |')
[void]$sb.AppendLine('| load_skill --fixture / --info | excluded-on-purpose | dev/debug options of the vendor skill loader |')
[void]$sb.AppendLine('| view --browser | excluded-on-purpose | open output in a browser — host UX plumbing, not an agent capability |')
[void]$sb.AppendLine('| view --render | excluded-on-purpose | native vs html screenshot path — host choice; the adapter uses auto (vendor default) |')
[void]$sb.AppendLine('| view --grid | covered (2026-08-15) | ViewScreenshot(grid: "auto"|N) — HTML-preview contact sheet for pptx/docx; taught by the docx/pptx skills as the visual verification pass, so it is implemented (AdapterSupport.ViewScreenshotGrid) |')
[void]$sb.AppendLine('| view --page-count | covered (2026-08-15) | ViewStats(pageCount: true) — Word repagination (Windows+Word) with HTML-preview fallback; "pages" field in the stats JSON |')
[void]$sb.AppendLine('| get --save | covered (2026-08-15) | Get(path, save: ...) extracts the binary payload (picture/ole/media) via TryExtractBinary; taught by the picture help schema, so it is implemented |')

$outDir = Join-Path $root 'out'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$out = Join-Path $outDir 'vendor-alignment.md'
[IO.File]::WriteAllText($out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('Alignment report written to ' + $out)
Write-Host ('REVIEW flags: ' + $flags.Count)
