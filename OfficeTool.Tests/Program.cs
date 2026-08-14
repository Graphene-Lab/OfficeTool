using System.Text.Json;
using System.Text.Json.Nodes;
using AIOrchestrator;
using AIOrchestrator.API;

namespace OfficeToolTests;

/// <summary>
/// OfficeTool end-to-end tests, grouped by purpose (strategy in README.md):
///   default       — smoke only (fast, seconds)
///   --full        — all deterministic groups
///   --group NAME  — one group: smoke|golden|view|edits|skills|dashboard|office|word|help
///   --demo        — word+dashboard+office only, then copies the 3 demo files
///                   (demo.docx, dashboard.xlsx, deck.pptx) into demo/
///   --agent       — LLM scenario (needs DeepseekBridge on 127.0.0.1:8787)
///   --range N-M   — run only checks N..M (implies --full)
///   --filter SUB  — run only checks whose name contains SUB (implies --full)
/// Golden rule: never re-run what we know works. A test on a single method is
/// written on-the-fly (--range/--filter), run once, then deleted.
/// Workspace lives in %TEMP% on purpose: the repo sits under OneDrive, and test
/// files written under the repo got cloud-synced on every Create/Save — the
/// historical "hour-long" runs. %TEMP% is local disk, no sync.
/// </summary>
static class Program
{
    private static int _failures, _total, _skipped, _index;
    private static (int From, int To)? _range;
    private static string? _filter;
    private static string _workspace = "";

