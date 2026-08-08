const vscode = require("vscode");
const { execFile } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const SOURCE = "sley";
const MAX_BUFFER = 10 * 1024 * 1024;
const MAX_CONCURRENT_LINTS = 4;

function config() {
  return vscode.workspace.getConfiguration("sleyTools");
}

function mappedLanguages(filetype, languageMap) {
  return Array.isArray(languageMap[filetype]) ? languageMap[filetype] : [filetype];
}

function expandFiletypes(filetypes, languageMap) {
  const languages = new Set();
  for (const filetype of filetypes || []) {
    for (const language of mappedLanguages(filetype, languageMap)) {
      if (typeof language === "string" && language.length > 0) {
        languages.add(language);
      }
    }
  }
  return [...languages].sort();
}

function languageToFiletypes(languageMap) {
  const byLanguage = new Map();
  for (const filetype of Object.keys(languageMap || {})) {
    for (const language of mappedLanguages(filetype, languageMap)) {
      if (typeof language !== "string" || language.length === 0) continue;
      if (!byLanguage.has(language)) byLanguage.set(language, new Set());
      byLanguage.get(language).add(filetype);
    }
  }
  return byLanguage;
}

function providerSelector(filetypes, languageMap, phase) {
  const languages = expandFiletypes(filetypes?.[phase] || [], languageMap);
  const selectors = languages.map((language) => ({ scheme: "file", language }));

  // VS Code validates `editor.defaultFormatter` against the registered language
  // selector before it calls the provider. Keep explicit language selectors in
  // sync with Checkrun capabilities so generated `[json]`/`[python]` settings
  // do not warn that Sley cannot format those languages.
  if (selectors.length > 0) return selectors;

  // Capabilities can be unavailable in a fresh extension host; keep one broad
  // file selector so custom path-based filetypes can still be serviced after
  // `currentFiletypes()` refreshes Checkrun metadata.
  return [{ scheme: "file" }];
}

function run(command, args, cwd, timeoutMs, allowFailure = false, signal) {
  return new Promise((resolve, reject) => {
    execFile(
      command,
      args,
      {
        cwd,
        timeout: timeoutMs,
        maxBuffer: MAX_BUFFER,
        env: { ...process.env, SLEY_CALLER: "vscode" },
        signal,
      },
      (err, stdout, stderr) => {
        if (err && !allowFailure) {
          err.stdout = stdout;
          err.stderr = stderr;
          reject(err);
          return;
        }
        resolve({ stdout, stderr, err });
      },
    );
  });
}

async function capabilities(signal) {
  const checkrun = config().get("checkrunCommand") || "checkrun";
  try {
    const { stdout } = await run(
      checkrun,
      ["capabilities", "--json"],
      process.cwd(),
      5000,
      false,
      signal,
    );
    const parsed = JSON.parse(stdout);
    return {
      filetypes: parsed.filetypes || {},
      languageMap: parsed.editorLanguageIds?.vscode || {},
    };
  } catch (err) {
    console.error("sley-tools: checkrun capabilities unavailable", err);
    return { filetypes: {}, languageMap: {} };
  }
}

function hasCapabilities(filetypes) {
  return (filetypes.format || []).length > 0 || (filetypes.lint || []).length > 0;
}

function fullDocumentRange(document) {
  return new vscode.Range(document.positionAt(0), document.positionAt(document.getText().length));
}

function extname(filePath) {
  const base = path.basename(filePath);
  const dot = base.lastIndexOf(".");
  if (dot <= 0 || dot === base.length - 1) return "";
  return base.slice(dot + 1);
}

function escapeRegex(value) {
  return value.replace(/[|\\{}()[\]^$+?.]/g, "\\$&");
}

function globToRegExp(glob) {
  let pattern = "";
  for (const char of glob) {
    switch (char) {
      case "*":
        pattern += ".*";
        break;
      case "?":
        pattern += ".";
        break;
      default:
        pattern += escapeRegex(char);
        break;
    }
  }
  return new RegExp(`^${pattern}$`);
}

function matchesPattern(filePath, pattern) {
  const normalizedPath = filePath.replace(/\\/g, "/").split(path.sep).join("/");
  const normalizedPattern = String(pattern || "")
    .replace(/\\/g, "/")
    .split(path.sep)
    .join("/");
  const target = normalizedPattern.includes("/") ? normalizedPath : path.basename(normalizedPath);
  return globToRegExp(normalizedPattern).test(target);
}

function documentPathCandidates(document) {
  const filePath = document?.uri?.fsPath;
  if (typeof filePath !== "string" || filePath.length === 0) return [];

  const candidates = new Set([filePath, filePath.replace(/\\/g, "/")]);
  const workspaceFolder = vscode.workspace.getWorkspaceFolder?.(document.uri);
  const workspacePath = workspaceFolder?.uri?.fsPath;
  if (typeof workspacePath === "string" && workspacePath.length > 0) {
    const relative = path.relative(workspacePath, filePath);
    if (relative && !relative.startsWith("..") && !path.isAbsolute(relative)) {
      candidates.add(relative);
      candidates.add(relative.replace(/\\/g, "/"));
    }
  }
  return [...candidates];
}

