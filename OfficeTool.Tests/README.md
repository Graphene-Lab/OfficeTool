# OfficeTool.Tests — strategia dei test

Harness end-to-end per `OfficeTool` (`OfficeTool.cs` nel repo plugin, stesso repo dell'engine
vendored). Esegue operazioni
reali su file docx/xlsx/pptx in una sandbox e verifica i risultati agent-facing
(envelope JSON, stringhe di errore officecli, versioning/rollback, help embedded).

## Regola d'oro

> **Non rieseguire ciò che sappiamo già funzionare.**

Un test su un singolo metodo o caso specifico (es. `ToUpper()`) si scrive, si esegue
**una volta** quando tocchiamo quel metodo, e poi si elimina. Le funzionalità di base
non cambiano da sole: vanno ritestate solo **quando sappiamo di averle modificate**.
Lanciare ogni volta tutti i test, incluso ciò che è già appurato, trasforma un run di
pochi secondi in una attesa inutile.

## Gruppi di test

| Gruppo | Contenuto | Quando si lancia |
|---|---|---|
| `smoke` (default) | Flusso core per formato (docx/xlsx/pptx: create→add→get→save→rollback) + guardie base | **Sempre** (default, nessun argomento) — pochi secondi |
| `golden` | Regression vendor: le stesse sequenze di `examples/` dell'upstream (document props, cell formatting, tables) | **Dopo ogni sync vendor** (`update-vendor.ps1`) |
| `view` | Tutte le View* (Outline, Stats, Annotated, Html, Forms, Svg, Screenshot, Watch gating) | Quando si tocca un metodo View |
| `edits` | Swap, Query, Raw, Dump, template, Merge | Quando si tocca un metodo di editing |
| `skills` | LoadSkill unificato (catalogo su null, `/path` → file, nome → SKILL.md) | Quando si tocca il sistema skill |
| `dashboard` | Caso reale vendor: replica di `sales-dashboard.xlsx` (showcase iOfficeAI/OfficeCLI) — skill `data-dashboard`, CSV reale, foglio Dashboard con KPI formula-driven + 2 grafici, Data con freeze/autofilter/CF, tab colors, activeTab, preview HTML senza `###` | Quando si tocca xlsx/chart/CF/import o si portano casi vendor |
| `office` | Deck progettato 3 slide (stile pitch-deck): cover navy con titolo ≥36pt + barra accento, slide stats con callout, chiusura; produce il `deck.pptx` "presentabile" (lo smoke lascia solo il flusso minimale) | Quando si tocca pptx shape/testo o si vuole il deck di esempio |
| `word` | Report progettato 1 pagina (stile showcase docx): document props, Title + lead, sezioni Heading1 con size esplicite, elenco puntato, tabella dati con header stilizzato, footer con campo pagina; produce il `demo.docx` "presentabile" | Quando si tocca docx stili/tabelle/footer o si vuole il documento di esempio |
| `--demo` | Solo `word` + `dashboard` + `office`, poi copia i 3 demo (`demo.docx`, `dashboard.xlsx`, `deck.pptx`) in `demo/` (sopravvivono al wipe del workspace in %TEMP%) | Quando si vogliono i 3 file demo pronti |
| `help` | Schemi help embedded | Quando si tocca lo schema help / sync schemas |
| `--agent` | Scenario LLM: l'agente costruisce un deck a 3 slide con OfficeTool | Esplicitamente, richiede DeepseekBridge su 127.0.0.1:8787 |
| `--agent-dashboard` | Scenario LLM: l'agente costruisce `dashboard.xlsx` dal CSV reale vendor con la skill `data-dashboard` (nessuno scripting — l'LLM decide ogni chiamata). Verifica onesta: Gate 1 (KPI formula) + Gate 8 (SUM su colonna Revenue con cache viva = 4.682.000) + grafici + validate | Esplicitamente, richiede DeepseekBridge; minuti |

Ogni gruppo è **autosufficiente** (crea i propri file con nomi dedicati), quindi
`--group <nome>` funziona anche da solo, senza dipendere dallo smoke.

## Comandi

```powershell
dotnet run --project OfficeTool.Tests -c Release                # smoke (default, ~5s)
dotnet run --project OfficeTool.Tests -c Release -- --full      # tutti i gruppi deterministici
dotnet run --project OfficeTool.Tests -c Release -- --demo      # i 3 file demo pronti in demo/
dotnet run --project OfficeTool.Tests -c Release -- --group golden
dotnet run --project OfficeTool.Tests -c Release -- --agent     # scenario LLM: deck (minuti)
dotnet run --project OfficeTool.Tests -c Release -- --agent-dashboard  # scenario LLM: dashboard da CSV reale (minuti)
dotnet run --project OfficeTool.Tests -c Release -- --range 21-23   # on-the-fly: check 21-23
dotnet run --project OfficeTool.Tests -c Release -- --filter svg    # on-the-fly: nome contiene "svg"
```

`--range` e `--filter` implicano `--full` (selezionano dall'intero set deterministico);
il riepilogo finale riporta `executed N · skipped M`.

## Lavorare sui test (flusso raccomandato)

1. **Stai sviluppando un metodo** (es. `ViewSvg`): usa `--filter svg` per test mirati rapidi.
   Il test mirato vive nel working tree, non nel commit.
2. **Verifica che funzioni** → il test mirato ha esaurito il suo scopo → **eliminalo**.
   Non resta nel codice: se il metodo rompe, lo si riscopre quando lo si modifica di nuovo.
3. **Hai modificato il funzionamento di un metodo esistente**: aggiungi/aggiorna il suo
   check nel gruppo appropriato (view/edits/skills/help), non nello smoke.
4. **Dopo un sync vendor** (`update-vendor.ps1`): lancia `--group golden` + `--group help`
   (gli schemi possono essere cambiati) + `--group skills` (skill nuove).

## Perché il workspace è in %TEMP%

Il repo vive sotto `OneDrive\Sorgenti\...`. In passato il workspace dei test era dentro
il progetto: ogni Create/Save scriveva file OOXML che OneDrive sincronizzava sul cloud —
i run da "un'ora" erano il sync, non i test. Il workspace ora sta in
`%TEMP%\OfficeTool.Tests-workspace` (disco locale, nessun sync). Viene cancellato e
ricreato a ogni run.

## Aggiungere un nuovo test

- Nello **smoke** solo se è parte del flusso core di un formato (raro).
- Nel gruppo giusto (view/edits/skills/help/golden) se copre un'area funzionale.
- Il **golden** si modifica solo portando un nuovo esempio vendor.
- Un nuovo caso reale vendor (es. uno showcase `assets/showcase/*.xlsx` di iOfficeAI)
  va nel gruppo **dashboard**, non nel golden: dati reali come CSV in-code, poi
  verifica strutturale (fogli, KPI con formula+cachedValue, grafici, CF, activeTab,
  preview HTML).
- Test on-the-fly: scrivili, eseguili con `--filter`/`--range`, cancellali quando hai
  verificato. Non lasciare test che ripetono ciò che il flusso già copre.
