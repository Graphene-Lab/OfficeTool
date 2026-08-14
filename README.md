# OfficeTool

Agent tool for Office documents (DOCX / XLSX / PPTX) used by [AIOrchestrator](https://github.com/Graphene-Lab/AIOrchestrator):
create/open, view (outline/text/annotated/stats/issues), path-based DOM get/query/set/add/remove/move/swap,
validate, batch, schema-driven help, template merge, save/restore — one document open at a time.

The class `AIOrchestrator.API.OfficeTool` is an **agent tool**: its public methods become
LLM-callable tools via reflection + XML docs (see `OfficePorting.md` and the
[Agent Tools Guide](https://github.com/Graphene-Lab/AIOrchestrator/blob/master/API/AGENT_TOOLS_GUIDE.md)).

It is a **plugin**: hosts load it dynamically from their `Tools/` folder (startup scan +
hot-add watcher) — see the plugin architecture doc shipped with AIOffice
(`Tools/ToolPluginArchitecture.md`). It also ships as the NuGet package `Graphene.OfficeTool`
for hosts that reference tools statically (e.g. AgentBridge).

## Engine: vendored OfficeCLI

The document engine (`OfficeCli.Core` + `OfficeCli.Handlers`) is vendored byte-identical from
the [OfficeCLI](https://github.com/iOfficeAI/OfficeCLI) project (Apache-2.0) and compiles into
the same assembly — deterministic JSON output, path-based addressing (`/slide[1]/shape[2]`),
schema-driven property validation, template merge, dump/batch round-trip and HTML rendering,
without the CLI shell.

Do **not** edit files under `src/officecli/`: they are upstream-copied (fidelity rules in
`VENDOR.md`). The only allowed operation is DELETE (`Program.cs`, `sync-exclude.txt`).

## Quick start (library use)

```csharp
using OfficeCli.Handlers;               // DocumentHandlerFactory
using OfficeCli.Core;                   // IDocumentHandler, CliException

using var handler = DocumentHandlerFactory.Open("/tmp/report.docx", editable: true);
var outline = handler.ViewOutline();
var json    = handler.Get("/body/p[1]", depth: 1);
handler.Set("/body/p[1]", new Dictionary<string, object?> { ["bold"] = "true" });
handler.Save();
```

## Updating from upstream

The vendor tracks the **stable release** (the "Source code (zip)" asset of
`https://github.com/iOfficeAI/OfficeCLI/releases`), never the repository branch.

```
.\update-vendor.ps1                 # latest release: sync + gap analysis + build + tests
.\update-vendor.ps1 -Tag v1.0.144   # pin a specific release
```

The updater vendors the release byte-identical, reports any CLI command that has no
`OfficeTool` method yet (`sync-gap-report.md`), verifies embedded-resource parity, builds the
plugin and runs the `OfficeTool.Tests` harness. Nothing is committed or pushed — review, fix
reported gaps, then commit (CI publishes the NuGet package). Full procedure: `VENDOR.md`.

## Repository layout

| Path | Content |
|---|---|
| `OfficeTool.cs` | the agent tool class (`AIOrchestrator.API.OfficeTool`) |
| `src/officecli/` | vendored engine, byte-identical to upstream (minus `Program.cs`) |
| `skills/` | agent skills (embedded `skills/…` resources) |
| `schemas/help/` | help schemas (embedded `schemas/help/…` resources) |
| `OfficeTool.Tests/` | deterministic end-to-end harness (docx/xlsx/pptx) |
| `OfficePorting.md` | porting guide: officecli → OfficeTool methods |
| `VENDOR.md` | upstream sync procedure + fidelity rules |
| `sync-from-upstream.ps1`, `update-vendor.ps1`, `sync-exclude.txt` | vendor update tooling |
| `NOTICE.md` | Apache-2.0 attribution for the vendored engine |
