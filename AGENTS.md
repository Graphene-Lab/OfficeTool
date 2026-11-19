# OfficeTool — notes for coding agents

> Read this file first. This repo is one tool plugin of the AIOffice solution: it is compiled on
> its own and loaded by the hosts from `Tools/OfficeTool/` at runtime.

## What this is

Office documents (DOCX, XLSX, PPTX) through a **vendored OfficeCLI engine**: path-based DOM
operations (get / query / set / add / remove), validate, batch, schema help, save/restore.

## Read before you edit

| If you touch… | Read first |
|---|---|
| anything | [PLUGIN-GUARDRAILS](../AIOrchestrator/docs-dev/PLUGIN-GUARDRAILS.md) — the contract shared by the 12 plugins; the file lives in the sibling AIOrchestrator repo (private), reachable from the solution checkout |
| the vendored engine | [VENDOR.md](VENDOR.md) and [NOTICE.md](NOTICE.md) — what is ours and what is not |
| a design choice already taken | [DECISIONS.md](DECISIONS.md) |
| the path/DOM surface | [OfficePorting.md](OfficePorting.md), [sync-gap-report.md](sync-gap-report.md) |
| a tool method or its XML docs | [AGENT_TOOLS_GUIDE](../AIOrchestrator/API/AGENT_TOOLS_GUIDE.md) |

## Non-negotiables

1. The class derives from `BaseAgentTool` and keeps
   `[ToolPurpose(ToolPurpose.Documents | ToolPurpose.Spreadsheets | ToolPurpose.Presentations)]` —
   it overlaps three single-purpose tools on purpose, and the host resolves the overlap.
2. Public methods and their XML docs **are** the agent's surface: no public method without docs,
   and a public method is never renamed (the model calls it by that name).
3. AnyCPU, no `RuntimeIdentifier`, `GenerateDocumentationFile` stays on.
4. The plugin folder never carries `AIOrchestrator.dll`; no state is written into `Tools/`.
5. **The engine is vendored, not ours.** A change to the engine goes through `ExternalDependencies/`
   and is recorded in `VENDOR.md`; do not patch it in place without reading that file.
6. A new metadata goes in a class attribute (or a `virtual` member with a default) — never an
   `abstract` member: the dlls already shipped must keep loading.

## Where things are

- `OfficeTool.cs` — the tool class; its public methods are what the model can call
- `skills/` — the `SKILL.md` files returned by `LoadSkill`, i.e. the working guidance the model reads
- `schemas/` — the document schemas the path/DOM surface validates against
- `ExternalDependencies/` — the vendored engine
- `OfficeTool.Tests/` — nested test project, excluded from the library compile

## Shipping

Publishes a GitHub release zip **and** a NuGet package; AgentBridge ships it in every release.
AIOffice does not build it into its dev `Tools/`.