function isDiagnosticExcluded(document, patterns) {
  if (!Array.isArray(patterns) || patterns.length === 0) return false;
  for (const candidate of documentPathCandidates(document)) {
    for (const pattern of patterns) {
      if (matchesPattern(candidate, pattern)) return true;
    }
  }
  return false;
}

function customFiletype(filePath, custom) {
  const base = path.basename(filePath);
  const filename = custom?.filename || {};
  if (typeof filename[base] === "string") return filename[base];

  const extension = custom?.extension || {};
  const ext = extname(filePath);
  if (ext && typeof extension[ext] === "string") return extension[ext];

  for (const rule of custom?.patterns || []) {
    if (!rule || typeof rule.filetype !== "string" || typeof rule.pattern !== "string") continue;
    if (rule.extensionlessOnly && ext) continue;
    if (matchesPattern(filePath, rule.pattern)) return rule.filetype;
  }
  return undefined;
}

function documentFiletypes(document, filetypes, byLanguage) {
  const detected = new Set();
  const byPath = customFiletype(document.uri.fsPath, filetypes.custom || {});
  if (byPath) detected.add(byPath);

  if (typeof document.languageId === "string" && document.languageId.length > 0) {
    detected.add(document.languageId);
    const mapped = byLanguage.get(document.languageId);
    if (mapped) {
      for (const filetype of mapped) detected.add(filetype);
    }
  }
  return detected;
}

function supports(document, filetypes, byLanguage, phase) {
  const supported = new Set(filetypes[phase] || []);
  for (const filetype of documentFiletypes(document, filetypes, byLanguage)) {
    if (supported.has(filetype)) return true;
  }
  return false;
}

function diagnosticRange(document, diagnostic) {
  const startLine = Math.max(0, (diagnostic.line || 1) - 1);
  const startCol = Math.max(0, (diagnostic.col || 1) - 1);
  const start = new vscode.Position(startLine, startCol);

  if (typeof diagnostic.end_line === "number" || typeof diagnostic.end_col === "number") {
    const endLine = Math.max(startLine, (diagnostic.end_line || diagnostic.line || 1) - 1);
    const endCol = Math.max(startCol + 1, (diagnostic.end_col || diagnostic.col || 1) - 1);
    return new vscode.Range(start, new vscode.Position(endLine, endCol));
  }

  if (startLine < document.lineCount) {
    return new vscode.Range(start, document.lineAt(startLine).range.end);
  }
  return new vscode.Range(start, start.translate(0, 1));
}

function severity(level) {
  switch (level) {
    case "error":
      return vscode.DiagnosticSeverity.Error;
    case "info":
      return vscode.DiagnosticSeverity.Information;
    case "hint":
      return vscode.DiagnosticSeverity.Hint;
    default:
      return vscode.DiagnosticSeverity.Warning;
  }
}

function parseDiagnostics(document, output) {
  const diagnostics = [];
  for (const line of String(output || "").split(/\r?\n/)) {
    if (!line.trim()) continue;
    let item;
    try {
      item = JSON.parse(line);
    } catch (_) {
      continue;
    }
    if (!item || typeof item.line !== "number") continue;

    const diagnostic = new vscode.Diagnostic(
      diagnosticRange(document, item),
      item.message || "Sley diagnostic",
      severity(item.severity),
    );
    diagnostic.source = item.source || SOURCE;
    if (item.code) diagnostic.code = item.code;
    diagnostics.push(diagnostic);
  }
  return diagnostics;
}

async function formatCopy(document, sley, timeoutMs) {
  const filePath = document.uri.fsPath;
  const dir = path.dirname(filePath);
  const tempDir = await fs.promises.mkdtemp(path.join(dir, ".sley-vscode-"));
  const tempFile = path.join(tempDir, path.basename(filePath));

  try {
    await fs.promises.writeFile(tempFile, document.getText());
    await run(sley, ["hook", "format-file", tempFile], dir, timeoutMs);
    return await fs.promises.readFile(tempFile, "utf8");
  } finally {
    await fs.promises.rm(tempDir, { recursive: true, force: true });
  }
}

