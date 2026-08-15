# OfficePorting — Linee guida per convertire officecli in OfficeTool.cs

> **Aggiornamento 2026-08-14 — OfficeTool è un adapter minimale.** L'engine vendored
> NON è più compilato nello stesso assembly del plugin: `ExternalDependencies/officecli`
> è un **progetto Library separato** (sempre dentro il repo, ProjectReference da
> `OfficeTool.csproj` con `PrivateAssets=all`). Lo script di sync converte il
> `officecli.csproj` upstream da console a Library (`OutputType` + `InternalsVisibleTo`
> a `OfficeTool`/`OfficeTool.Tests`) — l'unica modifica strutturale al vendor, che
> altrimenti resta byte-identical. `OfficeTool.cs` è ora il **minimal adapter**: stato
> (handler/watch/backup), `Dispose`, helper e niente codice engine; la **superficie
> public (metodi + XML docs) è rigenerata da `update-vendor.ps1`** in modo
> deterministico: analisi dei comandi CLI del vendor (`CommandBuilder*.cs` + view
> modes + `load_skill`) → template dei metodi incorporati nello script → blocco tra i
> marcatori `@@ADAPTER_SURFACE_BEGIN/END`. Un metodo viene emesso solo se il suo
> comando/modo esiste nel vendor; comandi nuovi senza template finiscono nel report.
> L'adapter accede agli internal dell'engine via `InternalsVisibleTo` (Watch*,
> TemplateMerger, SchemaHelpLoader, SkillInstaller, CommandBuilder, BatchTypes...) e,
> se un domani servisse un membro privato, via reflection — il confine sandbox
> (`SandboxPath.Resolve`/`ToAgent`) è preservato in ogni metodo generato.

> **Aggiornamento 2026-08-14 — OfficeTool è un plugin.** `OfficeTool.cs` non vive più in
> `AIOrchestrator\API`: è migrato nel repo `Graphene-Lab/OfficeTool` (pacchetto NuGet
> `Graphene.OfficeTool`), caricato dinamicamente dalla cartella `Tools/` degli host
> (stesso pattern di WordTool/SpreadsheetTool). L'engine vendored non è più un progetto
> separato (`OfficeCliEngine`, repo e pacchetto eliminati): `src/officecli/**` e
> `OfficeTool.cs` compilano in **una sola assembly** (`OfficeTool.dll`), quindi gli
> InternalsVisibleTo verso AIOrchestrator non servono più (resta solo `OfficeTool.Tests`).
> Le decisioni §1-§13 restano valide come storia del porting; l'updater semi-automatico
> ora è `update-vendor.ps1` ("Vendor to OfficeTool (plugin) updater", §11 fase 5).

