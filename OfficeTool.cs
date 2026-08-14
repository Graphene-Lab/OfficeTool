using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using OfficeCli;
using OfficeCli.Core;
using OfficeCli.Handlers;
using OfficeCli.Help;

namespace AIOrchestrator.API
{
    /// <summary>
    /// Office document (DOCX/XLSX/PPTX) operations for agent use: create/open, view (outline/text/annotated/stats/issues),
    /// get/query (path-based DOM), set/add/remove/move/swap, validate, batch, schema help, save/restore.
    /// ONE document open at a time: Open()/Create() replaces the current one; Save() persists with a numbered backup,
    /// Restore() reverts to the most recent backup.
    /// File paths are Unix-style relative to the workspace root (leading "/") — never escape it.
    /// Document paths use officecli syntax (e.g. /slide[1]/shape[2], 1-based); Get()/Query() produce them.
    /// Call Help(format, element) first when unsure about property names or value formats.
    /// Results are JSON (officecli --json envelope shape); failures return "Error: &lt;cause&gt;. &lt;fix&gt;. [valid values]".
    /// </summary>
    public class OfficeTool : BaseAgentTool, IDisposable, ILocalDesktopCapable, IFileTool
    {
        private IDocumentHandler? _handler;
        private string _filePath = string.Empty;
        private OfficeCli.Core.WatchServer? _watch;
        private CancellationTokenSource? _watchCts;
        private Task? _watchTask;

        /// <summary>
        /// Whether desktop-only methods (Watch/Unwatch/Goto/GetSelected/Mark) are allowed.
        /// Set by the orchestrator from isLocalUser + interactive desktop session. Default false.
        /// </summary>
        public bool IsWatchAllowed { get; set; }

        /// <summary>
        /// Parameterless constructor for agent activation. Call <see cref="Open"/> or <see cref="Create"/>
        /// before using other methods.
        /// </summary>
        public OfficeTool()
        {
        }

        /// <summary>
        /// Opens an existing Office document (docx/xlsx/pptx) for editing and replaces the current one.
        /// </summary>
        /// <param name="filePath">Path to an existing .docx/.xlsx/.pptx file (Unix style, e.g. "/folder/file.docx"),
        /// relative to the workspace root. Absolute Windows paths are accepted only inside the sandbox.</param>
        /// <returns>True if the file was opened successfully.</returns>
        public bool Open(string filePath)
        {
            try
            {
                _handler?.Dispose();
                var resolved = SandboxPath.Resolve(filePath);
                _handler = DocumentHandlerFactory.Open(resolved, editable: true);
                _filePath = resolved;
                Log.LogStep($"OfficeTool.Open: opened '{resolved}'");
                return true;
            }
            catch (Exception ex)
            {
                _handler?.Dispose();
                _handler = null;
                _filePath = string.Empty;
                Log.LogStep($"OfficeTool.Open: failed '{filePath}': {ex.Message}");
                return false;
            }
        }

        /// <summary>
        /// Creates a new blank Office document (docx/xlsx/pptx) on THIS instance and saves it.
        /// The format is determined by the file extension. Must be an instance method: the agent loop keeps
        /// ONE shared instance in its agents dictionary.
        /// </summary>
        /// <param name="filePath">Path where the new document is saved (Unix style, e.g. "/folder/deck.pptx"),
        /// relative to the workspace root. Extension must be .docx, .xlsx or .pptx.</param>
        /// <returns>True when the document was created and saved.</returns>
        public bool Create(string filePath)
        {
            try
            {
                var resolved = SandboxPath.Resolve(filePath);
                var ext = Path.GetExtension(resolved).ToLowerInvariant();
                if (ext is not (".docx" or ".xlsx" or ".pptx"))
                    return false;
                _handler?.Dispose();
                BlankDocCreator.Create(resolved, locale: null, minimal: false);
                _handler = DocumentHandlerFactory.Open(resolved, editable: true);
                _filePath = resolved;
                Log.LogStep($"OfficeTool.Create: created '{resolved}'");
                return true;
            }
            catch (Exception ex)
            {
                _handler?.Dispose();
                _handler = null;
                _filePath = string.Empty;
                Log.LogStep($"OfficeTool.Create: failed '{filePath}': {ex.Message}");
                return false;
            }
        }

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