    static int Main(string[] args)
    {
        if (args.Contains("--agent")) return RunAgentScenario();
        if (args.Contains("--agent-dashboard")) return RunAgentDashboardScenario();

        _range = ParseRange(Arg(args, "--range"));
        _filter = Arg(args, "--filter");
        var group = Arg(args, "--group");
        var demo = args.Contains("--demo");
        var full = args.Contains("--full") || _range != null || _filter != null;

        var groups = new (string Name, Action<OfficeTool> Run)[]
        {
            ("smoke",  RunSmoke),
            ("golden", RunGolden),
            ("view",   RunView),
            ("edits",  RunEdits),
            ("skills", RunSkills),
            ("dashboard", RunDashboard),
            ("office",   RunOffice),
            ("word",    RunWord),
            ("help",   RunHelp),
        };

        if (group != null)
        {
            var match = Array.Find(groups, g => g.Name == group);
            if (match.Name == null)
            {
                Console.WriteLine($"Unknown group '{group}'. Available: {string.Join(", ", groups.Select(g => g.Name))}");
                return 2;
            }
            groups = new[] { match };
        }
        else if (demo)
        {
            groups = groups.Where(g => g.Name is "word" or "dashboard" or "office").ToArray();
        }
        else if (!full)
        {
            groups = new[] { groups[0] }; // default: smoke only
        }

        Log.IsEnabled = true;
        _workspace = Path.Combine(Path.GetTempPath(), "OfficeTool.Tests-workspace");
        if (Directory.Exists(_workspace)) Directory.Delete(_workspace, recursive: true);
        Directory.CreateDirectory(_workspace);
        Setup.SkipIndexingOnStartup = true;
        Setup.DocumentsPath = _workspace;

        Console.WriteLine("══════════ OfficeTool tests ══════════");
        Console.WriteLine(group != null ? $"group: {group}"
            : demo ? "groups: word + dashboard + office (--demo)"
            : full ? "groups: all (--full)" : "groups: smoke (default)");
        Log.LogStep("=== OfficeTool.Tests run ===");
        using var tool = new OfficeTool();

        foreach (var g in groups)
        {
            Console.WriteLine($"\n── {g.Name} ──");
            g.Run(tool);
        }

        Console.WriteLine($"\n══════════ {(_failures == 0 ? "ALL TESTS PASSED" : $"{_failures} FAILURE(S)")} ══════════");
        Console.WriteLine($"executed {_total} check(s) · skipped {_skipped}");

        // --demo: keep the three showcase files out of the %TEMP% wipe. The repo
        // lives under OneDrive, so the copy happens once per run — never per edit.
        if (demo && _failures == 0)
        {
            var demoDir = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "demo"));
            Directory.CreateDirectory(demoDir);
            foreach (var f in new[] { "demo.docx", "dashboard.xlsx", "deck.pptx" })
            {
                var src = Path.Combine(_workspace, f);
                if (File.Exists(src))
                {
                    File.Copy(src, Path.Combine(demoDir, f), overwrite: true);
                    Console.WriteLine($"demo: {f} → {Path.Combine(demoDir, f)}");
                }
            }
        }
        return _failures == 0 ? 0 : 1;
    }

    static void RunSmoke(OfficeTool tool)
    {
        // docx core workflow
        Check("docx Create", tool.Create("/doc.docx"));
        var p1 = tool.Add("/body", "paragraph", new[] { "text=Hello World" });
        Check("docx Add paragraph → path returned", p1.StartsWith("Added /body/p") && !p1.Contains("Error"));
        Check("docx Get text", NodeText(tool.Get("/body/p[1]")) == "Hello World");
        Check("docx Set bold", tool.Set("/body/p[1]", new[] { "bold=true" }).StartsWith("Updated"));
        Check("docx Save → .001.bak", tool.Save().Contains(".001.bak"));
        Check("docx Save backup after edit", tool.Set("/body/p[1]", new[] { "text=Changed" }).StartsWith("Updated")
            && tool.Save().Contains(".002.bak"));
        Check("docx Restore → text back", tool.Restore().Contains("restored from backup")
            && NodeText(tool.Get("/body/p[1]")) == "Hello World");
        Check("docx Validate is JSON", tool.Validate().StartsWith("{") && tool.Validate().Contains("\"errors\""));
        Check("docx Get missing path → Error", tool.Get("/body/p[999]").StartsWith("Error:"));

        // xlsx core workflow
        Check("xlsx Create", tool.Create("/book.xlsx"));
        var items = Enumerable.Range(1, 60)
            .Select(i => $"{{\"command\":\"set\",\"path\":\"/Sheet1/A{i}\",\"props\":{{\"value\":\"{i * 2}\"}}}}");
        var batch = Parse(tool.Batch("[" + string.Join(",", items) + "]"));
        Check("xlsx Batch 60 cells → success", batch?["success"]?.GetValue<bool>() == true);
        Check("xlsx cell A5 value 10", NodeText(tool.Get("/Sheet1/A5")) == "10");
        Check("xlsx cell A60 value 120", NodeText(tool.Get("/Sheet1/A60")) == "120");
        Check("xlsx Save backup", tool.Save().Contains(".001.bak"));

        // pptx core workflow
        Check("pptx Create", tool.Create("/deck.pptx"));
        Check("pptx Add slide → /slide[1]", tool.Add("/", "slide").Contains("/slide[1]"));
        Check("pptx Add second slide", tool.Add("/", "slide").Contains("/slide[2]"));
        var shp = tool.Add("/slide[1]", "shape", new[] { "text=Title", "x=1cm", "y=1cm", "w=10cm", "h=3cm" });
        Check("pptx Add shape", shp.StartsWith("Added /slide[1]/shape["));
        Check("pptx shape text", NodeText(tool.Get(shp.Replace("Added ", "").TrimEnd('.'))) == "Title");

        // guards
        Check("No document open guard", new OfficeTool().Get("/x").Contains("No document open"));
    }

    static void RunGolden(OfficeTool tool)
    {
        // Ported from the upstream release's examples/ walkthroughs: same command
        // sequences through OfficeTool, same observable outcomes. Run after every
        // vendor sync (update-officecli.ps1).

        // word/document-formatting.md — document-level property round-trip
        Check("golden docx create", tool.Create("/gold.docx"));
        var setDoc = tool.Set("/", new[]
        {
            "author=Jane Author", "title=Q3 Field Report",
            "pageWidth=21cm", "pageHeight=29.7cm", "orientation=portrait",
            "docDefaults.font=Georgia", "docDefaults.fontSize=12",
            "theme.color.accent1=1F6FEB", "docGrid.type=lines",
        });
        Check("golden docx set document props → no unsupported", !setDoc.Contains("Skipped unsupported"));
        var docProps = tool.Get("/");
        Check("golden docx get normalizes color → #1F6FEB", docProps.Contains("#1F6FEB"));
        Check("golden docx get keeps pageWidth 21cm", docProps.Contains("21cm"));
        Check("golden docx get keeps docDefaults.font Georgia", docProps.Contains("Georgia"));
        Check("golden docx get keeps docGrid.type lines", docProps.Contains("lines"));
        Check("golden docx validate OK", tool.Validate().StartsWith("{") && !tool.Validate().Contains("Error"));

        // excel/cell-formatting.md — cell property surface
        Check("golden xlsx create", tool.Create("/gold.xlsx"));
        Check("golden xlsx set cell font", tool.Set("/Sheet1/B1", new[]
        {
            "value=Bold + italic + blue + 14pt",
            "font.bold=true", "font.italic=true", "font.color=2E75B6", "font.size=14",
        }).StartsWith("Updated"));
        var cell = tool.Get("/Sheet1/B1");
        Check("golden xlsx get normalizes color → #2E75B6", cell.Contains("#2E75B6"));
        Check("golden xlsx get normalizes size → 14pt", cell.Contains("14pt"));
        Check("golden xlsx get keeps bold", cell.Contains("bold"));
        Check("golden xlsx set numberformat", tool.Set("/Sheet1/B2", new[] { "value=29999.9", "numberformat=$#,##0.00" }).StartsWith("Updated"));
        Check("golden xlsx set formula", tool.Set("/Sheet1/B3", new[] { "formula=B2*2" }).StartsWith("Updated"));
        Check("golden xlsx set merge", tool.Set("/Sheet1/B4", new[] { "value=Merged title", "merge=B4:D4" }).StartsWith("Updated"));
        Check("golden xlsx border", tool.Set("/Sheet1/B5", new[] { "value=x", "border.bottom=double" }).StartsWith("Updated"));
        Check("golden xlsx get value", NodeText(tool.Get("/Sheet1/B1")) == "Bold + italic + blue + 14pt");

        // ppt/tables/tables-basic.md — table surface (data= CSV, per-cell set)
        Check("golden pptx create", tool.Create("/gold.pptx"));
        tool.Add("/", "slide");
        var tbl = tool.Add("/slide[1]", "table", new[]
        {
            "x=0.5in", "y=1.2in", "width=12in", "height=2in",
            "headerFill=4472C4", "bodyFill=DEEAF6",
            "data=Region,Q1,Q2,Q3,Q4;North,120,135,142,168;South,98,110,121,140",
        });
        Check("golden pptx add table → path under /slide[1]", tbl.StartsWith("Added /slide[1]/table["));
        var tablePath = tbl.Replace("Added ", "").TrimEnd('.');
        Check("golden pptx set table cell", tool.Set($"{tablePath}/tr[1]/tc[1]", new[] { "text=Product", "bold=true", "color=FFFFFF" }).StartsWith("Updated"));
        Check("golden pptx get table cell text", NodeText(tool.Get($"{tablePath}/tr[1]/tc[1]")) == "Product");
        Check("golden pptx get table cell fill", tool.Get($"{tablePath}/tr[1]/tc[1]").Contains("color"));
        var pptOutline = Parse(tool.ViewOutline());
        Check("golden pptx outline 1 slide", pptOutline?["totalSlides"]?.GetValue<int>() == 1);
    }

    static void RunView(OfficeTool tool)
    {
        // Self-contained: creates its own files, so --group view works standalone.
        tool.Create("/view.docx");
        tool.Add("/body", "paragraph", new[] { "text=Hello World" });
        Check("view docx reopen", tool.Open("/view.docx"));
        Check("view docx ViewOutline is JSON", tool.ViewOutline().StartsWith("{") && tool.ViewOutline().Contains("\"paragraphs\""));
        Check("view docx ViewStats is JSON", tool.ViewStats().StartsWith("{") && !tool.ViewStats().Contains("Error"));
        Check("view docx ViewAnnotated text", tool.ViewAnnotated().Contains("Hello World"));
        Check("view docx Add sdt", tool.Add("/body", "sdt", new[] { "type=text", "alias=name" }).StartsWith("Added /body/sdt"));
        Check("view docx ViewForms → JSON fields", tool.ViewForms().StartsWith("{") && tool.ViewForms().Contains("\"fields\""));
        Check("view docx ViewHtml saves file", tool.ViewHtml("/out/doc.html").Contains("/out/doc.html")
            && File.Exists(Path.Combine(_workspace, "out", "doc.html")));
        Check("view docx ViewHtml inline", tool.ViewHtml().StartsWith("<!DOCTYPE") || tool.ViewHtml().Contains("<html"));
        tool.Create("/view.xlsx");
        tool.Set("/Sheet1/A1", new[] { "value=10" });
        Check("view xlsx ViewText range", tool.ViewText(range: "Sheet1!A1:B3").StartsWith("{"));
        Check("view xlsx ViewText cols", tool.ViewText(cols: new[] { "A" }).StartsWith("{"));
        tool.Create("/view.pptx");
        tool.Add("/", "slide");
        var svg = tool.ViewSvg(1);
        Check("view pptx ViewSvg → SVG markup", svg.StartsWith("<svg") || svg.Contains("<svg"));
        Check("view pptx ViewSvg out-of-range → Error", tool.ViewSvg(99).StartsWith("Error:"));
        var shot = tool.ViewScreenshot("/shot.png");
        Check("view ViewScreenshot → png path or browser-missing error", shot.Contains(".png") || shot.Contains("Error"));
        Check("view Watch gated by default", tool.Watch().Contains("local desktop session"));
        Check("view Unwatch without watch", tool.Unwatch().Contains("No watch is running"));
        Check("view GetSelected gated", tool.GetSelected().Contains("local desktop session"));
    }

    static void RunEdits(OfficeTool tool)
    {
        // Self-contained: creates its own files, so --group edits works standalone.
        tool.Create("/edits.docx");
        tool.Add("/body", "paragraph", new[] { "text=Hello World" });
        Check("edits docx Swap", tool.Swap("/body/p[1]", "/body/p[1]").StartsWith("Swapped"));
        Check("edits docx Query selector", !tool.Query("paragraph").Contains("Error"));
        var raw = tool.Raw("/word/document.xml");
        Check("edits docx Raw part", raw.Contains("<w:document"));
        var dump = tool.Dump("/");
        Check("edits docx Dump → batch JSON with meta", dump.StartsWith("[{\"command\":\"meta\"") || dump.Contains("\"command\":\"meta\""));
        Check("edits docx Create template", tool.Create("/tpl.docx"));
        Check("edits docx template placeholder", tool.Add("/body", "paragraph", new[] { "text=Hello {{name}}" }).StartsWith("Added /body/p"));
        tool.Save();
        var merged = tool.Merge("/tpl.docx", "/merged.docx", "{\"name\":\"World\"}");
        Check("edits docx Merge → replaced", merged.Contains("1 placeholder(s) replaced")
            && File.Exists(Path.Combine(_workspace, "merged.docx")));
        tool.Create("/edits.pptx");
        tool.Add("/", "slide");
        tool.Add("/", "slide");
        Check("edits pptx Swap slides", tool.Swap("/slide[1]", "/slide[2]").StartsWith("Swapped"));
    }

    static void RunSkills(OfficeTool tool)
    {
        var skill = tool.LoadSkill("pitch-deck");
        Check("skills LoadSkill pitch-deck", skill.Contains("#") && !skill.Contains("Error"));
        Check("skills LoadSkill null → catalog", tool.LoadSkill().Contains("pitch-deck"));
        Check("skills LoadSkill unknown → Error with list", tool.LoadSkill("bogus").StartsWith("Error: Unknown skill"));
        Check("skills LoadSkill /path → file", tool.LoadSkill("/pitch-deck/SKILL.md").Contains("#"));
        Check("skills LoadSkill /path traversal → Error", tool.LoadSkill("/pitch-deck/../SKILL.md").StartsWith("Error:"));
    }

    // Real-case fixture: the 20 sales rows shipped in the vendor's showcase
    // workbook (iOfficeAI/OfficeCLI assets/showcase/sales-dashboard.xlsx).
    private const string SalesDataCsv =
        "Region,Product,Month,Revenue,Cost,Profit,Target,Achievement%\n" +
        "North America,Enterprise,Oct,485000,291000,194000,450000,1.078\n" +
        "North America,SMB,Oct,320000,198000,122000,300000,1.067\n" +
        "North America,Consumer,Oct,210000,142000,68000,200000,1.05\n" +
        "North America,Enterprise,Nov,510000,306000,204000,470000,1.085\n" +
        "North America,SMB,Nov,340000,204000,136000,310000,1.097\n" +
        "Europe,Consumer,Nov,155000,105000,50000,160000,0.969\n" +
        "Europe,Enterprise,Oct,365000,228000,137000,350000,1.043\n" +
        "Europe,SMB,Oct,242000,157000,85000,250000,0.968\n" +
        "Europe,Consumer,Oct,165000,112000,53000,170000,0.971\n" +
        "Europe,Enterprise,Nov,385000,238000,147000,360000,1.069\n" +
        "APAC,Enterprise,Oct,275000,178000,97000,260000,1.058\n" +
        "APAC,SMB,Oct,185000,125000,60000,190000,0.974\n" +
        "APAC,Consumer,Oct,120000,84000,36000,130000,0.923\n" +
        "APAC,Enterprise,Nov,295000,189000,106000,280000,1.054\n" +
        "LatAm,Enterprise,Oct,145000,98000,47000,150000,0.967\n" +
        "LatAm,SMB,Oct,95000,68000,27000,100000,0.95\n" +
        "LatAm,Consumer,Oct,62000,45000,17000,70000,0.886\n" +
        "LatAm,Enterprise,Nov,158000,105000,53000,155000,1.019\n" +
        "LatAm,SMB,Nov,102000,72000,30000,105000,0.971\n" +
        "LatAm,Consumer,Nov,68000,49000,19000,75000,0.907";

    // Real-case fixture: the 10-rep leaderboard from the same showcase workbook.
    private const string SalesRepsCsv =
        "Rep Name,Region,Revenue,Rank\n" +
        "Sarah Johnson,North America,1850000,1\n" +
        "Michael Chen,APAC,1620000,2\n" +
        "Emma Williams,Europe,1540000,3\n" +
        "David Martinez,LatAm,1380000,4\n" +
        "Lisa Thompson,North America,1250000,5\n" +
        "James Park,APAC,1120000,6\n" +
        "Anna Mueller,Europe,980000,7\n" +
        "Carlos Silva,LatAm,870000,8\n" +
        "Yuki Tanaka,APAC,760000,9\n" +
        "Pierre Dubois,Europe,650000,10";

    static void RunDashboard(OfficeTool tool)
    {
        // Replicates the vendor's real-case result — "Q4 2025 Global Sales
        // Dashboard" (iOfficeAI/OfficeCLI assets/showcase/sales-dashboard.xlsx,
        // produced by the officecli-data-dashboard skill). Same input data, same
        // composition: Dashboard sheet with formula KPI cards + 2 charts, Data
        // sheet with freeze/autofilter/conditional formatting, tab colors,
        // activeTab pointing at the Dashboard sheet.
        var dataCsv = Path.Combine(_workspace, "sales-data.csv");
        var repsCsv = Path.Combine(_workspace, "sales-reps.csv");
        File.WriteAllText(dataCsv, SalesDataCsv);
        File.WriteAllText(repsCsv, SalesRepsCsv);

        var skill = tool.LoadSkill("data-dashboard");
        Check("dashboard skill data-dashboard loads", skill.Contains("Dashboard") && !skill.Contains("Error"));

        Check("dashboard Create", tool.Create("/dashboard.xlsx"));
        var imp1 = tool.Import("/Sheet1", dataCsv, header: true);
        Check("dashboard import 20 sales rows", imp1.Contains("8 cols"));
        Check("dashboard rename Sheet1 to Data", tool.Set("/Sheet1", new[] { "name=Data" }).StartsWith("Updated"));
        Check("dashboard Data tabColor", tool.Set("/Data", new[] { "tabColor=4472C4" }).StartsWith("Updated"));
        foreach (var (col, w) in new[] { ("A", 18), ("B", 14), ("C", 10), ("D", 14), ("E", 14), ("F", 14), ("G", 14), ("H", 16) })
            tool.Set($"/Data/col[{col}]", new[] { $"width={w}" });
        Check("dashboard Data header fill", tool.Set("/Data/A1:H1", new[] { "fill=1F3864", "font.color=FFFFFF", "font.bold=true" }).StartsWith("Updated"));
        Check("dashboard Data money numFmt", tool.Set("/Data/D2:G21", new[] { "numberformat=$#,##0" }).StartsWith("Updated"));
        Check("dashboard Data percent numFmt", tool.Set("/Data/H2:H21", new[] { "numberformat=0.0%" }).StartsWith("Updated"));
        Check("dashboard CF dataBar Profit", tool.Add("/Data", "conditionalformatting", new[] { "type=dataBar", "ref=F2:F21", "color=4472C4" }).Contains("/Data/cf["));
        Check("dashboard CF colorScale Achievement", tool.Add("/Data", "conditionalformatting", new[] { "type=colorScale", "ref=H2:H21", "minColor=F8696B", "midColor=FFEB9C", "maxColor=63BE7B" }).Contains("/Data/cf["));

        Check("dashboard add Dashboard sheet", tool.Add("/", "sheet", new[] { "name=Dashboard", "tabColor=1B365D" }).Contains("/Dashboard"));
        for (var c = 'A'; c <= 'J'; c++) tool.Set($"/Dashboard/col[{c}]", new[] { "width=13" });
        Check("dashboard merged title", tool.Set("/Dashboard/A1", new[] { "value=Q4 2025 Global Sales Dashboard", "merge=A1:J1", "font.size=16", "bold=true", "font.color=1B365D" }).StartsWith("Updated"));
        var kpis = new (string Col, string Pair, string Label, string Formula, string Fmt)[]
        {
            ("A", "B", "Total Revenue", "SUM(Data!D2:D21)", "$#,##0"),
            ("C", "D", "Total Profit", "SUM(Data!F2:F21)", "$#,##0"),
            ("E", "F", "Avg Deal Size", "ROUND(AVERAGE(Data!D2:D21),0)", "$#,##0"),
            ("G", "H", "Avg Achievement", "AVERAGE(Data!H2:H21)", "0.0%"),
        };
        foreach (var (col, pair, label, formula, fmt) in kpis)
        {
            Check($"dashboard KPI label {label}", tool.Set($"/Dashboard/{col}3", new[]
            {
                $"value={label}", $"merge={col}3:{pair}3",
                "font.size=9", "font.color=666666", "bold=true",
            }).StartsWith("Updated"));
            Check($"dashboard KPI {label}", tool.Set($"/Dashboard/{col}4", new[]
            {
                $"formula=={formula}", $"merge={col}4:{pair}5",
                "font.size=24", "bold=true", $"numberformat={fmt}", "font.color=2E7D32",
            }).StartsWith("Updated"));
        }

        Check("dashboard add Summary sheet", tool.Add("/", "sheet", new[] { "name=Summary" }).Contains("/Summary"));
        tool.Set("/Summary/col[A]", new[] { "width=10" });
        tool.Set("/Summary/col[B]", new[] { "width=14" });
        tool.Set("/Summary/col[D]", new[] { "width=12" });
        tool.Set("/Summary/col[E]", new[] { "width=14" });
        tool.Set("/Summary/A1", new[] { "value=Month", "bold=true" });
        tool.Set("/Summary/B1", new[] { "value=Revenue", "bold=true" });
        tool.Set("/Summary/A2", new[] { "value=Oct" });
        tool.Set("/Summary/B2", new[] { "formula==SUMIF(Data!$C$2:$C$21,\"Oct\",Data!$D$2:$D$21)", "numberformat=$#,##0" });
        tool.Set("/Summary/A3", new[] { "value=Nov" });
        tool.Set("/Summary/B3", new[] { "formula==SUMIF(Data!$C$2:$C$21,\"Nov\",Data!$D$2:$D$21)", "numberformat=$#,##0" });
        tool.Set("/Summary/D1", new[] { "value=Product", "bold=true" });
        tool.Set("/Summary/E1", new[] { "value=Revenue", "bold=true" });
        tool.Set("/Summary/D2", new[] { "value=Enterprise" });
        tool.Set("/Summary/E2", new[] { "formula==SUMIF(Data!$B$2:$B$21,\"Enterprise\",Data!$D$2:$D$21)", "numberformat=$#,##0" });
        tool.Set("/Summary/D3", new[] { "value=SMB" });
        tool.Set("/Summary/E3", new[] { "formula==SUMIF(Data!$B$2:$B$21,\"SMB\",Data!$D$2:$D$21)", "numberformat=$#,##0" });
        tool.Set("/Summary/D4", new[] { "value=Consumer" });
        tool.Set("/Summary/E4", new[] { "formula==SUMIF(Data!$B$2:$B$21,\"Consumer\",Data!$D$2:$D$21)", "numberformat=$#,##0" });

        Check("dashboard chart Revenue by Month", tool.Add("/Dashboard", "chart", new[]
        {
            "chartType=column", "title=Revenue by Month",
            "series1.name=Revenue", "series1.values=Summary!B2:B3", "series1.categories=Summary!A2:A3",
            "x=1", "y=9", "width=10", "height=13",
        }).Contains("/chart["));
        Check("dashboard chart Revenue Share", tool.Add("/Dashboard", "chart", new[]
        {
            "chartType=doughnut", "title=Revenue Share by Product",
            "series1.name=Share", "series1.values=Summary!E2:E4", "series1.categories=Summary!D2:D4",
            "x=12", "y=9", "width=10", "height=13",
        }).Contains("/chart["));

        Check("dashboard add Rankings sheet", tool.Add("/", "sheet", new[] { "name=Rankings", "tabColor=70AD47" }).Contains("/Rankings"));
        var imp2 = tool.Import("/Rankings", repsCsv, header: true);
        Check("dashboard import 10 reps", imp2.Contains("4 cols"));
        Check("dashboard Rankings header fill", tool.Set("/Rankings/A1:D1", new[] { "fill=1F3864", "font.color=FFFFFF", "font.bold=true" }).StartsWith("Updated"));
        tool.Set("/Rankings/col[A]", new[] { "width=20" });
        tool.Set("/Rankings/col[B]", new[] { "width=18" });
        tool.Set("/Rankings/col[C]", new[] { "width=14" });
        tool.Set("/Rankings/col[D]", new[] { "width=10" });
        Check("dashboard Rankings revenue numFmt", tool.Set("/Rankings/C2:C11", new[] { "numberformat=$#,##0" }).StartsWith("Updated"));

        Check("dashboard activeTab Dashboard", tool.Set("/", new[] { "activeTab=Dashboard" }).StartsWith("Updated"));
        Check("dashboard Save", tool.Save().Contains(".001.bak"));
        Check("dashboard Validate", tool.Validate().StartsWith("{") && !tool.Validate().Contains("Error"));
        var html = tool.ViewHtml();
        Check("dashboard HTML preview no ###", !html.Contains("###"));

        var dataXml = tool.Raw("/xl/worksheets/sheet1.xml");
        Check("dashboard Data freeze+autofilter", dataXml.Contains("pane") && dataXml.Contains("autoFilter"));
        Check("dashboard Summary col widths (no ###)", tool.Raw("/xl/worksheets/sheet3.xml").Contains("width=\"14\""));
        var kpi = tool.Get("/Dashboard/A4");
        Check("dashboard KPI formula+cache", kpi.Contains("SUM") && kpi.Contains("cachedValue") && kpi.Contains("\"evaluated\":true"));
        var chartQ = Parse(tool.Query("chart"));
        Check("dashboard 2 charts", chartQ?["results"] is JsonArray ca && ca.Count == 2);
        var cfQ = Parse(tool.Query("conditionalformatting"));
        Check("dashboard 2 CF rules", cfQ?["results"] is JsonArray cfa && cfa.Count >= 2);
        Check("dashboard Get activeTab", tool.Get("/").Contains("activeTab"));

        Check("dashboard reopen", tool.Open("/dashboard.xlsx"));
        Check("dashboard 4 sheets after reopen", tool.Query("sheet").Contains("Dashboard") && tool.Query("sheet").Contains("Rankings"));
    }

    static void RunOffice(OfficeTool tool)
    {
        // Designed 3-slide deck (vendor pitch-deck style, not the bare smoke
        // workflow): full-bleed navy cover with big title (>=36pt) + gold accent
        // bar, a stats slide with three callout cards, and a closing slide.
        // Palette: 1B365D navy / 4472C4 blue / FFC000 gold / F0F4FF card / 666666 label.
        Check("office Create deck", tool.Create("/deck.pptx"));
        for (var s = 1; s <= 3; s++)
            Check($"office add slide {s}", tool.Add("/", "slide").Contains($"/slide[{s}]"));

        // slide 1 — cover
        Check("office cover bg", tool.Add("/slide[1]", "shape", new[]
        { "fill=1B365D", "x=0", "y=0", "w=13.33in", "h=7.5in" }).Contains("/slide[1]/shape["));
        tool.Add("/slide[1]", "shape", new[] { "fill=FFC000", "x=1in", "y=2.55in", "w=1.6in", "h=0.09in" });
        Check("office cover title 44pt", tool.Add("/slide[1]", "shape", new[]
        { "text=Q4 2025 Strategy Review", "size=44pt", "bold=true", "color=FFFFFF",
          "x=1in", "y=2.75in", "w=11.3in", "h=1.3in" }).Contains("/slide[1]/shape["));
        tool.Add("/slide[1]", "shape", new[]
        { "text=Growth / Profit / Outlook", "size=18pt", "color=8FAADC",
          "x=1in", "y=4.2in", "w=9in", "h=0.6in" });
        tool.Add("/slide[1]", "shape", new[]
        { "text=AIOffice - built with OfficeTool", "size=10pt", "color=5B7DB1",
          "x=1in", "y=6.9in", "w=6in", "h=0.35in" });

        // slide 2 — stat callouts (numbers tied to the dashboard data)
        Check("office stats band", tool.Add("/slide[2]", "shape", new[]
        { "fill=1B365D", "x=0", "y=0", "w=13.33in", "h=1.5in" }).Contains("/slide[2]/shape["));
        tool.Add("/slide[2]", "shape", new[]
        { "text=FY25 at a Glance", "size=32pt", "bold=true", "color=FFFFFF",
          "x=0.9in", "y=0.42in", "w=9in", "h=0.7in" });
        var stats = new (string X, string Num, string Label)[]
        {
            ("1in",    "$4.7M", "Revenue"),
            ("4.75in", "$1.7M", "Profit"),
            ("8.5in",  "100.5%", "Avg Achievement"),
        };
        foreach (var (x, num, label) in stats)
        {
            tool.Add("/slide[2]", "shape", new[]
            { "geometry=roundRect", "fill=F0F4FF", $"x={x}", "y=2.2in", "w=3.55in", "h=3.3in" });
            Check($"office stat {label}", tool.Add("/slide[2]", "shape", new[]
            { $"text={num}", "size=44pt", "bold=true", "color=1B365D",
              $"x={x}", "y=2.7in", "w=3.55in", "h=1in" }).Contains("/slide[2]/shape["));
            tool.Add("/slide[2]", "shape", new[]
            { $"text={label}", "size=14pt", "color=666666",
              $"x={x}", "y=4.1in", "w=3.55in", "h=0.6in" });
        }

        // slide 3 — closing
        Check("office closing bg", tool.Add("/slide[3]", "shape", new[]
        { "fill=1B365D", "x=0", "y=0", "w=13.33in", "h=7.5in" }).Contains("/slide[3]/shape["));
        tool.Add("/slide[3]", "shape", new[] { "fill=FFC000", "x=5.85in", "y=3.05in", "w=1.6in", "h=0.09in" });
        Check("office closing title", tool.Add("/slide[3]", "shape", new[]
        { "text=Thank you", "size=48pt", "bold=true", "color=FFFFFF", "align=center",
          "x=0", "y=2.35in", "w=13.33in", "h=1.1in" }).Contains("/slide[3]/shape["));
        tool.Add("/slide[3]", "shape", new[]
        { "text=Questions welcome", "size=18pt", "color=8FAADC", "align=center",
          "x=0", "y=3.55in", "w=13.33in", "h=0.6in" });

        Check("office Save", tool.Save().Contains(".001.bak"));
        Check("office Validate", tool.Validate().StartsWith("{") && !tool.Validate().Contains("Error"));
        var outline = Parse(tool.ViewOutline());
        Check("office outline 3 slides", outline?["totalSlides"]?.GetValue<int>() == 3);
        var slide1 = tool.Get("/slide[1]");
        Check("office cover big title + brand", slide1.Contains("44pt") && slide1.Contains("Strategy Review") && slide1.Contains("1B365D"));
        var shapes = Parse(tool.Query("shape"));
        Check("office 14+ shapes", shapes?["results"] is JsonArray sa && sa.Count >= 14);
        Check("office ViewSvg slide 1", tool.ViewSvg(1).Contains("<svg"));
        Check("office reopen", tool.Open("/deck.pptx") && Parse(tool.ViewOutline())?["totalSlides"]?.GetValue<int>() == 3);
    }

    static void RunWord(OfficeTool tool)
    {
        // Designed one-page report (vendor docx showcase style, not the bare
        // smoke workflow): document props, Title + lead, Heading1 sections with
        // explicit sizes, a bulleted list, a styled data table and a footer with
        // a live page-number field. Palette: 1B365D navy / 1F6FEB accent /
        // 666666 label — the same family as the dashboard and deck demos.
        Check("word Create demo", tool.Create("/demo.docx"));

        var setDoc = tool.Set("/", new[]
        {
            "title=Q4 2025 Sales Review", "author=AIOffice Demo",
            "docDefaults.font=Georgia", "docDefaults.fontSize=12",
            "theme.color.accent1=1F6FEB",
        });
        Check("word doc props", !setDoc.Contains("Skipped unsupported"));

        Check("word title", tool.Add("/body", "paragraph", new[]
        {
            "text=Q4 2025 Sales Review", "style=Title", "size=28pt", "bold=true",
            "color=1B365D", "spaceAfter=4pt",
        }).Contains("/body/p["));
        Check("word lead", tool.Add("/body", "paragraph", new[]
        {
            "text=Prepared by the OfficeTool agent — no templates, no manual editing.",
            "size=11pt", "color=666666", "spaceAfter=14pt",
        }).Contains("/body/p["));

        Check("word H1 highlights", tool.Add("/body", "paragraph", new[]
        {
            "text=Highlights", "style=Heading1", "size=18pt", "bold=true",
            "color=1B365D", "spaceBefore=14pt", "spaceAfter=6pt",
        }).Contains("/body/p["));
        Check("word body paragraph", tool.Add("/body", "paragraph", new[]
        {
            "text=Revenue grew 18% year-over-year, ahead of plan, on strong enterprise renewals and a new EMEA region.",
            "size=12pt", "spaceAfter=8pt",
        }).Contains("/body/p["));
        foreach (var item in new[] { "Enterprise renewals up 24%", "EMEA opened with 3 anchor accounts", "Margin held at 36% despite FX headwinds" })
            Check("word bullet", tool.Add("/body", "paragraph", new[]
            {
                $"text={item}", "listStyle=bullet", "size=12pt",
            }).Contains("/body/p["));

        Check("word H1 results", tool.Add("/body", "paragraph", new[]
        {
            "text=Quarterly Results", "style=Heading1", "size=18pt", "bold=true",
            "color=1B365D", "spaceBefore=14pt", "spaceAfter=6pt",
        }).Contains("/body/p["));

        Check("word table", tool.Add("/body", "table", new[]
        {
            "data=Metric,Q3,Q4,Change;Revenue,4.02M,4.68M,+16%;Profit,1.42M,1.68M,+18%;Avg Achievement,97%,100.5%,+3.5pts",
            "width=100%",
        }).Contains("/body/tbl["));
        foreach (var (c, h) in new[] { ("1", "Metric"), ("2", "Q3"), ("3", "Q4"), ("4", "Change") })
            tool.Set($"/body/tbl[1]/tr[1]/tc[{c}]", new[] { $"text={h}", "bold=true", "color=FFFFFF", "fill=1B365D" });
        Check("word table header", tool.Get("/body/tbl[1]/tr[1]/tc[1]").Contains("Metric"));
        Check("word table cell text", NodeText(tool.Get("/body/tbl[1]/tr[2]/tc[2]")) == "4.02M");

        Check("word footer", tool.Add("/", "footer", new[] { "type=default", "align=center", "size=9pt", "text=Page ", "field=page" }).Contains("footer"));

        Check("word Save", tool.Save().Contains(".001.bak"));
        Check("word Validate", tool.Validate().StartsWith("{") && !tool.Validate().Contains("Error"));
        var outline = tool.ViewOutline();
        Check("word outline", outline.Contains("Highlights") && outline.Contains("Quarterly Results"));
        Check("word stats", tool.ViewStats().StartsWith("{") && !tool.ViewStats().Contains("Error"));
        var tblQ = Parse(tool.Query("table"));
        Check("word 1 table", tblQ?["results"] is JsonArray ta && ta.Count == 1);
        Check("word bullets text", tool.Query("paragraph").Contains("Enterprise renewals up 24%"));
        Check("word reopen", tool.Open("/demo.docx") && tool.Query("paragraph").Contains("Highlights"));
    }

    static void RunHelp(OfficeTool tool)
    {
        var h1 = tool.Help("docx", "paragraph");
        Check("Help docx paragraph → schema JSON", h1.StartsWith("{") && h1.Contains("\"properties\""));
        Check("Help xlsx → element list", tool.Help("xlsx").Contains("\"elements\""));
        Check("Help unknown format → Error", tool.Help("bogus").Contains("Error"));
        Check("Help unknown element → Error", tool.Help("docx", "bogus").Contains("Error"));
        Check("Help no args → formats", tool.Help().Contains("docx"));
    }

    private static void Check(string name, bool ok)
    {
        _index++;
        if (_filter != null && !name.Contains(_filter, StringComparison.OrdinalIgnoreCase)) { _skipped++; return; }
        if (_range is { } r && (_index < r.From || _index > r.To)) { _skipped++; return; }
        _total++;
        Console.WriteLine($"{(ok ? "✓" : "✗")} {name}");
        if (!ok) _failures++;
    }

    private static string? Arg(string[] args, string key)
    {
        var i = Array.IndexOf(args, key);
        return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
    }

    private static (int From, int To)? ParseRange(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return null;
        var parts = s.Split('-');
        return parts.Length == 2 && int.TryParse(parts[0], out var a) && int.TryParse(parts[1], out var b)
            ? (Math.Min(a, b), Math.Max(a, b))
            : null;
    }

    private static JsonObject? Parse(string json) =>
        json.StartsWith("{") ? JsonSerializer.Deserialize<JsonObject>(json) : null;

    private static string? NodeText(string getJson) => Node(getJson)?["text"]?.ToString();

    private static JsonNode? Node(string getJson)
    {
        var obj = Parse(getJson);
        return obj?["results"] is JsonArray { Count: > 0 } arr ? arr[0] : null;
    }

    /// <summary>LLM scenario: the agent builds a presentation with OfficeTool only.</summary>
    static int RunAgentScenario()
    {
        Console.WriteLine("╔══════════════════════════════════════════════════════╗");
        Console.WriteLine("║  OfficeTool test — agent-built PPTX pitch deck        ║");
        Console.WriteLine("╚══════════════════════════════════════════════════════╝");
        Log.IsEnabled = true;
        Log.LogStep("=== OfficeTool.Tests agent scenario (PPTX pitch deck) ===");

        var providerName = "DeepSeekBridge";
        _workspace = Path.Combine(Path.GetTempPath(), "OfficeTool.Tests-workspace");
        if (Directory.Exists(_workspace)) Directory.Delete(_workspace, recursive: true);
        Directory.CreateDirectory(_workspace);
        Setup.SkipIndexingOnStartup = true;
        Setup.DocumentsPath = _workspace;
        Setup.ProviderConfig = ProviderConfigs.Get(providerName);
        var orch = new AgentOrchestrator(providerName);
        try
        {
            var task = Task.Run(() => orch.ExecuteAction(
                "Build a 3-slide presentation /deck.pptx with OfficeTool. " +
                "FIRST call LoadSkill(\"pitch-deck\") to load the vendor pitch-deck guidance and follow its layout rules " +
                "(title ≥ 36pt, 12-column grid, palette, slide recipes). " +
                "Then: slide 1 cover title 'Quarterly Review', " +
                "slide 2 three stat callouts about revenue, costs, outlook, slide 3 a closing shape with text 'Thank you'. " +
                "Then Save().",
                new[] { "OfficeTool" },
                maxIterations: 40));
            var result = task.GetAwaiter().GetResult();
            Console.WriteLine($"\nAgent final message:\n{result.Message}\n");
            Console.WriteLine(result.Error != null ? $"Agent reported error: {result.Error}" : "");
            Console.WriteLine($"Outcome: {(result.Success ? "✓ SUCCESS" : $"✗ {result.Code}")} ({result.Iterations} iterations, {result.TotalElapsedMs / 1000}s)");

            if (!result.Success || !File.Exists(Path.Combine(_workspace, "deck.pptx")))
            {
                Console.WriteLine("✗ deck.pptx not produced.");
                return 1;
            }
            using var tool = new OfficeTool();
            var ok = tool.Open("/deck.pptx");
            Console.WriteLine(ok ? "✓ reopened deck.pptx" : "✗ cannot reopen deck.pptx");
            var outline = Parse(tool.ViewOutline());
            var slides = outline?["totalSlides"]?.GetValue<int>() ?? 0;
            Console.WriteLine($"Slides: {slides}  (expect 3)");
            return ok && slides >= 3 ? 0 : 1;
        }
        finally
        {
            orch.Dispose();
        }
    }

    /// <summary>
    /// LLM scenario — the real agent at work, no scripting: same prompt pattern,
    /// same skill (officecli-data-dashboard, vendored identically) and the same
    /// real CSV the vendor showcase is built from. The model decides every
    /// tool call; the harness only verifies the produced document afterwards.
    /// </summary>
    static int RunAgentDashboardScenario()
    {
        Console.WriteLine("╔══════════════════════════════════════════════════════════╗");
        Console.WriteLine("║  OfficeTool test — agent-built sales dashboard (xlsx)     ║");
        Console.WriteLine("╚══════════════════════════════════════════════════════════╝");
        Log.IsEnabled = true;
        Log.LogStep("=== OfficeTool.Tests agent scenario (sales dashboard, real CSV) ===");

        var providerName = "DeepSeekBridge";
        _workspace = Path.Combine(Path.GetTempPath(), "OfficeTool.Tests-workspace");
        if (Directory.Exists(_workspace)) Directory.Delete(_workspace, recursive: true);
        Directory.CreateDirectory(_workspace);
        Setup.SkipIndexingOnStartup = true;
        Setup.DocumentsPath = _workspace;
        Setup.ProviderConfig = ProviderConfigs.Get(providerName);

        // Context data — the exact 20 sales rows of the vendor showcase workbook.
        File.WriteAllText(Path.Combine(_workspace, "sales-data.csv"), SalesDataCsv);

        var orch = new AgentOrchestrator(providerName);
        try
        {
            var task = Task.Run(() => orch.ExecuteAction(
                "Build a sales dashboard /dashboard.xlsx with OfficeTool from the context file /sales-data.csv " +
                "(20 rows, columns: Region,Product,Month,Revenue,Cost,Profit,Target,Achievement%). " +
                "FIRST call LoadSkill(\"data-dashboard\") and follow it: a Dashboard sheet the user lands on " +
                "with formula-driven KPI cards (Total Revenue, Total Profit, Avg Deal Size, Avg Achievement), " +
                "two charts with titles and named series (month revenue and product share), a Data sheet with " +
                "the imported CSV (freeze, autofilter, conditional formatting on Profit and Achievement%), " +
                "tab colors, and activeTab set to the Dashboard sheet. Then Save().",
                new[] { "OfficeTool" },
                maxIterations: 80));
            var result = task.GetAwaiter().GetResult();
            Console.WriteLine($"\nAgent final message:\n{result.Message}\n");
            Console.WriteLine(result.Error != null ? $"Agent reported error: {result.Error}" : "");
            Console.WriteLine($"Outcome: {(result.Success ? "✓ SUCCESS" : $"✗ {result.Code}")} ({result.Iterations} iterations, {result.TotalElapsedMs / 1000}s)");

            var file = Path.Combine(_workspace, "dashboard.xlsx");
            if (!result.Success || !File.Exists(file))
            {
                Console.WriteLine("✗ dashboard.xlsx not produced.");
                return 1;
            }
            Console.WriteLine($"✓ dashboard.xlsx produced ({new FileInfo(file).Length} bytes)");

            using var tool = new OfficeTool();
            var ok = tool.Open("/dashboard.xlsx");
            if (!ok) { Console.WriteLine("✗ cannot reopen dashboard.xlsx"); return 1; }
            var sheets = tool.Query("sheet");
            Console.WriteLine($"Sheets: {sheets.Contains("Dashboard")} — Dashboard present: {sheets.Contains("Dashboard")}");
            // Vendor skill Gate 1: KPI formula coverage on the Dashboard sheet (layout-agnostic).
            var kpiQ = Parse(tool.Query("Dashboard!:has(formula)"));
            var kpiCount = kpiQ?["results"] is JsonArray ka ? ka.Count : 0;
            Console.WriteLine($"KPI formula cells on Dashboard: {kpiCount}  (expect >= 4)");
            // Vendor skill Gate 8 (workbook-wide, layout-agnostic): somewhere a SUM
            // over the Revenue column must carry a LIVE cached value (4,682,000).
            // Catches column shifts (wrong-column SUM) and stale caches (correct
            // formula with cachedValue 0 — "zero is broken" per the skill).
            var cells = new List<string>();
            if (kpiQ?["results"] is JsonArray kArr)
                foreach (var n in kArr) if (n?["path"]?.ToString() is { } p0) cells.Add(p0);
            if (Parse(tool.Query("sheet"))?["results"] is JsonArray shArr)
            {
                foreach (var s in shArr)
                {
                    var sp = s?["path"]?.ToString();
                    if (sp == null) continue;
                    var sq = Parse(tool.Query($"{sp.TrimStart('/')}!:has(formula)"));
                    if (sq?["results"] is JsonArray fArr)
                        foreach (var fn in fArr) if (fn?["path"]?.ToString() is { } p1) cells.Add(p1);
                }
            }
            var right = 0;
            foreach (var p in cells.Distinct())
            {
                var cell = tool.Get(p);
                if (!cell.Contains("formula")) continue;
                Console.WriteLine($"   formula cell {p}: {cell.Replace("\n", "")[..Math.Min(160, cell.Length)]}");
                if (cell.Contains("D2:D21") && cell.Contains("4682000")) right++;
            }
            Console.WriteLine($"Revenue SUM cells with live cache 4,682,000: {right}");
            var charts = Parse(tool.Query("chart"));
            var chartCount = charts?["results"] is JsonArray ca ? ca.Count : 0;
            Console.WriteLine($"Charts: {chartCount}  (expect >= 1)");
            var wb = tool.Get("/");
            var hasActiveTab = wb.Contains("activeTab");
            var tabsWithColor = 0;
            if (Parse(tool.Query("sheet"))?["results"] is JsonArray shC)
                foreach (var s in shC)
                    if (s?["path"]?.ToString() is { } spC && tool.Get(spC).Contains("tabColor")) tabsWithColor++;
            Console.WriteLine($"activeTab set: {(hasActiveTab ? "✓" : "✗ not set (file opens on the first sheet)")}");
            Console.WriteLine($"Sheets with tabColor: {tabsWithColor}  (expect >= 1)");
            Console.WriteLine($"Validate: {(tool.Validate().Contains("\"errors\":[]") ? "✓ clean" : "see output")}");
            return sheets.Contains("Dashboard") && kpiCount >= 4 && right >= 1 && chartCount >= 1 && hasActiveTab && tabsWithColor >= 1 ? 0 : 1;
        }
        finally
        {
            orch.Dispose();
        }
    }
}
