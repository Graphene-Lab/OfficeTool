# OfficeTool — Decision Log

Stable record of the significant design choices behind the OfficeTool adapter and the
vendor-update pipeline. **Read this before touching the code**: it explains WHY things
are the way they are, so a future change does not silently undo a considered decision.

Status legend: `[active]` = current behavior to preserve; `[superseded]` = replaced by a
later decision (kept for history).

---

## Architecture

### D1. Vendored engine as a separate Library project, adapter as a parasite
`[active]`
- Upstream `src/officecli` lives at `ExternalDependencies/officecli/` (742 files, byte-identical to
  the stable release), referenced by `OfficeTool.csproj` as a `ProjectReference` with
  `PrivateAssets="all"`.
- `OfficeTool.cs` is a MINIMAL adapter: state, Dispose, helpers, and the public surface block
  between `@@ADAPTER_SURFACE_BEGIN@@` / `@@ADAPTER_SURFACE_END@@` markers.
- **Why**: a vendor update = one command (`.\update-vendor.ps1`) that replaces the engine and
  regenerates the surface; no redundant copied code to merge by hand; the engine stays pristine
  (fidelity rule) so future upstream changes apply cleanly.
- **How to apply**: never edit the generated surface block by hand; change the method templates
  in `update-vendor.ps1` and re-run the pipeline.

### D2. Surface markers and template ownership
`[active]`
- The script regenerates ONLY the block between the markers; everything above `ADAPTER_SURFACE_BEGIN`
  (class summary, fields, helpers, Dispose) and below `ADAPTER_SURFACE_END` is hand-maintained.
- The method templates (signatures, bodies, XML docs) live in `update-vendor.ps1` (`$Methods`
  ordered hashtable, 37 entries). New vendor commands without a template → WARNING in
  `sync-gap-report.md` with the instruction "add a template".
- **Why**: the script is the single owner of "which methods to expose and how", so a vendor
  update needs no human judgment on the adapter's shape.

### D3. Deterministic surface analysis (`Get-CliSurface`)
`[active]`
- Commands are extracted from the vendored `CommandBuilder*.cs` by matching `new Command("x")`
  registrations plus the `Build*Command(jsonOption, "name")` factory names (e.g. mark/unmark/
  get-marks/goto in `CommandBuilder.Watch.cs`).
- View modes come from the literal `View mode:` comment in `CommandBuilder.View.cs`.
- `load_skill` presence is detected from the vendored sources.
- Only methods whose command/mode exists are emitted; the coherence checks fail loudly when a
  found command/mode has no template and no exclusion reason.
- **Why**: deterministic, version-agnostic — the same analysis works on any future release.

### D4. Logic → support classes, surface → script templates
`[active]`
- Non-trivial engine-facing logic lives in `AdapterSupport.cs` (hand-maintained, NEVER
  regenerated): `Set` find/replace merge + match-count, `Query` full pipeline
  (FilterSelector + MatchesTextFilter + FormatNodesCompact), `TranslateSkillSyntax`.
  Generated methods are thin: guard + `Exec` + one delegation call.
- **Why** (G1, 2026-08-15): a vendor change that breaks the logic surface must fail the BUILD
  stage of the pipeline (never silently drift); the script stays about surface, the code about
  behavior.

### D5. Accessing the engine
`[active]`
- The vendored `officecli.csproj` is converted Exe→Library and granted `InternalsVisibleTo`
  for `OfficeTool` + `OfficeTool.Tests` (the ONLY structural change to the vendor; the pristine
  upstream csproj is saved as `officecli.csproj.upstream`, gitignored, and used by the
  embedded-resource parity check).
- Watch*, TemplateMerger, SchemaHelpLoader, SkillInstaller, CommandBuilder, BatchTypes,
  OutputFormatter, HtmlScreenshot, ScrollResult are reached through internals.
- Private members (if ever needed) would use reflection. **Sandbox is preserved structurally**:
  every generated method resolves and reports paths via `SandboxPath.Resolve` / `ToAgent`.

### D6. Packaging
`[active]`
- `ProjectReference` + `PrivateAssets="all"` → the nuspec has NO `officecli` dependency.
- Both assemblies ship in the package via `TargetsForTfmSpecificContentInPackage`
  (the `BeforeTargets="GenerateNuspec"` hook is TOO LATE — `_LoadPackInputItems` runs first).