async function activate(context) {
  const controller = new AbortController();
  let disposed = false;
  let activeLints = 0;
  const lintQueue = [];
  const inFlightLints = new Map();
  let cap = await capabilities(controller.signal);
  let filetypes = cap.filetypes;
  let languageMap = cap.languageMap;
  let byLanguage = languageToFiletypes(languageMap);
  let capabilitiesInFlight;
  const diagnostics = vscode.languages.createDiagnosticCollection(SOURCE);

  async function currentFiletypes() {
    if (!hasCapabilities(filetypes)) {
      if (!capabilitiesInFlight) {
        capabilitiesInFlight = capabilities(controller.signal)
          .then((next) => {
            cap = next;
            filetypes = cap.filetypes;
            languageMap = cap.languageMap;
            byLanguage = languageToFiletypes(languageMap);
          })
          .finally(() => {
            capabilitiesInFlight = undefined;
          });
      }
      await capabilitiesInFlight;
    }
    return filetypes;
  }

  const provider = {
    async provideDocumentFormattingEdits(document) {
      if (document.isUntitled || document.uri.scheme !== "file") return [];
      if (!supports(document, await currentFiletypes(), byLanguage, "format")) return [];

      const sley = config().get("command") || "sley";
      const timeoutMs = config().get("timeoutMs") || 10000;
      const before = document.getText();
      const after = await formatCopy(document, sley, timeoutMs);

      if (after === before) return [];
      return [vscode.TextEdit.replace(fullDocumentRange(document), after)];
    },
  };
  context.subscriptions.push(
    vscode.languages.registerDocumentFormattingEditProvider(
      providerSelector(filetypes, languageMap, "format"),
      provider,
    ),
  );

  async function lint(document, version) {
    if (
      document.isUntitled ||
      document.uri.scheme !== "file" ||
      isDiagnosticExcluded(document, config().get("diagnosticExclude")) ||
      !supports(document, await currentFiletypes(), byLanguage, "lint")
    ) {
      diagnostics.delete(document.uri);
      return;
    }

    const sley = config().get("command") || "sley";
    const timeoutMs = config().get("timeoutMs") || 10000;
    const filePath = document.uri.fsPath;
    const { stdout } = await run(
      sley,
      ["hook", "lint-file", "--json", filePath],
      path.dirname(filePath),
      timeoutMs,
      true,
      controller.signal,
    );
    if (!disposed && (typeof version !== "number" || document.version === version)) {
      diagnostics.set(document.uri, parseDiagnostics(document, stdout));
    }
  }

  function pumpLintQueue() {
    while (!disposed && activeLints < MAX_CONCURRENT_LINTS && lintQueue.length > 0) {
      const { task, resolve, reject } = lintQueue.shift();
      activeLints += 1;
      Promise.resolve()
        .then(task)
        .then(resolve, reject)
        .finally(() => {
          activeLints -= 1;
          pumpLintQueue();
        });
    }
  }

  function withLintSlot(task) {
    if (disposed) return Promise.resolve();
    return new Promise((resolve, reject) => {
      lintQueue.push({ task, resolve, reject });
      pumpLintQueue();
    });
  }

  function lintKey(document) {
    const uri = document.uri.fsPath || document.uri.toString();
    return `${uri}\0${typeof document.version === "number" ? document.version : ""}`;
  }

  function scheduleLint(document) {
    const key = lintKey(document);
    const existing = inFlightLints.get(key);
    if (existing) return existing;

    const version = document.version;
    const pending = withLintSlot(() => lint(document, version)).finally(() => {
      if (inFlightLints.get(key) === pending) inFlightLints.delete(key);
    });
    inFlightLints.set(key, pending);
    return pending;
  }

  async function lintDocuments(documents) {
    if (!hasCapabilities(await currentFiletypes())) {
      for (const document of documents) diagnostics.delete(document.uri);
      return;
    }

    await Promise.all(documents.map(scheduleLint));
  }

  function reportLintFailure(err) {
    if (!disposed && err?.name !== "AbortError") {
      console.error("sley-tools: diagnostics failed", err);
    }
  }

  function startLint(document) {
    void scheduleLint(document).catch(reportLintFailure);
  }

  context.subscriptions.push({
    dispose() {
      disposed = true;
      controller.abort();
      for (const { resolve } of lintQueue.splice(0)) resolve();
    },
  });
  context.subscriptions.push(diagnostics);
  context.subscriptions.push(
    vscode.commands.registerCommand("sleyTools.refreshDiagnostics", () =>
      lintDocuments([...vscode.workspace.textDocuments]),
    ),
  );
  context.subscriptions.push(
    vscode.workspace.onDidChangeTextDocument((event) => diagnostics.delete(event.document.uri)),
  );
  context.subscriptions.push(
    vscode.workspace.onDidOpenTextDocument((document) => {
      if (config().get("lintOnOpen")) startLint(document);
    }),
  );
  context.subscriptions.push(
    vscode.workspace.onDidSaveTextDocument((document) => {
      if (config().get("lintOnSave")) startLint(document);
    }),
  );
  context.subscriptions.push(
    vscode.window.onDidChangeActiveTextEditor((editor) => {
      if (editor && config().get("lintOnOpen")) startLint(editor.document);
    }),
  );
  if (config().get("lintOnOpen")) {
    void lintDocuments([...vscode.workspace.textDocuments]).catch(reportLintFailure);
  }
}

function deactivate() {}

module.exports = {
  activate,
  deactivate,
  _test: {
    customFiletype,
    documentFiletypes,
    expandFiletypes,
    formatCopy,
    globToRegExp,
    isDiagnosticExcluded,
    languageToFiletypes,
    matchesPattern,
    parseDiagnostics,
    providerSelector,
    supports,
  },
};