Documento di pianificazione: come portare il tool CLI [OfficeCLI](https://github.com/iOfficeAI/OfficeCLI)
(v1.0.143, sorgente in `Sorgenti\OfficeCLI`) nel formato agente del nostro sistema
(una singola classe `OfficeTool.cs` in `AIOrchestrator\API`, secondo
[AGENT_TOOLS_GUIDE.md](AGENT_TOOLS_GUIDE.md)).

Scopo del porting: dare all'agente l'intera superficie Office (docx + xlsx + pptx)
— lettura, editing DOM, rendering, formule/pivot, merge, dump — come metodi
tipizzati di una classe, **senza perdere nulla della documentazione testata di
officecli**. La documentazione di officecli è ciò che permette all'agente di
lavorare: va mantenuta fedele, non riscritta.

---

## 1. Architettura a confronto

| Concetto officecli | Dove vive in officecli | Equivalente nel nostro sistema |
|---|---|---|
| Comando CLI (`create`, `get`, `set`, ...) | `Program.cs` + `CommandBuilder*.cs` (System.CommandLine) | Metodo pubblico di `OfficeTool` (chiamato via reflection da `CallMethod`) |
| Opzioni (`--path`, `--depth`, `--prop key=value`) | parametri del comando | Parametri tipizzati del metodo (`<param>` docs) |
| Descrizioni testuali interne | schemi JSON in `schemas/help/<fmt>/<element>.json` (embedded) + stringhe `Description` dei comandi | XML docs di classe/metodo/parametro + metodo `Help(format, element)` che restituisce lo schema JSON originale |
| Output `--json` deterministico | `OutputFormatter` / `DocumentNode` (get/query/view) | Stringhe di ritorno con formato JSON documentato in `<returns>` |
| Codici errore + suggerimenti (`CliException`: `Code`, `Suggestion`, `ValidValues`, `Help`) | `Core/CliException.cs`, lanciati dai handler | Stringhe `"Error: <causa>. <fix>. [alternativa]"` (politica AGENT_TOOLS_GUIDE) |
| Motore documenti (WordHandler/ExcelHandler/PowerPointHandler) | `Handlers/*`, interfaccia `IDocumentHandler`, factory `DocumentHandlerFactory.Open(file, editable)` | Engine riusato così com'è (v. §2), NON riscritto |
| Path-based addressing (`/slide[1]/shape[2]`, `@id=`, selettori) | `Core/Selector*.cs`, `PathIndex.cs` | Identico, passato come parametro stringa (`path`, `selector`) |
| Resident mode (documento in memoria, flush a richiesta) | `ResidentServer/ResidentClient` | Stato dell'istanza: UN documento aperto alla volta, `Save()` esplicito + backup |
| `--help` / `help <fmt> <element>` | `Help/SchemaHelp*.cs` + schemi embedded | `Help(format, element)` + definizioni tool generate da reflection |
| `view html`/`screenshot` (rendering) | `Core/Rendering/*`, `HtmlPreview*`, `HtmlScreenshot` | `ViewHtml(...)` / `ViewScreenshot(...)` (scrittura file nel sandbox) |
| Batch (`batch`) | `Core/BatchExecutor.cs` — entry point pubblico **pensato apposta per host in-process** | `Batch(string commandsJson, bool stopOnError = false)` — applica in memoria, `Save()` persiste; mantenuto per coerenza con la documentazione portata (§3) |
| Watch / goto / get selected / mark | `CommandBuilder.Watch.cs` + `Core/Watch/*` + server HTTP | `Watch`/`Unwatch`/`Goto`/`GetSelected`/`Mark` — **SOLO sessione desktop locale** (§3, gating `isLocalUserInOsDesktop`); server: `Core/Watch/*` vendored |
| MCP / install / config / plugins | vari | Escluso (operazioni di sistema, non dell'agente) |
| load_skill | `SkillInstaller.cs` (embedded) | **`LoadSkill(string? skill = null)`** — unico tool: null→catalogo, `/skill/relpath`→file bundled, nome→SKILL.md (§ decisione `load_skill`) |

### Punti di fedeltà non negoziabili

- **Indicizzazione 1-based nei path** (`/slide[1]`, `/body/p[3]`). I path documento
  sono coordinate del documento, non percorsi filesystem. Non normalizzare a 0-based:
  è parte della semantica testata e della documentazione.
- **Sintassi `--prop key=value`** → parametro `string[] props` con voci `"key=value"`
  (v. §4). Gli esempi degli schemi sono già in questa forma: `["lineSpacing=14pt",
  "lineRule=atLeast"]`.
- **Formati valori** (colori `FF0000`/`red`/`accent1`, dimensioni `2cm`/`1in`/`72pt`/EMU,
  spaziature `1.5x`/`150%`): restano validi come in CLI — lo schema `Help()` li documenta.
- **Alias delle proprietà** (es. `align` ≡ `alignment` ≡ `halign`, `style` ≡ `styleId`
  ≡ `styleName`): accettarli tutti in `props`, come fa la CLI.
- **1-based nei path vs 0-based in `--index`** di `add` (legacy): mantenere entrambi
  come da CLI e documentarli nel `<param>`.

---

## 2. Decisione di integrazione (come riusare l'engine)

L'engine di officecli è enorme, ben testato e sotto contratto di test sugli schemi
(`schemas/README.md`: ogni claim `add`/`set`/`get`/`readback` è verificato contro gli
handler). **Non va reimplementato.** Tre opzioni:

| Opzione | Pro | Contro |
|---|---|---|
| **A. ProjectReference locale a `Sorgenti\OfficeCLI\src\officecli`** (progetto Exe, net10.0 — compatibile con AIOrchestrator/AIOffice, entrambi net10.0) | Zero copie; gli aggiornamenti a monte fluiscono; `OfficeTool` usa `DocumentHandlerFactory` + `IDocumentHandler` direttamente | Trascina l'intero assembly: System.CommandLine 3.0.0-preview, risorse embedded (preview css/js, skills, schemi), infra plugin/resident non necessaria; **il pack NuGet di AIOrchestrator** (Graphene.AIOrchestrator) avrebbe bisogno di officecli come dipendenza — ma officecli non è su NuGet |
| **B. Vendor dell'engine in un progetto library dedicato `OfficeCliEngine`** (sibling di AIOrchestrator, es. `Sorgenti\OfficeCliEngine`: **intero albero upstream byte-identical, unico DELETE ammesso = `Program.cs`**; `System.CommandLine` preview resta nel grafo perché `CommandBuilder*`/`Resident*` sono intrecciati a `Core`/`Handlers` e non si possono eliminare senza modificare file vendored) | Build e pack NuGet di AIOrchestrator restano autosufficienti (stesso pattern dual-reference dei fratelli); sync triviale (copia tutto); nessuna modifica ai file vendored | Fork da mantenere (script di sync); assembla anche codice CLI morto (CommandBuilder, Resident, McpServer) + System.CommandLine preview nel grafo dipendenze (~+1 dipendenza) |
| C. Subprocess del binario officecli | Nessuna modifica all'engine | Lento (spawn per chiamata), mappatura path sandbox fragile, dipendenza da binario esterno, doppio parsing — **escluso** |

**Decisione: B** — vendor in un progetto library dedicato **`OfficeCliEngine`**
(sibling di AIOrchestrator, es. `Sorgenti\OfficeCliEngine`), referenziato da
AIOrchestrator con il pattern dual-reference già usato per
UISupportGeneric/MermaidRendering: ProjectReference quando il progetto locale esiste
(build di soluzione), PackageReference (`OfficeCliEngine` 1.*) come fallback per
build/CI senza sorgenti. Il progetto espone solo `Core` + `Handlers` (+ risorse
embedded), niente layer CLI; va pubblicato su NuGet seguendo il pipeline esistente
(versione datata + NuGetApiKey).

### Fedeltà al vendor e sync con upstream (requisito)

Il progetto `OfficeCliEngine` deve essere **fedele all'originale**: i file vendored
restano **byte-identical** all'upstream, così gli aggiornamenti loro sono individuabili
con un semplice `git diff` sul nostro codice. Regole:

1. **Zero modifiche ai file vendored.** Nessun reformat, rinomina, "miglioria" o fix
   inline nei file copiati: qualunque divergenza romperebbe il diff con upstream.
   - Un fix/feature che serve a noi e manca a loro → va proposto **upstream prima**
     (l'engine è Apache-2.0 e pubblico), poi arriva nel vendor col prossimo sync.
   - Un workaround locale inevitabile → **isolato in un unico file-patch separato**
     (`patches/`) applicato a ogni sync, mai disperso nei file copiati.
2. **Le uniche operazioni ammesse sui file vendored sono di tipo DELETE** (di fatto
   uno solo: `Program.cs`, l'entry point CLI che forza OutputType Exe). Un file
   cancellato è immediatamente visibile nel diff; un file modificato no. Lista di
   esclusione esplicita in `sync-exclude.txt`. Verificato alla Fase 0: il resto del
   layer CLI (CommandBuilder*, Resident*, McpServer, McpInstaller, Help/) NON è
   eliminabile — è referenziato da `Core`/`Handlers` (ResidentServer↔CommandBuilder↔
   Core/Plugins↔DocumentHandlerFactory) e toglierlo richiederebbe modificare file
   vendored, vietato dalla regola 1. Resta nel build come codice inerte; il runtime
   non lo usa (nessun plugin installato, nessuna resident mode avviata).
3. **Tracciabilità della versione**: `VENDOR.md` nella radice del progetto registra
   upstream + versione + commit hash, es.
   `synced from iOfficeAI/OfficeCLI v1.0.143 (commit <sha>) on <date>` — il valore
   di sync è *"il prossimo aggiornamento loro si vede come differenza tra due versioni
   registrate"*.
4. **Script di sync**: `sync-from-upstream.ps1` scarica lo **"Source code (zip)" della
   release stabile** di GitHub (`https://github.com/iOfficeAI/OfficeCLI/releases`,
   mai il ramo default del repo), vende `src/officecli` (meno `sync-exclude.txt`),
   `skills`, `schemas/help` byte-identical, elimina i file spariti dalla release,
   verifica la **parità byte-identical** (SHA-256 di ogni file venduto), aggiorna
   le righe versione/commit/data di `VENDOR.md` e mostra `git diff --stat`.
   Il commit registrato è il `target_commitish` della release (l'hash esatto del tag).
   - **`update-officecli.ps1`** è l'updater semi-automatico completo: sync + **gap
     analysis** (ogni comando CLI della doc venduta deve avere un metodo in
     `OfficeTool` — v. §3; report in `sync-gap-report.md`) + parità risorse embedded
     (csproj upstream vs nostro) + build engine e AIOrchestrator + harness
     `OfficeTool.Tests` + pack di verifica. Non committa né pusha: il report guida
     le azioni manuali (nuovi metodi, NOTICE.md, commit → CI pubblica NuGet).
   - Eseguito anche come **verifica anti-deriva** prima di ogni release dell'engine
     (opzione "sync → diff vuoto = vendored aggiornato").
5. **Verifica dopo ogni sync**: build + harness `OfficeTool.Tests` + confronto
   `--output-schema-crc` di officecli con gli schemi embedded del vendor (nessuna
   deriva degli schemi help tra upstream e vendor).
6. **NOTICE.md** (nel pack) cita versione/commit upstream: la provenienza resta
   tracciabile anche fuori dal repo.

Risultato: un nuovo release upstream si porta nel vendor in 3 passi (script sync →
`git diff` → test), e le modifiche nostre rispetto a loro sono **sempre zero o un
patch isolato**, mai nascoste dentro file copiati.

### Template csproj di OfficeCliEngine (versione automatica + pipeline NuGet)

Stesso meccanismo di AllToMarkdown/UISupportGeneric/AIOrchestrator (versione datata
`1.yy.MM.dd` + push NuGet con `NuGetApiKey`, `--skip-duplicate`):

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <OutputType>Library</OutputType>
    <RootNamespace>OfficeCli</RootNamespace>   <!-- namespace originali dell'engine: i nomi logici delle risorse embedded e i reference nel codice restano validi -->
    <AssemblyName>OfficeCliEngine</AssemblyName>
    <PackageId>OfficeCliEngine</PackageId>
    <Description>Vendored OfficeCLI engine (Apache-2.0, upstream iOfficeAI/OfficeCLI): Core + Handlers for in-process Office document manipulation (.docx/.xlsx/.pptx).</Description>
    <PackageTags>office;docx;xlsx;pptx;openxml;agent;document</PackageTags>
    <Authors>Andrea Bruno</Authors>
    <RepositoryUrl>https://github.com/Graphene-Lab/AIOffice</RepositoryUrl>
    <PackageLicenseFile>NOTICE.md</PackageLicenseFile>   <!-- attribuzione Apache-2.0 upstream, v. sotto -->
    <PackageReadmeFile>README.md</PackageReadmeFile>
    <PackageRequireLicenseAcceptance>False</PackageRequireLicenseAcceptance>
    <Copyright>Andrea Bruno</Copyright>
    <Configurations>Debug;Release;Test</Configurations>
    <Version>$([System.DateTime]::Now.ToString("1.yy.MM.dd"))</Version>
    <GenerateDocumentationFile>True</GenerateDocumentationFile>
  </PropertyGroup>

  <ItemGroup>
    <!-- come officecli (3.4.1); NuGet unifica verso l'alto col 3.5.1 di AIOrchestrator — verifica di Fase 0: l'engine deve compilare contro la versione unificata -->
    <PackageReference Include="DocumentFormat.OpenXml" Version="3.4.1" />
  </ItemGroup>

  <!-- risorse embedded con i nomi logici che l'engine già usa (schemi help per Help(), template effetti, preview/watch, skills) -->
  <ItemGroup>
    <EmbeddedResource Include="schemas\help\**\*.json" LogicalName="schemas/help/%(RecursiveDir)%(Filename)%(Extension)" />
    <EmbeddedResource Include="Resources\preview.css" />
    <EmbeddedResource Include="Resources\preview.js" />
    <EmbeddedResource Include="Resources\watch-sse-core.js" />
    <EmbeddedResource Include="Resources\watch-overlay.js" />
    <EmbeddedResource Include="Resources\chartex-colors.xml" />
    <EmbeddedResource Include="Resources\chartex-style.xml" />
    <EmbeddedResource Include="Handlers\Pptx\EffectTemplates\*.xml">
      <LogicalName>OfficeCli.Handlers.Pptx.EffectTemplates.%(Filename)%(Extension)</LogicalName>
    </EmbeddedResource>
    <EmbeddedResource Include="skills\**\*" LogicalName="skills/$([System.String]::Copy('%(RecursiveDir)').Replace('\','/'))%(Filename)%(Extension)" />
  </ItemGroup>

  <!-- I tre target di AllToMarkdown.csproj (§317-345), verbatim:
       SetPackageVersion (DependsOnTargets="Build") → PackageVersion=$(Version)
       CleanOldNuGetPackages (BeforeTargets="GenerateNuspec") → svuota $(PackageOutputPath)
       PublishPackageToNuGet (AfterTargets="Pack", Condition="'$(SkipNuGetPush)' != 'true'")
         → Error se NuGetApiKey manca, push --skip-duplicate su $(NuGetSource) -->
</Project>
```

Note:
- **Namespace originali**: `RootNamespace`/`AssemblyName` diversi ma i namespace del
  codice restano `OfficeCli.*` (non rinominare): le LogicalName delle risorse
  (`OfficeCli.Resources.*`, `OfficeCli.Handlers.Pptx.EffectTemplates.*`) e i reference
  interni al codice dipendono da quelli.
- **NOTICE.md** nel pack: attribuzione Apache-2.0 — provenienza iOfficeAI/OfficeCLI
  v1.0.143, NOTICE upstream + link licenza.
- **CI**: `.github/workflows/publish.yml` copiato da AllToMarkdown (pack `-c Release
  -p:SkipNuGetPush=true` + `dotnet nuget push --api-key ${{ secrets.NUGET_API_KEY }}
  --skip-duplicate` su push a master), puntando a `OfficeCliEngine.csproj`.
- **Dual-reference in AIOrchestrator**, come gli altri fratelli:
  ```xml
  <ProjectReference Include="..\OfficeCliEngine\OfficeCliEngine.csproj" Condition="Exists('..\OfficeCliEngine\OfficeCliEngine.csproj')" />
  <PackageReference Include="OfficeCliEngine" Version="1.*" />
  ```

Qualunque opzione: l'uso in-process è pulito perché i metodi di `IDocumentHandler`
restituiscono stringhe/`JsonNode`/liste (nessun `Console.Write` negli handler — la
stampa vive solo nel layer CommandBuilder, che non riusiamo).

---

## 3. Mappatura comandi → metodi

**Principio di coerenza superficie ↔ documentazione.** Portiamo fedelmente la
documentazione (schemi + skill); quindi **ogni comando che la documentazione portata
menziona all'agente deve esistere come metodo** (e viceversa). Un comando citato senza
metodo = l'agente lo invoca e riceve "unknown method": workflow rotto e token sprecati,
contro lo spirito self-healing. Questo principio determina cosa si tiene:
- `batch` → **si tiene** (citato nelle skill come verbo di prima classe: *"The verbs:
  add/set/remove/move/swap/batch"*, *"use batch for repetitive shape grids"*, *"≤50
  ops/block"*). L'engine lo fornisce già per host in-process (`Core/BatchExecutor`).
- `watch`/`goto`/`selected`/`mark` → **si tiene**, gated desktop (§3.1).
- `load_skill` → **si tiene** come `LoadSkill(name)` (skill specializzate embedded),
  oppure le menzioni si eliminano dalla doc portata — da decidere (v. sotto).
- `mcp`/`install`/`config`/`plugins` → si **eliminano** dalla doc portata: sono comandi
  d'ambiente (rivolti all'operatore, non all'agente), non compaiono nella documentazione
  che l'agente usa per lavorare sui documenti.
- `refresh` → candidato fase 3 (Word backend).

### Batch (mantenuto)

| Comando | Metodo | Note |
|---|---|---|
| `batch <file> [--commands/--input/stdin]` | `Batch(string commandsJson, bool stopOnError = false)` | Applica N operazioni in un colpo. Semantica resident di officecli: gli item si applicano **in memoria** sull'istanza aperta, ogni item riporta successo/fallimento con code, `Save()` persiste. Nessuna copia temporanea/atomicità: nel nostro modello nulla viene scritto finché non si chiama `Save()` |

Il `<param>` di `commandsJson` documenta la forma dell'item esattamente come la
descrizione CLI originale: `{"command":"set","path":"/Sheet1/A1","props":{...}}`,
verbi `add/set/get/query/remove/move/swap/view/raw/raw-set/validate`, campi
`parent`/`path`/`selector`/`type`/`props`/`to`/`after`/`before`/`path2`. La
semantica per-item (fail → code + errore, `stopOnError`) è identica; il `<returns>`
documenta il riepilogo `N succeeded, M failed`.
Implementazione: `BatchExecutor.ExecuteBatch(handler, itemsJson, json: true, stopOnError)`
(già in `Core`, pensato per host in-process).

### load_skill (decisione)

`load_skill <name>` carica le skill specializzate (pitch-deck, financial-model,
academic-paper, ...) che la SKILL.md dice di caricare *"once, then proceed"*. Le skill
sono risorse embedded in officecli (`skills/*`, incluse nel vendor). Due strade:
- **Tenere**: `LoadSkill(...)` restituisce il contenuto della skill — fedeltà
  totale, l'agente segue i workflow specializzati come in CLI.
- **Tagliare**: si eliminano dalla doc portata le menzioni alle skill specializzate
  (il comportamento sui documenti resta identico, si perde solo la guida di dominio).

**Superficie unificata (2026-08-14)** — un solo metodo, come il vendor (che ha un
solo comando `load_skill` con path opzionale; il nome segue lo standard Agent Skills
di Anthropic/Microsoft, non è casuale):
- `LoadSkill(null)` → **catalogo** di tutte le skill (nome + a cosa serve) — l'help del
  parametro omesso, identico a `load_skill` senza argomenti del vendor
- `LoadSkill("pitch-deck")` → SKILL.md + manifest (lookup nella `SkillMap`)
- `LoadSkill("/pitch-deck/reference/guide.md")` → file di riferimento DENTRO la skill
  (primo segmento = nome pubblico skill → `SkillMap`, resto = relativo; protezioni
  anti-traversal del motore: no `..`, no path assoluti, binari rifiutati)
- `LoadSkillFile`/`ListSkills` **non** sono esposti come tool separati (il motore li
  tiene interni); `ListSkills` è coperta dal catalogo su `null`.

La base class `BaseAgentTool` fornisce un `LoadSkill` virtual con strategia universale
per i tool senza skill; `OfficeTool` lo sovrascrive (vedi `BaseAgentTool.cs`).

Classe: `public class OfficeTool : BaseAgentTool, IDisposable, ILocalDesktopCapable, IFileTool` in `AIOrchestrator\API`.

### L1 — Lettura semantica

| Comando officecli | Metodo | Note |
|---|---|---|
| `create <file>` | `Create(string filePath)` | Anche `OpenOrCreate`? No: tenere separati come in officecli |
| `open <file>` | `Open(string filePath)` | Resident ⇒ stato dell'istanza; sostituisce il documento corrente |
| `close <file>` / `save` | `Save()` / `Restore()` | Flush su disco + backup numerato (pattern SpreadsheetTool) |
| `view <file> outline` | `ViewOutline()` | Ritorna JSON strutturato |
| `view <file> text` | `ViewText(int? startLine = null, int? endLine = null, int? maxLines = null, string[]? cols = null, string? range = null)` | `range` solo xlsx (`Sheet1!A1:C10`) — come da guard `ViewRangeGuard` |
| `view <file> annotated` | `ViewAnnotated(...)` | |
| `view <file> stats` | `ViewStats()` | |
| `view <file> issues` | `ViewIssues(string? issueType = null, int? limit = null)` | `--type format\|content\|structure` |
| `view <file> html -o out.html` | `ViewHtml(string? filePath = null)` | Scrive HTML nel sandbox, ritorna il path agente |
| `view <file> svg` | `ViewSvg(int page = 1)` | SVG della slide pptx (ispezione geometria) — solo pptx |
| `view <file> screenshot -o out.png --page N` | `ViewScreenshot(string? filePath = null, int? page = null)` | Richiede browser Chrome-family |
| `view <file> forms` | `ViewForms()` | Content control/form fields del docx come JSON — solo docx |
| `validate` | `Validate()` | Ritorna errori OOXML |

### L2 — DOM

| Comando | Metodo |
|---|---|
| `get <file> <path> --depth N` | `Get(string path, int depth = 1)` |
| `query <file> <selector>` | `Query(string selector, string? find = null, bool compact = false, string? fields = null)` — parità totale: `--find` (filtro testo), `--compact` (formato riga) e `--fields` (colonne extra) implementati via `AdapterSupport.Query` sullo stesso motore del vendor (`AttributeFilter.FilterSelector` + `FormatNodesCompact`); envelope JSON `{matches, results, warnings?}` |
| `set <file> <path> --prop ...` | `Set(string path, string[]? props = null, string? find = null, string? replace = null)` |
| `add <file> <parent> --type T --prop ... [--after/--before/--index/--from]` | `Add(string parentPath, string type, string[]? props = null, string? after = null, string? before = null, int? index = null, string? from = null)` |
| `remove <file> <path>` | `Remove(string path, string[]? props = null)` (`--shift left\|up` xlsx) |
| `move <file> <path> [--to/--index/--after/--before]` | `Move(string path, string? to = null, int? index = null, string? after = null, string? before = null)` |
| `swap <file> <p1> <p2>` | `Swap(string path1, string path2)` |

**Perché un `Set` generico e non metodi tipizzati per elemento?** La superficie
proprietà è enorme (es. `schemas/help/docx/paragraph.json` è 1631 righe). Inlineare
tutto negli XML docs esploderebbe il prompt (viola la regola MIN-MAX). Il `Set`
generico + `Help()` preserva **al 100%** le descrizioni originali al momento del
bisogno, con zero drift.

### L3 — Raw XML

| Comando | Metodo |
|---|---|
| `raw <file> <part>` | `Raw(string partPath)` |
| `raw-set <file> <part> --xpath --action --xml` | `RawSet(string partPath, string xpath, string action, string? xml = null)` |
| `add-part <file> <parent>` | `AddPart(string parentPath, string partType, string[]? props = null)` |

### Documentazione runtime

| Comando | Metodo |
|---|---|
| `help <fmt> <element>` | `Help(string? format = null, string? element = null)` |

`Help()` legge lo schema JSON embedded (`schemas/help/...`, risorse dell'assembly
engine) e lo restituisce verbatim: nomi proprietà, alias, tipi, valori ammessi,
esempi, readback. È **il meccanismo che mantiene le descrizioni fedeli** (§5).
Formati: `docx`/`xlsx`/`pptx` (+ alias `word`/`excel`/`ppt`). `Help()` senza argomenti
elenca i formati e i comandi disponibili.

### Produzione documenti

| Comando | Metodo |
|---|---|
| `merge <template> <out> --data <json>` | `Merge(string templatePath, string outputPath, string dataJson)` |
| `dump <file> [<path>]` | `Dump(string? path = null)` |
| `import <file> <sheet> <csv> --header` | `Import(string sheetPath, string csvPath, bool? header = null)` (fase 2) |

### Watch (solo sessione desktop locale)

| Comando | Metodo | Note |
|---|---|---|
| `watch <file>` / `unwatch <file>` | `Watch(string? filePath = null, int? port = null)` / `Unwatch()` | Preview HTML live nel browser dell'utente (auto-refresh su ogni modifica). Disponibile SOLO su sessione desktop locale |
| `goto <file> <path>` | `Goto(string path)` | Scrolla il/i browser watching al path |
| `get <file> selected` | `GetSelected()` | Legge la selezione corrente nel browser (path stabili `@id=`) |
| `mark <file> <path> --prop ...` / `unmark` / `get-marks` | `Mark(string path, string[]? props = null)` / `Unmark(string? path = null, bool all = false)` / `GetMarks()` | Proposte di modifica in attesa di revisione umana, prima che tocchino il file |

**Gating desktop** — il watch apre un server HTTP locale + un browser sulla macchina
dove gira l'agente: disponibile solo quando l'utente è davanti a un desktop locale.
Design:

- `ExecuteAction` (AgentOrchestrator.cs#332) riceve un nuovo parametro opzionale
  **`bool isLocalUser = false`** — default false (safe). Il check "sistema desktop"
  NON è del chiamante: è interno a `ExecuteAction`:
  `watchAllowed = isLocalUser && IsInteractiveDesktopSession()`, con
  `IsInteractiveDesktopSession()` = `Environment.UserInteractive` su Windows/macOS
  (false in servizi/sessione 0) e presenza di `DISPLAY`/`WAYLAND_DISPLAY` su Linux.
- Dopo la creazione delle istanze (`agents[type] = Activator.CreateInstance(type)`),
  l'orchestratore propaga `watchAllowed` alle istanze che optano in via una piccola
  interfaccia marker, es. `ILocalDesktopCapable { bool IsWatchAllowed { get; set; } }`
  implementata da `OfficeTool` — stesso pattern di `WordTool.AsyncTaskRegistry`
  (proprietà pubblica sull'istanza, settata dall'infrastruttura).
- I metodi `Watch`/`Unwatch`/`Goto`/`GetSelected`/`Mark` guardano `IsWatchAllowed`
  alla prima riga: `"Error: Watch requires a local desktop session. Use ViewHtml() instead."`
- Gli XML docs dei metodi dicono *"(requires a local desktop session)"*: l'agente sa
  che la disponibilità dipende dall'host e pianifica di conseguenza.

**Catena a ritroso — chi passa cosa (`isLocalUser` colto alla fonte):**

| Fonte (utente) | Chiamata | `isLocalUser` |
|---|---|---|
| AIOffice — pannello Agent (desktop Blazor) | `Panels\Agent.cs:73` → `ExecuteAction` | `true` (utente alla macchina) |
| AIOffice — pannello Voice (desktop) | `Panels\Voice.cs:455` → `VoiceConversation.StreamToMediaAsync` → `ExecuteActionStream` → `ExecuteAction` | `true` |
| DocumentCreator — WebAgent (desktop) | `Panels\WebAgent.cs:42` → `ExecuteAction` | `true` |
| AgentBridge — API REST | `Program.cs:305` → `ExecuteAction` | Derivato dall'IP del client: `IsLoopback(HttpContext.Connection.RemoteIpAddress)` (localhost/::1 → true; IP remoto → false) |
| AgentBridge — chiamata SIP (telefono) | `SipBridge.cs:861` → `RunConversationAsync` → `StreamToMediaAsync` | `false` (l'utente non è al desktop) |
| Test / CI | harness | `false` (default) |

Il flag va propagato anche lungo il path streaming: `ExecuteActionStream(...)` e
`VoiceConversation.StreamToMediaAsync`/`RunConversationAsync` ricevono lo stesso
parametro (default `false`) e lo passano a `ExecuteAction`.
Caveat IP: dietro un reverse proxy `RemoteIpAddress` è l'IP del proxy — se il proxy è
sulla macchina locale (localhost), loopback → true, corretto; per proxy remoti il
client risulta remoto, come deve essere. In futuro si può guardare `X-Forwarded-For`.

### Esclusi (documentare il perché nella classe, non implementare)

- `mcp`, `install`, `config`, `plugins` — operazioni d'ambiente (rivolte all'operatore,
  non all'agente): non compaiono nella documentazione che l'agente usa per lavorare.
- `view pdf` — exporter plugin: richiede un plugin installato e un subprocess esterno
  (`Core/Plugins.ExporterInvoker`); per l'agente il bisogno visivo è coperto da
  `ViewHtml`/`ViewScreenshot`.
- `refresh` (TOC/pagine Word) — candidato fase 3 (backend Word solo Windows).

---

## 4. Regole di conversione dei parametri

1. **Path file** → `string` Unix-style relativo al sandbox, risolto con
   `SandboxPath.Resolve`/`TryResolve` in ogni metodo (mai risolto a mano, mai leak di
   `Setup.DocumentsPath`). Gli output (html/png, output di `Merge`) vanno scritti nel
   sandbox e restituiti come path agente con `SandboxPath.ToAgent`.
2. **Path documento** (`path`, `selector`, `parentPath`) → `string`, coordinate
   documento (sintassi officecli, 1-based). **Non passare da SandboxPath.** Il `<param>`
   deve distinguere esplicitamente: es. *"Document path in officecli syntax
   (e.g. /slide[1]/shape[2], 1-based)"* vs *"File path, Unix style relative to the
   workspace root"*.
3. **Proprietà** → `string[] props` di voci `"key=value"` (parità con `--prop`).
   Il `<param>` spiega il formato e rimanda a `Help()`:
   *"Properties as 'key=value' strings (e.g. ["text=Hello","bold=true"]). Property
   names, aliases, value formats and examples: call Help(format, element) first."*
4. **Posizionamento** (`after`/`before`/`index`) → parametri opzionali mutuamente
   esclusivi, come i flag CLI; `index` è 0-based (legacy CLI).
5. **Cross-reference tra metodi** (regola del guide): i `<param>` devono dire quale
   metodo produce il valore. Es. `Get` e `Query` producono i `path`; `ViewOutline`
   produce la struttura; `Help` produce i nomi proprietà.
6. **Tipi JSON**: `int?`→integer, `bool?`→boolean, `string[]`→array, tutto il resto→string.

---

## 5. Regole di conversione delle descrizioni (fedeltà)

Fonte di verità: `schemas/help/<format>/<element>.json` + stringhe `Description`
dei comandi in `CommandBuilder*.cs` + `SKILL.md`. Queste descrizioni sono testate e
fanno lavorare l'agente: **non inventare, non parafrasare; riusare il wording
originale**, applicando solo i ritagli della regola MIN-MAX (niente frasi di
contorno, niente dettagli di implementazione, una riga continua per ogni voce).

| Origine | Destinazione | Regola |
|---|---|---|
| `properties.<p>.description` + `values` + `aliases` + `examples` | `Help(format, element)` → JSON verbatim | Nessuna perdita: lo schema è la descrizione del parametro, consegnata a runtime |
| Comandi più comuni (`text`, `style`, `bold`, `size`, `fill`, `color`, `x/y/w/h`) | Hint di una riga nel `<param>` di `Set`/`Add` | Solo per evitare il round-trip di `Help()` nelle edit banali; mai una lista esaustiva |
| `Description` del comando (es. `view`, `get`) | `/// <summary>` del metodo | Fedele, con taglio MIN-MAX: eliminare solo i riferimenti CLI (`--json`, `-o`, shell quoting) |
| `readback` (es. `"unit-qualified, e.g. 12pt"`) | `/// <returns>` del metodo che legge il valore | Utile: dice all'agente il formato del valore restituito |
| `operations`/`add`/`set`/`get` per elemento | (nessuna destinazione) | Vincolo interno dell'engine, non serve all'agente |
| Errori (`Code`+`Suggestion`+`ValidValues`+`Help`) | Stringhe `"Error: ..."` (§6) | Mantenere il testo del suggerimento quasi verbatim |
| `SKILL.md` (strategia L1→L2→L3, help-first, pitfall comuni) | Class summary (righe successive) + `/// <summary>` dei metodi di scoperta | Es. *"Start with ViewOutline()/Get() before editing; call Help() when unsure about property names"* |

**Non tradurre**: le descrizioni sono in inglese (come da convention del repo) e
l'agente le legge in inglese. Il documento di conversione non è una traduzione.

### Esempio concreto — `set` di un paragrafo

Schema (`schemas/help/docx/paragraph.json`):
```json
"align": { "type": "enum", "values": ["left","center","right","justify","both","distribute"],
           "aliases": ["alignment","halign"], "add": true, "set": true, "get": true,
           "examples": ["--prop align=center"], "readback": "one of values", "enforcement": "strict" }
```

In `OfficeTool`:
```csharp
/// <summary>Modifies element properties at the given document path. Accepts selectors
/// and Excel-native paths (parity with Get/Query). Any XML attribute is settable.
/// Call Help(format, element) first when unsure about property names or value formats.</summary>
/// <param name="path">Document path in officecli syntax (e.g. /body/p[1], 1-based; or a selector
/// like paragraph[style=Heading1]). Produced by Get()/Query(). Use "/" for whole-document scope.</param>
/// <param name="props">Properties as 'key=value' strings, e.g. ["align=center","style=Heading1"].
/// Accepts aliases (align/alignment/halign) and value formats: colors (FF0000, red, accent1),
/// dimensions (2cm, 1in, 72pt, EMU), spacing (12pt, 1.5x, 150%). Dotted aliases allowed
/// (font.color=red, revision.author=Alice). Full property list: Help(format, element).</param>
/// <param name="find">Optional: only apply props to text matching this literal (or regex when
/// props contains regex=true). Empty match = success with 0 changes.</param>
/// <param name="replace">Optional: replace matched text (whole-document scope via path "/").</param>
/// <returns>Confirmation with path, or "Error: ..." with cause + fix + valid values.</returns>
public string Set(string path, string[]? props = null, string? find = null, string? replace = null)
```

---

## 6. Regole di conversione degli errori

`CliException` porta già causa + suggerimento + valori validi: è la stessa
struttura richiesta dalla nostra politica (causa + uso corretto + alternativa).
Tradurre `CliException` in stringhe nel metodo (mai lasciare che il safety net di
`CallMethod` intercetti l'eccezione grezza):

| `CliException` | Ritorno |
|---|---|
| `Code=not_found`, `Suggestion="Valid Slide index range: 1-8"` | `Error: Slide 50 not found (total: 8). Valid Slide index range: 1-8.` |
| `Code=invalid_value`, `ValidValues=[...]` | `Error: <message>. Valid values: <join>.` |
| `Code=unsupported_property` (auto-correzione nome) | `Error: Unknown property 'fnt'. Did you mean 'font'? Call Help(format, element) for the full list.` |
| `Code=file_not_found` | `Error: '<path>' not found in workspace. Use Open(path) on an existing file or Create(path) to make a new one.` |
| `Code=file_locked` | `Error: <message>. Close the file in the other application first.` |
| `Code=invalid_selector` / `invalid_path` | `Error: <message>. Selector/path syntax: see Help(format, element).` |
| `Code=corrupt_file` / `decompression_bomb` | `Error: Cannot open '<path>': <message>. Recreate the file with Create(path).` |

Regole:
- Mantenere il testo di `Message`/`Suggestion` **quasi verbatim** (sono già
  LLM-oriented e testati); aggiungere solo il prefisso `Error:` e, quando serve, il
  riferimento al metodo di scoperta (`Help(...)`, `Get()`, `ViewOutline()`).
- Stato non valido all'ingresso: `"Error: No document open. Call Open(path) or Create(path) first."`
- `find` senza match = successo silenzioso in CLI → nel nostro modello ritornare
  `"No matches found for '<find>' (0 changes)."` (l'agente deve poter distinguere).

---

## 7. Stato, ciclo di vita e backup

- **Costruttore parameterless** obbligatorio (reflection `Activator.CreateInstance`);
  il doc deve dire *"Call Open(path) or Create(path) first"*.
- **UN documento aperto alla volta** (analogo resident): `Open`/`Create` sostituiscono
  il corrente (pattern `SpreadsheetTool`). Regola cross-method nel class summary.
- **Modello salvataggio**: le modifiche vivono in memoria sull'istanza (handler
  aperto `editable: true`); `Save()` scrive su disco creando **backup numerato**
  (`.001.bak`, ...) e ritorna il nome del backup; `Restore()` ripristina il più
  recente. `Dispose` → flush + rilascio (equivale a `close`). Questo è il pattern
  Backup-Before-Write & Restore della guida — già usato da SpreadsheetTool/WordTool.
- Nessun salvataggio automatico intermedio: l'agente chiama `Save()` quando serve
  (parità con il flush esplicito di officecli prima che un altro programma legga il file).
- Stato di errore per method entry: guardia all'inizio di ogni metodo pubblico.

---

## 8. Sandbox e sicurezza

- Ogni parametro file (`filePath`, `templatePath`, `outputPath`, `csvPath`, `filePath`
  di `ViewHtml`/`ViewScreenshot`) → `SandboxPath.Resolve`/`TryResolve`.
- Ogni messaggio di risultato/errore che mostra un file → `SandboxPath.ToAgent(...)`.
- Il class summary documenta la convenzione Unix-path (una riga).
- `Help()` restituisce schemi embedded: nessun accesso a filesystem, sicuro.
- I path documento (`/slide[1]/...`) NON sono path filesystem: nessuna risoluzione.
- **Nessun metodo pubblico di sistema**: niente install/config/watch/mcp (v. §3).

---

## 9. Class summary (una riga + regole cross-method)

```csharp
/// <summary>Office document (DOCX/XLSX/PPTX) operations for agent use: create/open, view, get/query,
/// set/add/remove, raw XML, merge, dump, render.
/// ONE document open at a time: Open()/Create() replaces the current one; Save() persists with a
/// numbered backup, Restore() reverts.
/// File paths are Unix-style relative to the workspace root (leading "/") — never escape it.
/// Document paths use officecli syntax (e.g. /slide[1]/shape[2], 1-based).
/// Call Help(format, element) first when unsure about property names or value formats.</summary>
public class OfficeTool : BaseAgentTool, IDisposable, ILocalDesktopCapable, IFileTool
```

Ordine dei metodi nel file = ordine nelle definizioni tool: mettere prima la
scoperta (`Help`, `Open`, `Create`, `ViewOutline`, `Get`, `Query`), poi le
mutazioni, poi L3 e produzione. Questo implementa la progressione L1→L2→L3.

---

## 10. Registrazione nell'host

- Aggiungere `typeof(AIOrchestrator.API.OfficeTool)` all'array `agentTypes` dei host
  (es. `AIOffice\Panels\Agent.cs` riga 44 e `AIOffice\Panels\Voice.cs` righe 92-96).
- In `AgentOrchestrator.cs` (~riga 617), il guard `requiresFileTools` deve includere
  `t == typeof(API.OfficeTool)`.
- Gli host desktop passano `isLocalUser: true` a `ExecuteAction`/`ExecuteActionStream`
  (abilita i metodi Watch di OfficeTool, v. §3); l'API di AgentBridge lo deriva dall'IP
  loopback; SIP e test lo omettono (false).
- **Coesistenza**: OfficeTool copre docx+xlsx+pptx; WordTool (DocSharp/OpenXml) e
  SpreadsheetTool (Aspose.Cells_FOSS) restano registrati? Doppia superficie = token
  sprecati e scelte ambigue per l'agente. Decisione da confermare: sostituire o
  mantenere entrambi (una via intermedia: OfficeTool per pptx+merge+render, e far
  convergere gli altri in fasi successive).

---

## 11. Fasi di porting

| Fase | Contenuto | Verifica |
|---|---|---|
| **0 — Setup** | **FATTO (2026-08-13)**: progetto `OfficeCliEngine` creato — intero albero upstream v1.0.143 byte-identical (verifica hash: 0 differenze), unico DELETE = `Program.cs`, csproj auto-version + pipeline NuGet + `publish.yml`, `VENDOR.md`, `sync-exclude.txt`, `sync-from-upstream.ps1`, `NOTICE.md` Apache-2.0, repo git init | **FATTO**: build Release 0 errori/0 avvisi; `dotnet pack` → `OfficeCliEngine.1.26.8.13.nupkg`; risorse embedded verificate (schemas/help 152, skills 121, preview/watch, EffectTemplates 31) con le LogicalName attese |
| **1 — Core** | **FATTO (2026-08-13)**: dual-reference in `AIOrchestrator.csproj` (ProjectReference condizionale + PackageReference 1.*), `API/OfficeTool.cs` core: `Open`/`Create`/`Save`/`Restore`/`FilePath`/`Dispose` (backup numerato .NNN.bak + auto-save on dispose), `ViewOutline`/`ViewText`/`ViewAnnotated`/`ViewStats`/`ViewIssues`/`Validate`, `Get`/`Query` (envelope `{matches,results}`), `Set`/`Add`/`Remove`/`Move`/`Swap`, `Help(format, element)` (schemi embedded via `SchemaHelpLoader` + InternalsVisibleTo), `Batch` (envelope CLI byte-identical). Guard `requiresFileTools` esteso. `InternalsVisibleTo` per `AIOrchestrator` + `OfficeTool.Tests` aggiunto al csproj dell'engine | **FATTO**: harness `OfficeTool.Tests` — 39 test deterministici (docx/xlsx/pptx: crea→popola→leggi→batch 60 celle→backup/restore→errori→help), tutti passanti |
| **2 — Avanzato** | **FATTO (2026-08-13)**: `Raw`/`RawSet`/`AddPart`, `ViewHtml` (RenderViaRegistry + save nel sandbox), `Merge` (TemplateMerger, placeholder {{key}}), `Dump` (emitter Word/Excel/Pptx + meta item + BatchJsonContext), `Import` (ExcelHandler.Import, csv/tsv, --header, start-cell). Fix: directory auto-creata in ViewHtml/ViewScreenshot | **FATTO**: harness esteso — Raw part, ViewHtml file+inline, Dump round-trip JSON, Merge con template reale, tutti passanti |
| **3 — Fidelity** | **FATTO (2026-08-13)**: `ViewScreenshot` (HtmlScreenshot.Capture, Chrome-family, errore screenshot_unavailable se manca il browser), `Watch`/`Unwatch`/`Goto`/`GetSelected`/`Mark`/`Unmark`/`GetMarks` (WatchServer in-process + pipe WatchNotifier, gated da `ILocalDesktopCapable.IsWatchAllowed`), `LoadSkill`/`LoadSkillFile`/`ListSkills` (SkillInstaller embedded). NotifyWatch() live-refresh dopo ogni mutazione. **2026-08-14**: superficie skill **unificata** in un solo `LoadSkill(string? skill = null)` (null→catalogo, `/path`→file bundled, nome→SKILL.md); `LoadSkillFile`/`ListSkills` non più tool separati | **FATTO**: harness esteso — skills, gating watch (default false → "requires a local desktop session"), screenshot path-or-error; 54/54 test passanti |
| **4 — Distribuzione** | **FATTO (2026-08-13)**: gating orchestrate — `ExecuteAction`/`ExecuteActionStream` + `VoiceConversation.StreamToMediaAsync`/`RunConversationAsync` ricevono `bool isLocalUser = false`; `watchAllowed = isLocalUser && IsInteractiveDesktopSession()` propagato a `ILocalDesktopCapable`; helper `IsInteractiveDesktopSession()` (UserInteractive su Win/macOS, DISPLAY/WAYLAND su Linux). Host: `AIOffice\Panels\Agent.cs` (+OfficeTool, isLocalUser: true), `Panels\Voice.cs` (+OfficeTool, isLocalUser: true), `AgentBridge` (`/v1/chat/completions` riceve HttpContext → isLocalUser = IP loopback; `office-agent` = FileTool+OfficeTool; SIP resta default false). **Repo**: `Graphene-Lab/OfficeCliEngine` creato (public) + push | **FATTO**: build AIOrchestrator (0 errori), AIOffice (0 errori), AgentBridge (0 errori); harness 54/54; scenario `--agent` (LLM, provider DeepSeekBridge) disponibile nell'harness |
| **5 — Manutenzione/update** | **FATTO (2026-08-13)**: sync riscritto su **release stabile** ("Source code (zip)" di GitHub, mai il ramo default): download + parità byte-identical SHA-256 + prune file spariti + auto-update `VENDOR.md` (versione/commit `target_commitish`/data). Nuovo **`update-officecli.ps1`** semi-automatico: sync + gap analysis (comandi/view-modes CLI vs metodi `OfficeTool`, report `sync-gap-report.md`) + parità risorse embedded (csproj upstream vs nostro) + build engine/AIOrchestrator + harness + pack. Superficie completata: `ViewForms` (docx), `ViewSvg` (pptx); `view pdf` escluso con motivo (plugin exporter). Doc: `VENDOR.md`/`README.md` riscritti | **FATTO**: build 0 errori; harness 60/60 |
| **6 — Plugin** | **FATTO (2026-08-14)**: repo `Graphene-Lab/OfficeTool` (public) + pacchetto NuGet `Graphene.OfficeTool`; `OfficeTool.cs`, `OfficePorting.md` e l'harness migrati da AIOrchestrator; engine vendored (src/officecli, skills, schemas) fuso nello stesso progetto/assembly (niente più repo/pacchetto `OfficeCliEngine`, cancellati). Updater rinominato **`update-vendor.ps1`** ("Vendor to OfficeTool (plugin) updater"): toolPath/harness locali al repo, build del plugin (non più engine+AIOrchestrator). Host aggiornati: AIOffice (plugin da `Tools/OfficeTool`, rimossi i riferimenti statici in Agent/Voice), AgentBridge (dual-reference `Graphene.OfficeTool` per `office-agent`) | **FATTO**: build AIOrchestrator + plugin + AIOffice 0 errori; harness `--full` verde; load dinamico del plugin verificato |

---

## 12. Testing

- **Harness**: `AIOrchestrator\OfficeTool.Tests` seguendo il pattern dei progetti di
  test esistenti (WordTool.Tests, SpreadsheetTool.Tests): scenario-driven, file reali
  nel sandbox, verifica contenuti e backup.
- **Contratti schema**: lo schema embedded non cambia (l'engine non si modifica);
  `Help()` deve restituire esattamente il JSON embedded (test di round-trip).
- **Parità CLI**: per i metodi principali, eseguire lo stesso scenario via officecli
  binario e via `OfficeTool` e confrontare i risultati (documenti generati + output JSON).
- **Sandbox**: test di confine (sibling-prefix, `..`, path Windows assoluti) come nel
  test 16 di AgentOrchestrator.Tests.

---

## 13. Rischio e decisioni aperte

1. **Integrazione engine** — **Deciso: B**, vendor byte-identical in `OfficeCliEngine`
   (progetto library sibling di AIOrchestrator, pattern dual-reference, sync script +
   VENDOR.md) — §2.
2. **Coesistenza con WordTool/SpreadsheetTool** — **Deciso: nessuna azione iniziale**;
   i tool esistenti restano registrati e l'utente li eliminerà se OfficeTool
   funzionerà bene. Registrare OfficeTool solo per i formati non coperti all'inizio
   (pptx) se utile a ridurre la doppia superficie — §10.
3. **Pack NuGet**: il progetto `OfficeCliEngine` va pubblicato seguendo il pipeline
   esistente (versione datata + NuGetApiKey + `.github/workflows/publish.yml`, §2) per
   abilitare il fallback PackageReference nelle build senza sorgenti. — **Deciso**.
4. **Dimensione**: in opzione B il drop è di ~200 file; lo script di sync
   (`sync-from-upstream.ps1` + `sync-exclude.txt`, §2) è lo strumento per non creare
   un fork divergente — il vendor resta byte-identical a upstream. — **Deciso**.
5. **`Set` generico vs tipizzato**: la scelta `Set(path, props)` + `Help()` sacrifica
   l'introspezione statica delle proprietà negli XML docs in cambio di fedeltà totale
   e prompt minimo. Se si preferisce l'introspezione, alternativa: metodi tipizzati
   per i tipi di elemento più usati (paragraph, shape, cell, slide, sheet) che
   inlinano le proprietà comuni e delegano il resto a `Help()`. — **Deciso: `Set`
   generico + `Help()`**, come da §3/§5; l'alternativa tipizzata resta un'evoluzione
   futura se l'introspezione dovesse servire.
6. **load_skill** — **Deciso: tenere** `LoadSkill(name)` (skill embedded, §3).
7. **Fonte del sync** — **Deciso (2026-08-13): release stabile, non il repo**. Il
   vendor si allinea allo "Source code (zip)" della release GitHub (mai il ramo
   default), così la base è sempre la stable release e non i lavori in corso
   upstream. Manutenzione semi-automatica via `update-officecli.ps1` (§2/§11).