- Hosts (AIOffice, AgentBridge) copy `officecli.dll` into `Tools/OfficeTool/` so the
  ToolPluginHost `Resolving` fallback finds it (verified 9/9 dynamic load).
- `OfficeTool.csproj` uses the dual-reference pattern: ProjectReference when the sibling project
  exists, PackageReference `1.*` otherwise (CI uses the package).

### D7. Update flow
`[active]`
- `sync-from-upstream.ps1`: download release Source-code zip (gh + curl), replace the three
  vendored trees byte-identical (mirroring deletions via `sync-exclude.txt`), convert the csproj
  (idempotent), save `officecli.csproj.upstream`, run the SHA-256 parity check (officecli.csproj
  excluded: transformed), update `VENDOR.md` rows.
- `update-vendor.ps1`: sync → surface analysis → generation → coherence checks → build → harness
  (`--full`) → **agent-view** (`--agent-view`, added 2026-08-15) → pack.
- **Why**: no human intervention; the acceptance criterion is that the script alone produces a
  working, agent-facing adapter from any vendor release.

---

## Agent-facing contract

### D8. Conversational return values (string everywhere)
`[active]`
- Every surface method returns a narrative `string`: success messages, JSON, or `"Error: <cause>. <fix>. [valid values]"`.
- **Why**: the agent distinguishes outcome by the `Error:` prefix; a bare `bool` (or `true/false`)
  gives no cause and no fix (guide: "Conversational Return Values").
- Applied to `Create` (G2, 2026-08-15: `bool`→`string` + backup info) and `Open`
- (found by the agent-view check on 2026-08-15: was `bool`, now `"Opened '<path>'."` / `"Error: ..."`).

### D9. Sandbox transparency
`[active]`
- Agent-facing docs and messages say "workspace", NEVER "sandbox" — for the agent the paths ARE
  real (guide: "The sandbox is transparent to the agent").
- Generated artifacts (screenshots, HTML, exports) are written INSIDE the workspace
  (`/out/` when the method takes no path) and the agent is always told the path
  (G4, 2026-08-15: `ViewScreenshot` no longer writes to `%TEMP%`; `Open`'s param doc no longer
  mentions the sandbox).
- **Why**: mentioning the sandbox makes small models second-guess path validity and leaks
  implementation detail.

### D10. Method order
`[active]`
- The emission loop writes methods in REVERSE order (G3, 2026-08-15) so discovery methods
  (`Help`, `LoadSkill`, views) head the surface; the report line mirrors the file order.

### D11. Skill syntax translation (G5, 2026-08-15)
`[active]`
- `LoadSkill` passes returned content through `AdapterSupport.TranslateSkillSyntax`: a
  presentation-time rewrite of self-contained `officecli ...` CLI lines into method calls
  (`view <mode>` → `View<Mode>()`, `--prop k=v` ×N → `props: [...]`, `--depth/--find/--replace`
  mapped); shell lines (pipes, variables, continuations) stay byte-identical; a mapping note is
  prepended only when at least one line was translated. Vendor skill files are never modified.
- **Why**: the vendor skills are written for the officecli CLI; an agent following them literally
  would hit "command does not exist: view" — the translation bridges without touching fidelity.

### D12. Unwatch error convention (G10, 2026-08-15)
`[active]`
- `Unwatch()` without an active watch returns `"Error: No watch is running. Call Watch() first."`
  — ALL failures start with `Error:` (guide convention).

---

## Vendor parity decisions

### D13. Set find/replace (G1, 2026-08-15)
`[active]`
- `Set(path, props, find, replace)` exposes the vendor's canonical `--find/--replace`; the merge
  and match-count logic is in `AdapterSupport.Set` (parity with `CommandBuilder.Set.cs`:
  `find`/`replace` parameters and `find=`/`replace=` props entries are mutually exclusive;
  `LastFindMatchCount` reported; 0 matches → explicit warning).
- The script detects `set --find/--replace` in the vendor; if upstream drops them, the coherence
  check WARNs and the params degrade gracefully. `LastFindMatchCount` removal would fail the build.

