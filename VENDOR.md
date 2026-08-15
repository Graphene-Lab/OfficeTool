# VENDOR — OfficeTool (vendored OfficeCLI engine)

This repository vendors the engine of **OfficeCLI** (upstream repository
`iOfficeAI/OfficeCLI`) as a **separate Library project** that the OfficeTool
adapter references: the in-process document manipulation layer (Core + Handlers)
compiles into its own `officecli.dll`, without the CLI shell.

## Current sync

| Field | Value |
|---|---|
| Upstream repository | https://github.com/iOfficeAI/OfficeCLI |
| Upstream version | v1.0.144 |
| Upstream commit | 1ced45e900782c5083ed550ddf328ee974e425e7 |
| Sync date | 2026-08-15 |
| Upstream license | Apache-2.0 (see NOTICE.md) |

> The sync pipeline updates the *version*, *commit* and *date* rows above
> automatically — never edit them by hand.

## Vendored layout (mirrors upstream `OfficeCLI` repo root)

| Here | Upstream | Content |
|---|---|---|
| `ExternalDependencies/officecli/` | `src/officecli/` | entire project tree, byte-identical, **minus `Program.cs`** (the CLI entry point; the only allowed DELETE) |
| `skills/` | `skills/` | agent skills (embedded by the officecli csproj as `skills/…` resources) |
| `schemas/help/` | `schemas/help/` | help schemas (embedded as `schemas/help/…` resources) |

The vendored `officecli.csproj` is the upstream one with **one structural change**
applied by the sync: `OutputType` `Exe` → `Library` (+ removal of the console-only
publish props `PublishSingleFile`/`SelfContained`/`PublishTrimmed`/`CETCompat`) and an
`InternalsVisibleTo` grant to `OfficeTool`/`OfficeTool.Tests`. The embedded resources
stay wired exactly as upstream (same LogicalNames), so the engine resolves them
unchanged. The adapter (`OfficeTool.csproj` + `OfficeTool.cs`) references the engine
via `ProjectReference` and is **regenerated** by `update-vendor.ps1` from the
deterministic analysis of the vendored commands — it contains no engine code.

## Fidelity rules

1. **Zero modifications to vendored files.** No reformat, rename, "improvement" or
   inline fix: any divergence breaks the diff against upstream.
   - A fix/feature we need that upstream lacks → propose it **upstream first**, then
     bring it here with the next sync.
   - An unavoidable local workaround → isolate it in `patches/`, applied by the sync
     script, never mixed into vendored files.
2. **The only allowed operations on vendored files are DELETE and the csproj
   transform.** `Program.cs` (and whatever `sync-exclude.txt` lists) is deleted; the
   `officecli.csproj` is converted `Exe` → `Library` + `InternalsVisibleTo` (nothing
   else: the transform is regex-driven and never touches the EmbeddedResource blocks).
   A deleted file shows in `git diff`; a modified one does not.
3. **Version traceability**: the *Current sync* table records upstream version + commit.
   The value of a sync is that the next upstream release shows as a diff between two
   recorded versions.

## Sync source: the stable release, not the repository

The sync downloads the **"Source code (zip)" of the upstream GitHub release**
(`https://github.com/iOfficeAI/OfficeCLI/releases`), never the repository default
branch. This keeps the vendor on the **stable release** — no in-progress work, no
unreleased commits. The commit recorded in the table is the release's
`target_commitish` (the exact commit the tag points to).

## Sync procedure

### One-shot (mechanical)

```
.\sync-from-upstream.ps1                 # latest release
.\sync-from-upstream.ps1 -Tag v1.0.144   # pin a specific release
```

It downloads the release zip, vendors `src/officecli` → `ExternalDependencies/officecli`
/ `skills` / `schemas` (pruning files gone from the release), applies the csproj
transform, saves the pristine upstream csproj as
`ExternalDependencies/officecli/officecli.csproj.upstream` (gitignored, the
resource-parity reference), verifies **byte-identical parity** (SHA-256 of every
vendored file except the transformed csproj), updates the version/commit/date rows,
and prints `git diff --stat`.

### Full update (recommended) — vendor update + adapter generation

```
.\update-vendor.ps1                      # sync + analysis + generation + build + tests
.\update-vendor.ps1 -Tag v1.0.144        # pin a specific release
```

`update-vendor.ps1` is the **fully automatic** updater: after the sync it

1. **surface analysis** — parses the vendored `CommandBuilder*.cs` for the CLI commands
   (literal `new Command("x")` registrations + `Build*Command` factory names) and the
   view modes; this is the deterministic pass that decides **which methods the adapter
   must expose** (they can change between vendor versions);
2. **generation** — emits the adapter surface block (methods + XML docs) from the
   method templates embedded in the script (the adapter logic) into `OfficeTool.cs`
   between its `@@ADAPTER_SURFACE` markers; a method is emitted only when its command/
   mode exists in the vendored surface;
3. **coherence checks** — every found command/view-mode must be mapped (template,
   excluded-with-reason, or a NEW-command warning), the generated `LoadSkill` surface
   must match the unified contract, and the vendored csproj embedded-resource blocks
   must equal the pristine upstream ones;
4. **builds** the plugin (Release, surfaces engine API / adapter drift);
5. **runs** `OfficeTool.Tests` (the deterministic harness, docx/xlsx/pptx);
6. **packs** (`SkipNuGetPush`) and verifies the nupkg carries **both** assemblies
   (`OfficeTool.dll` + `officecli.dll`) with no `officecli` NuGet dependency.

Nothing is committed or pushed. After a green run:

1. Read `sync-gap-report.md` and the `git diff` (sync verified byte-identity).
2. If the report lists **new commands/view modes**: add a template to `update-vendor.ps1`
   (Commands + Code) — nothing else to touch.
3. Bump the version in `NOTICE.md` to the new release tag.
4. Commit and push to `Graphene-Lab/OfficeTool` — the CI workflow
   (`.github/workflows/publish.yml`) packs and publishes the NuGet package, which
   AIOrchestrator/AgentBridge hosts pick up via `PackageReference 1.*` where the
   sibling project is absent.

### Offline / troubleshooting

- `.\sync-from-upstream.ps1 -UpstreamPath <dir>` syncs from a local source tree
  (release zip extract or git checkout) without downloading.
- The parity check must report *"OK — N files byte-identical"*. A `DIFFERS`/`MISSING`
  line means a vendored file was hand-edited or the sync was interrupted — investigate
  before committing.

## Verification after a sync

- `dotnet build OfficeTool.csproj -c Release` — 0 errors.
- `dotnet run --project OfficeTool.Tests` — ALL TESTS PASSED.
- The parity line in the sync output — byte-identical.
- The nupkg content line — `OfficeTool.dll: True | officecli.dll: True`.