        /// <summary>Gets the current file path of this document (host form), or null if not loaded.</summary>
        public string? FilePath => string.IsNullOrEmpty(_filePath) ? null : _filePath;

        /// <summary>
        /// Explicit interface implementation — NOT an agent tool (the orchestrator disposes agents
        /// automatically when the loop ends). Persists any unsaved changes first (with a numbered backup),
        /// then releases the document handler.
        /// </summary>
        void IDisposable.Dispose()
        {
            try
            {
                if (_handler != null && !string.IsNullOrEmpty(_filePath))
                {
                    var backupName = CreateBackup(_filePath);
                    _handler.Save();
                    Log.LogStep(backupName == null
                        ? $"OfficeTool.Dispose: auto-saved '{_filePath}' (new file, no backup)"
                        : $"OfficeTool.Dispose: auto-saved '{_filePath}' (backup '{backupName}')");
                }
            }
            catch (Exception ex)
            {
                Log.LogStep($"OfficeTool.Dispose: auto-save failed — {ex.Message}");
            }
            StopWatch();
            _handler?.Dispose();
        }

        // ──────────────────────────────
        //  L1 — Semantic view
        // ──────────────────────────────

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

        /// <summary>
        /// Document statistics as JSON (paragraphs/cells/slides counts, page size, style usage...).
        /// </summary>
        /// <returns>JSON stats, or "Error:" when no document is open.</returns>
        public string ViewStats()
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() => _handler!.ViewAsStatsJson().ToJsonString());
        }

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

        // ──────────────────────────────
        //  L2 — DOM operations
        // ──────────────────────────────

        /// <summary>
        /// Reads an element (and children down to the given depth) at a document path, as JSON.
        /// Paths use officecli syntax: /slide[1]/shape[2], /body/p[1], /Sheet1/A1 (1-based), or a selector
        /// like paragraph[style=Heading1]. Use "/" for the document root.
        /// </summary>
        /// <param name="path">Document path in officecli syntax (produced by ViewOutline/Query).</param>
        /// <param name="depth">How many levels of children to include (default 1).</param>
        /// <returns>JSON envelope {matches, results: [...]}, or "Error:" when the path is not found.</returns>
        public string Get(string path, int depth = 1)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() =>
            {
                var node = _handler!.Get(path, depth);
                if (string.Equals(node.Type, "error", StringComparison.Ordinal))
                {
                    var err = node.Text ?? $"Path not found: {path}";
                    throw new CliException(err) { Code = "not_found" };
                }
                return Json(new { matches = 1, results = new[] { node } });
            });
        }

        /// <summary>
        /// Queries all elements matching a CSS-like selector, as JSON. Selectors address elements by type,
        /// attribute values and position, e.g. shape[text~=quarter], paragraph[style=Heading1], row[2].
        /// </summary>
        /// <param name="selector">Selector in officecli syntax (see Help for the selector reference).</param>
        /// <returns>JSON envelope {matches, results: [...]}, or "Error:" when the selector is invalid.</returns>
        public string Query(string selector)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() =>
            {
                var nodes = _handler!.Query(selector);
                return Json(new { matches = nodes.Count, results = nodes });
            });
        }

        /// <summary>
        /// Modifies element properties at the given document path. Accepts selectors and Excel-native paths
        /// (parity with Get/Query). Any XML attribute is settable.
        /// Call Help(format, element) first when unsure about property names or value formats.
        /// </summary>
        /// <param name="path">Document path in officecli syntax (e.g. /body/p[1], 1-based; or a selector
        /// like paragraph[style=Heading1]). Produced by Get()/Query(). Use "/" for whole-document scope.</param>
        /// <param name="props">Properties as 'key=value' strings, e.g. ["align=center", "style=Heading1"].
        /// Accepts aliases (align/alignment/halign) and value formats: colors (FF0000, red, accent1),
        /// dimensions (2cm, 1in, 72pt, EMU), spacing (12pt, 1.5x, 150%). Dotted aliases allowed
        /// (font.color=red, revision.author=Alice). Full property list: Help(format, element).</param>
        /// <returns>Confirmation with the path (and any skipped unsupported properties), or "Error:".</returns>
        public string Set(string path, string[]? props = null)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() =>
            {
                var dict = ParseProps(props);
                var unsupported = _handler!.Set(path, dict);
                var result = unsupported.Count == 0
                    ? $"Updated {path}."
                    : $"Updated {path}. Skipped unsupported properties: {string.Join(", ", unsupported)}.";
                NotifyWatch();
                return result;
            });
        }

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
        /// <returns>The path of the new element, or "Error:".</returns>
        public string Add(string parentPath, string type, string[]? props = null, string? after = null, string? before = null, int? index = null, string? from = null)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() =>
            {
                var position = InsertPositionFor(after, before, index);
                var dict = ParseProps(props);
                var newPath = from != null
                    ? _handler!.CopyFrom(from, parentPath, position)
                    : _handler!.Add(parentPath, type, position, dict);
                NotifyWatch();
                return $"Added {newPath}.";
            });
        }

        /// <summary>
        /// Removes the element at the given document path.
        /// </summary>
        /// <param name="path">Document path to remove (e.g. /slide[2]/shape[3]).</param>
        /// <param name="props">Optional: for Word, trackChange.* keys record the removal as a revision
        /// (e.g. trackChange=on) instead of physically deleting. For xlsx, shift=left|up shifts cells.</param>
        /// <returns>Confirmation (with any warning), or "Error:".</returns>
        public string Remove(string path, string[]? props = null)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() =>
            {
                var warning = _handler!.Remove(path, ParseProps(props));
                var result = warning == null ? $"Removed {path}." : $"Removed {path}. {warning}";
                NotifyWatch();
                return result;
            });
        }

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

        // ──────────────────────────────
        //  Batch
        // ──────────────────────────────

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
        /// <returns>JSON envelope {success, data: {results, summary}} — outer success is true only when every
        /// step succeeded. Failures carry code+suggestion per item, or "Error:" when no document is open.</returns>
        public string Batch(string commandsJson, bool stopOnError = false)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() =>
            {
                var result = BatchExecutor.ExecuteBatch(_handler!, commandsJson, json: true, stopOnError);
                NotifyWatch();
                return result;
            });
        }

        // ──────────────────────────────
        //  L3 — Raw XML + parts
        // ──────────────────────────────

        /// <summary>
        /// Reads a raw OOXML part (document.xml, styles.xml, slide1.xml, sheet1.xml, ...) as XML text.
        /// Last resort when DOM operations cannot express the needed change.
        /// </summary>
        /// <param name="partPath">Part path, e.g. "/word/document.xml", "/ppt/slides/slide1.xml", "/xl/worksheets/sheet1.xml".</param>
        /// <param name="startRow">Optional: for sheet parts, first row to include.</param>
        /// <param name="endRow">Optional: for sheet parts, last row to include.</param>
        /// <param name="cols">Optional: for sheet parts, column filter.</param>
        /// <returns>The raw XML, or "Error:".</returns>
        public string Raw(string partPath, int? startRow = null, int? endRow = null, string[]? cols = null)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() => _handler!.Raw(partPath, startRow, endRow, ToHashSet(cols)));
        }

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

        // ──────────────────────────────
        //  Rendering / production
        // ──────────────────────────────

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

        private static OfficeCli.Core.Rendering.RenderOptions BuildRenderOptions(string formatId, string? page)
        {
            var options = new OfficeCli.Core.Rendering.RenderOptions();
            if (string.IsNullOrWhiteSpace(page)) return options;
            if (formatId == "pptx")
            {
                if (page.Contains('-'))
                {
                    var parts = page.Split('-', 2);
                    options = new OfficeCli.Core.Rendering.RenderOptions
                    {
                        StartPage = int.Parse(parts[0].Trim()),
                        EndPage = int.Parse(parts[1].Trim()),
                    };
                }
                else
                {
                    var p = int.Parse(page.Trim());
                    options = new OfficeCli.Core.Rendering.RenderOptions { StartPage = p, EndPage = p };
                }
            }
            else
            {
                options = new OfficeCli.Core.Rendering.RenderOptions { PageFilter = page };
            }
            return options;
        }

        // ──────────────────────────────
        //  Desktop watch (local session only)
        // ──────────────────────────────

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

        /// <summary>
        /// Stops the watch preview server started by <see cref="Watch"/>.
        /// </summary>
        /// <returns>Confirmation, or "Error:".</returns>
        public string Unwatch()
        {
            if (_watch == null) return "No watch is running.";
            return Exec(() =>
            {
                StopWatch();
                return "Watch stopped.";
            });
        }

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

        // ──────────────────────────────
        //  Screenshot
        // ──────────────────────────────

        /// <summary>
        /// Renders the document to a PNG screenshot via a headless Chrome-family browser
        /// (Chrome/Edge/Chromium), closing the render→observe→correct loop for layout issues.
        /// </summary>
        /// <param name="filePath">Optional: where to save the .png (Unix style). When omitted, returns the
        /// path of a temp PNG.</param>
        /// <param name="page">Optional: page/slide to capture (e.g. "1", "1-3").</param>
        /// <param name="width">Optional: target width in px (default 1600, capped at 1920).</param>
        /// <param name="height">Optional: target height in px (default 1200).</param>
        /// <returns>The PNG workspace path, or "Error:" (no browser available).</returns>
        public string ViewScreenshot(string? filePath = null, string? page = null, int width = 1600, int height = 1200)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() =>
            {
                var formatId = Path.GetExtension(_filePath).TrimStart('.').ToLowerInvariant();
                var html = CommandBuilder.RenderViaRegistry(_handler!, formatId, BuildRenderOptions(formatId, page));
                if (html == null)
                    throw new CliException("Screenshot is only supported for .pptx, .xlsx and .docx files.")
                    { Code = "unsupported_type" };
                var tmpHtml = Path.Combine(Path.GetTempPath(), $"oec_shot_{Guid.NewGuid():N}.html");
                File.WriteAllText(tmpHtml, html);
                try
                {
                    string outPng;
                    if (string.IsNullOrWhiteSpace(filePath))
                    {
                        outPng = Path.Combine(Path.GetTempPath(), $"oec_shot_{Guid.NewGuid():N}.png");
                    }
                    else
                    {
                        outPng = SandboxPath.Resolve(filePath);
                        var dir = Path.GetDirectoryName(outPng);
                        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                    }
                    var result = OfficeCli.Core.HtmlScreenshot.Capture(tmpHtml, outPng, width, height);
                    if (!result.Ok)
                        throw new CliException(
                            $"Screenshot failed: {result.Error}. Requires a Chrome-family browser (Chrome/Edge/Chromium) installed on the host.")
                        { Code = "screenshot_unavailable" };
                    Log.LogStep($"OfficeTool.ViewScreenshot: wrote '{outPng}'");
                    return filePath != null
                        ? $"Screenshot saved to '{SandboxPath.ToAgent(outPng)}'."
                        : $"Screenshot saved to '{SandboxPath.ToAgent(outPng)}' (temp file).";
                }
                finally { File.Delete(tmpHtml); }
            });
        }

        /// <summary>
        /// Renders a slide of a PPTX document to SVG — officecli `view svg`.
        /// Returns the SVG markup for the requested slide, useful for inspecting precise
        /// geometry/layout before editing. PPTX only.
        /// </summary>
        /// <param name="page">Optional 1-based slide number to render (default 1).</param>
        /// <returns>SVG markup, or "Error:" (not a .pptx, or no document open).</returns>
        public string ViewSvg(int page = 1)
        {
            if (_handler == null) return NoDocumentError;
            return Exec(() =>
            {
                if (_handler is not PowerPointHandler)
                    throw new CliException("SVG rendering is only supported for .pptx files.") { Code = "unsupported_type" };
                var formatId = Path.GetExtension(_filePath).TrimStart('.').ToLowerInvariant();
                var svg = CommandBuilder.RenderViaRegistry(_handler!, formatId,
                    new OfficeCli.Core.Rendering.RenderOptions
                    { Output = OfficeCli.Core.Rendering.RenderOutputKind.Svg, StartPage = page });
                return svg ?? throw new CliException("SVG rendering is not available for this document.")
                {
                    Code = "unsupported_type",
                    ValidValues = ["pptx"],
                };
            });
        }

        // ──────────────────────────────
        //  Skills
        // ──────────────────────────────

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
                    return OfficeCli.Core.SkillInstaller.LoadSkillFile(parts[0], rel);
                }
                return OfficeCli.Core.SkillInstaller.LoadSkillContent(skill);
            }
            catch (ArgumentException ex) { return $"Error: {ex.Message}"; }
            catch (Exception ex) { return $"Error: {ex.Message}"; }
        }

        // ──────────────────────────────
        //  Schema help
        // ──────────────────────────────

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

        // ──────────────────────────────
        //  Helpers
        // ──────────────────────────────

        private const string NoDocumentError = "Error: No document open. Call Open(path) or Create(path) first.";
        private const string WatchGatedError = "Error: Watch requires a local desktop session. Use ViewHtml() instead.";

        /// <summary>Stops the watch server (if any) and releases its resources.</summary>
        private void StopWatch()
        {
            if (_watch == null) return;
            try
            {
                _watchCts?.Cancel();
                _watch.Dispose();
            }
            catch (Exception ex)
            {
                Log.LogStep($"OfficeTool.StopWatch: {ex.Message}");
            }
            _watch = null;
            _watchCts = null;
            _watchTask = null;
        }

        /// <summary>Best-effort live refresh of the watch preview after a mutation.</summary>
        private void NotifyWatch()
        {
            try
            {
                if (_watch == null || _handler == null) return;
                var formatId = Path.GetExtension(_filePath).TrimStart('.').ToLowerInvariant();
                var html = CommandBuilder.RenderViaRegistry(_handler, formatId, new OfficeCli.Core.Rendering.RenderOptions());
                if (html != null)
                    OfficeCli.Core.WatchNotifier.NotifyIfWatching(_filePath, new OfficeCli.Core.WatchMessage { Action = "full", FullHtml = html });
            }
            catch { /* watch notify is best-effort */ }
        }

        private string Exec(Func<string> action)
        {
            try { return action(); }
            catch (CliException ex) { return FormatCliError(ex); }
            catch (Exception ex)
            {
                Log.LogStep($"OfficeTool: {ex.GetType().Name}: {ex.Message}");
                return $"Error: {ex.Message}";
            }
        }

        private static string FormatCliError(CliException ex)
        {
            var msg = string.IsNullOrEmpty(ex.Message) ? "Operation failed" : ex.Message.TrimEnd('.', ' ');
            if (!string.IsNullOrEmpty(ex.Suggestion)) msg += $". {ex.Suggestion.TrimEnd('.', ' ')}";
            if (ex.ValidValues is { Length: > 0 }) msg += $". Valid values: {string.Join(", ", ex.ValidValues)}";
            if (!string.IsNullOrEmpty(ex.Help)) msg += $". {ex.Help}";
            return $"Error: {msg}.";
        }

        private static Dictionary<string, string> ParseProps(string[]? props)
        {
            var dict = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (props == null) return dict;
            foreach (var prop in props)
            {
                var eq = prop.IndexOf('=');
                if (eq <= 0)
                    throw new CliException($"Invalid property '{prop}': expected 'key=value' (e.g. text=Hello).")
                    { Code = "invalid_value" };
                dict[prop[..eq].Trim()] = prop[(eq + 1)..];
            }
            return dict;
        }

        private static InsertPosition? InsertPositionFor(string? after, string? before, int? index)
        {
            if (after != null) return InsertPosition.AfterElement(after);
            if (before != null) return InsertPosition.BeforeElement(before);
            if (index.HasValue) return InsertPosition.AtIndex(index.Value);
            return null;
        }

        private static HashSet<string>? ToHashSet(string[]? cols) => cols is { Length: > 0 } ? cols.ToHashSet(StringComparer.OrdinalIgnoreCase) : null;

        private static string Json(object value) => JsonSerializer.Serialize(value);

        /// <summary>Creates a numbered backup of the specified file (pattern filename.NNN.bak, never overwrites).</summary>
        private static string? CreateBackup(string filePath)
        {
            if (!File.Exists(filePath)) return null;
            var dir = Path.GetDirectoryName(filePath) ?? ".";
            var nameWithoutExt = Path.GetFileNameWithoutExtension(filePath);
            for (int i = 1; i <= 9999; i++)
            {
                var backupName = $"{nameWithoutExt}.{i:D3}.bak";
                if (!File.Exists(Path.Combine(dir, backupName)))
                {
                    File.Copy(filePath, Path.Combine(dir, backupName));
                    return backupName;
                }
            }
            var ts = DateTime.Now.ToString("yyyyMMddHHmmss");
            var fallbackName = $"{nameWithoutExt}.{ts}.bak";
            File.Copy(filePath, Path.Combine(dir, fallbackName));
            return fallbackName;
        }
    }
}