### D14. Create Backup-Before-Write (G2, 2026-08-15)
`[superseded 2026-08-20 — replaced by git versioning (GitSupport/GitTool)]`
- `Create` over an existing file makes a numbered backup first (`CreateBackup`) and returns
  `"Created '<path>'. The previous version was backed up as '<name>'."`; `Restore()` recovers it.
- **Why**: guide policy "Backup-Before-Write"; the vendor CLI truncates, but an autonomous agent
  must never destroy content silently.
- **Superseded**: the `.NNN.bak` policy was replaced by version-on-save in the workspace git
  repo (`GitSupport.Snapshot`); rollback is centralized in the tool's `Restore(versionId)` and
  `GitTool.restore`. See AGENT_TOOLS_GUIDE.md → "Version-Before-Write".

### D15. Query full vendor parity (G11, 2026-08-15)
`[active]`
- `Query(selector, find, compact, fields)` delegates to `AdapterSupport.Query` running the
  vendor's exact pipeline: `AttributeFilter.FilterSelector` (boolean engine + Excel cell-alias
  resolver), `MatchesTextFilter` (find), `FormatNodesCompact` (compact + fields, xlsx → upstream
  "not supported" error). JSON envelope `{matches, results}` is the facade contract; `warnings`
  is additive (FilterDiagnostic → CliWarning mapping).
- **Why**: the original port (2026-08-13) had silently simplified `Query(string)` — a violation
  of full-parity. Vendor research (wiki `command-query`) confirmed `compact` is an agent-loop
  feature (observation-limit truncation + read-completeness footer), NOT a RAG/internal feature:
  keep it exposed. Docs include the deterministic decision pattern: read `matches` first, then
  `compact:true` for large sets.

### D16. Excluded commands
`[active]`
- `__resident-serve__`, `close`, `refresh` (server plumbing), `check`/`validate` overlap
  (validate kept), `watch`/`unwatch` exposed but desktop-gated (`IsWatchAllowed`),
  `help`→`Help` unified. See OfficePorting.md §3 for the full exclusion table and reasons.

### D19. Document protection gate + remove --shift (2026-08-15, alignment review)
`[active]`
- The vendored CLI blocks mutations of a protected .docx unless `--force`
  (`CheckDocxProtection` on add/set, `GetBatchProtectionBlock` on batch). The adapter
  calls the engine in-process and had NO gate — a protected document was silently editable.
  Replicated: `AdapterSupport.EnsureEditable(handler, path, force)` (in-memory, same message,
  same formfield/sdt editable-region exemptions, same "can't read protection → allow" fallback)
  wired into `Set`, `Add` and `Batch` (via the engine's internal `GetBatchProtectionBlock`,
  reachable through InternalsVisibleTo), each with a `force` parameter (vendor `--force`).
- `remove --shift left|up` (Excel single-cell shift-delete, `RemoveCellWithShift`) is now
  exposed on `Remove`; the old doc claimed "shift=left|up via props" but the handler ignored
  the prop — a deceiving doc, now fixed.
- Verified by the harness: protection engages (prop sticks), Set/Add/Batch blocked without
  force and allowed with force; remove shift moves the cell; bad paths → Error.

### D21. Skill/method type coherence (2026-08-15)
`[active]`
- The question "do the deferred features leave the agent confused?" found THREE real incoherences taught by the vendored material (skills + help schemas), now fixed:
  1. **`ViewSvg(int page)` → `ViewSvg(string? page)`**: the pptx skill teaches `view svg --start 3 --end 3` and the CLI page filter is a string ("3", "2-4" → first slide). The old int param made the G5 translation drop the slide (`ViewSvg()` → slide 1!) and made the CLI surface reject ranges. Now it takes the same string filter as ViewScreenshot (coherent types); the translator maps `--page/--start` → `ViewSvg("N")`.
  2. **`view screenshot --grid`** (contact-sheet visual pass) — taught by docx/pptx skills as the layout/pagination verification step; implemented via `AdapterSupport.ViewScreenshotGrid` (HTML-preview grid, pptx+docx, `grid: "auto"|N`; xlsx silently ignores grid like the vendor).
  3. **`get --save`** (binary extraction of picture/ole/media) — taught by the `picture` help schema; implemented as `Get(path, save: ...)` via `TryExtractBinary` (narrative "Extracted N bytes (MIME) to '<path>'.").
- Along the way a REAL sandbox gap surfaced and was fixed: `Add` picture/media/ole/video with `src=/file.png` (workspace path) was passed verbatim to the engine (which has no sandbox) → "file not found". The template now resolves `src`/`path` props through `SandboxPath.Resolve` for those types.
- Verification: harness 188/188 (picture add via workspace src → `get --save` extracts bytes + file exists; grid png-or-browser-error + invalid-grid Error; svg translation `ViewSvg("3")`; ViewSvg invalid page Error). The agent-view stage caught a regression the new Get doc introduced (raw `<path>` in `<returns>` broke the member XML → "Executes Get API call." fallback) — fixed with `&lt;path&gt;`, proving the stage's value again.
- **`view --page-count` closed (2026-08-15):** `ViewStats(pageCount: bool)` — tier 1: `WordPdfBackend.GetPageCount` (real Word repagination on Windows+Word, authoritative); tier 2: HTML preview paginator (`GetPageCountFromDom`, `<title>PAGES:N>`, approximate); both public engine APIs. Verified on this machine (no Word) via the HTML tier: `"pages":1` in the stats JSON. Harness check tolerant (pages field or clear Error). With this, ALL vendor options are either exposed or classified — the alignment review has no remaining "known minor gap" deferrals.

### D20. Alignment review tool (check-vendor-alignment.ps1, 2026-08-15)
`[active]`
- Lexically compares each vendored CommandBuilder option (`new Option<...>("--name")`) with the
  adapter method parameters (exact, alias, or camel prefix/suffix match) and writes
  `out/vendor-alignment.md` with a REVIEW list. It is a REVIEW TOOL, not a gate: the first run
  surfaced the REAL gaps (remove --shift, protection gate) plus a catalogue of transport/host
  plumbing that is excluded on purpose — each remaining flag is classified in the report
  (excluded-on-purpose / covered-by-design / known minor gap). `get --save` and `view --grid`
  started as "deferred" in this report and were promoted to covered (D21) once the skill/schema
  material showed they are taught to the agent.

---

## Verification

### D17. Agent-view test (2026-08-15)
`[active]`
- `OfficeTool.Tests --agent-view` dumps EXACTLY what the agent sees into
  `out/agent-view-api.md` (`Analyzer.GeToolDefinitions` — one JSON tool per method with XML
  docs) and `out/agent-view-cli.md` (`Terminal.GetToolPrompt` — the CLI-mode allowed-command
  block), and runs 82 deterministic checks: 37 methods present in both views, subcommand list
  complete, all returns string, no missing-summary fallback ("API call."), no sandbox mention,
  no stub markers, no C# type leaks, no host paths.
- The stage is part of `update-vendor.ps1` (after the harness). It caught the `Open:Boolean`
  regression on its first run (D8).
- **Why**: the pipeline must prove not just that it compiles, but that the AGENT's view is
  correct, useful and free of porting artifacts that would deceive it.

### D18. Harness workspace in %TEMP%
`[active]`
- `OfficeTool.Tests` runs in `%TEMP%` on purpose: the repo sits under OneDrive and test files
  written under the repo got cloud-synced on every Create/Save (the historical hour-long runs).
- The agent scenarios (`--agent`, `--agent-dashboard`) drive the REAL AgentHarness loop
  against DeepSeekBridge and verify the produced documents (deck slides, dashboard KPIs/charts/
  activeTab/tabColor).

---

## Environment gotchas (learned the hard way)

- PowerShell `@($null)` is a single-element array containing `$null` → template loops must filter
  with `| Where-Object { $_ }`.
- cmd.exe quoting: a `;`-chained `powershell -File ... > log 2>&1; echo ...` leaks the trailing
  tokens as positional script args (they land in `$UpstreamPath`). Run the pipeline without
  chaining; the tool/redirect captures output.
- PowerShell 5.1 reads `.ps1` without BOM as ANSI: literal non-ASCII in a script (e.g. `·`) gets
  written back mojibaked — keep patch scripts ASCII-only or use `[char]0xNN`.
- The edit/read tools can show a phantom state on the OneDrive-hosted `Program.cs` (an edit that
  "succeeded" was not persisted while read_file showed it applied). Verify with `findstr`/
  `Get-Content` after editing, and patch via a .NET script (`[IO.File]::WriteAllText` with the
  detected BOM) when the harness build behaves as if nothing changed.
