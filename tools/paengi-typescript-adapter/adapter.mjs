import { createHash } from "node:crypto";
import path from "node:path";
import process from "node:process";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const PROTOCOL_VERSION = 1;
const MINIMUM_NODE_VERSION = "14.17.0";
const MAX_REQUEST_BYTES = 4 * 1024 * 1024;
const MAX_RESPONSE_BYTES = 4 * 1024 * 1024;
const MAX_FILES = 128;
const MAX_FILE_BYTES = 512 * 1024;
const MAX_TIMEOUT_MS = 30_000;
const VIRTUAL_ROOT = "/__paengi_snapshot__";

let ts;
try {
  ts = require("./node_modules/typescript/lib/typescript.js");
} catch (error) {
  writeResponse({
    protocolVersion: PROTOCOL_VERSION,
    status: "error",
    error: {
      code: "typescript-unavailable",
      message: "local pinned TypeScript package is unavailable",
      detail: String(error),
    },
  });
  process.exitCode = 1;
}

function writeResponse(response) {
  const payload = JSON.stringify(response);
  if (Buffer.byteLength(payload, "utf8") > MAX_RESPONSE_BYTES) {
    const bounded = JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      status: "error",
      error: {
        code: "response-too-large",
        message: `adapter response exceeds ${MAX_RESPONSE_BYTES} bytes`,
      },
    });
    process.stdout.write(`${bounded}\n`);
    return;
  }
  process.stdout.write(`${payload}\n`);
}

function fail(code, message, detail = undefined) {
  const error = { code, message };
  if (detail !== undefined) error.detail = detail;
  return { protocolVersion: PROTOCOL_VERSION, status: "error", error };
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function nodeVersionAtLeast(version, minimum) {
  const parse = (value) => value.replace(/^v/, "").split(".").map(Number);
  const actual = parse(version);
  const required = parse(minimum);
  for (let index = 0; index < 3; index += 1) {
    if (actual[index] > required[index]) return true;
    if (actual[index] < required[index]) return false;
  }
  return true;
}

function safeRelativePath(value) {
  if (typeof value !== "string" || value.length === 0 || value.includes("\0")) {
    return undefined;
  }
  if (value.includes("\\") || path.posix.isAbsolute(value)) return undefined;
  const normalized = path.posix.normalize(value);
  if (normalized === "." || normalized === ".." || normalized.startsWith("../")) {
    return undefined;
  }
  return normalized;
}

function toVirtualPath(relativePath) {
  return `${VIRTUAL_ROOT}/${relativePath}`;
}

function fromVirtualPath(fileName) {
  if (typeof fileName !== "string") return undefined;
  const prefix = `${VIRTUAL_ROOT}/`;
  if (!fileName.startsWith(prefix)) return undefined;
  return safeRelativePath(fileName.slice(prefix.length));
}

function extensionFor(relativePath) {
  if (relativePath.endsWith(".d.ts")) return ts.Extension.Dts;
  if (relativePath.endsWith(".tsx")) return ts.Extension.Tsx;
  if (relativePath.endsWith(".ts")) return ts.Extension.Ts;
  return undefined;
}

function scriptKindFor(relativePath, requestedLanguage) {
  if (requestedLanguage === "tsx" || relativePath.endsWith(".tsx")) {
    return ts.ScriptKind.TSX;
  }
  if (requestedLanguage === "ts" || relativePath.endsWith(".ts")) {
    return ts.ScriptKind.TS;
  }
  return undefined;
}

function isValidHex(value) {
  return typeof value === "string" && value.length % 2 === 0 && /^[0-9a-f]*$/i.test(value);
}

function decodeFile(entry) {
  const relativePath = safeRelativePath(entry?.path);
  if (!relativePath) return { error: "file path is unsafe" };
  const extension = extensionFor(relativePath);
  const scriptKind = scriptKindFor(relativePath, entry.language);
  if (!extension || !scriptKind) {
    return { error: `file ${relativePath} is not .ts, .tsx, or .d.ts` };
  }
  if (!isValidHex(entry.contentsHex)) return { error: `file ${relativePath} has invalid hex bytes` };
  const bytes = Buffer.from(entry.contentsHex, "hex");
  if (bytes.length > MAX_FILE_BYTES) {
    return { error: `file ${relativePath} exceeds ${MAX_FILE_BYTES} byte limit` };
  }
  const text = bytes.toString("utf8");
  if (!Buffer.from(text, "utf8").equals(bytes)) {
    return { error: `file ${relativePath} is not valid UTF-8` };
  }
  return { relativePath, virtualPath: toVirtualPath(relativePath), extension, scriptKind, bytes, text };
}

function byteOffsetAtUtf16(text, offset) {
  if (!Number.isInteger(offset) || offset < 0 || offset > text.length) return undefined;
  if (offset > 0 && offset < text.length) {
    const previous = text.charCodeAt(offset - 1);
    const next = text.charCodeAt(offset);
    if (previous >= 0xd800 && previous <= 0xdbff && next >= 0xdc00 && next <= 0xdfff) {
      return undefined;
    }
  }
  return Buffer.byteLength(text.slice(0, offset), "utf8");
}

function diagnosticFor(diagnostic, filesByVirtualPath) {
  const relativePath = fromVirtualPath(diagnostic.file?.fileName);
  const file = diagnostic.file ? filesByVirtualPath.get(diagnostic.file.fileName) : undefined;
  const startByte = file && diagnostic.start !== undefined
    ? byteOffsetAtUtf16(file.text, diagnostic.start)
    : undefined;
  const endByte = file && diagnostic.start !== undefined && diagnostic.length !== undefined
    ? byteOffsetAtUtf16(file.text, diagnostic.start + diagnostic.length)
    : undefined;
  const result = {
    code: diagnostic.code,
    category: ts.DiagnosticCategory[diagnostic.category] ?? "Unknown",
    message: ts.flattenDiagnosticMessageText(diagnostic.messageText, "\n"),
  };
  if (relativePath !== undefined) result.path = relativePath;
  if (startByte !== undefined) result.startByte = startByte;
  if (endByte !== undefined) result.endByte = endByte;
  return result;
}

function hasModifier(node, kind) {
  return Boolean(node.modifiers?.some((modifier) => modifier.kind === kind));
}

function declarationKind(node) {
  if (ts.isFunctionDeclaration(node)) return "function";
  if (ts.isClassDeclaration(node)) return "class";
  if (ts.isInterfaceDeclaration(node)) return "interface";
  if (ts.isTypeAliasDeclaration(node)) return "type-alias";
  if (ts.isEnumDeclaration(node)) return "enum";
  if (ts.isModuleDeclaration(node)) return "namespace";
  if (ts.isVariableDeclaration(node)) {
    return ts.isArrowFunction(node.initializer) ? "arrow-function" : "variable";
  }
  if (ts.isMethodDeclaration(node) || ts.isMethodSignature(node)) return "method";
  if (ts.isPropertyDeclaration(node) || ts.isPropertySignature(node)) return "property";
  if (ts.isGetAccessorDeclaration(node)) return "getter";
  if (ts.isSetAccessorDeclaration(node)) return "setter";
  if (ts.isConstructorDeclaration(node)) return "constructor";
  if (ts.isExportAssignment(node)) return "default-export";
  if (ts.isImportSpecifier(node)) return "import-alias";
  if (ts.isNamespaceImport(node)) return "namespace-import";
  if (ts.isExportSpecifier(node)) return "re-export-alias";
  if (ts.isImportEqualsDeclaration(node)) return "import-alias";
  return undefined;
}

function nameNodeFor(node) {
  if (ts.isExportAssignment(node)) return undefined;
  if ("name" in node && node.name && ts.isIdentifier(node.name)) return node.name;
  return undefined;
}

function syntacticNameFor(node) {
  if (ts.isExportAssignment(node)) return "default";
  const name = nameNodeFor(node);
  return name ? name.text : undefined;
}

function declarationModifierSource(node) {
  if (ts.isVariableDeclaration(node) && ts.isVariableDeclarationList(node.parent)) {
    return node.parent.parent;
  }
  return node;
}

function exportStatus(node) {
  const modifierSource = declarationModifierSource(node);
  const exported = hasModifier(modifierSource, ts.SyntaxKind.ExportKeyword);
  return {
    exported,
    default: hasModifier(modifierSource, ts.SyntaxKind.DefaultKeyword) || ts.isExportAssignment(node),
    local: !exported && !ts.isExportAssignment(node),
  };
}

function declarationSegments(node, sourceFile) {
  const segments = [];
  let current = node.parent;
  while (current && current !== sourceFile) {
    const kind = declarationKind(current);
    const name = syntacticNameFor(current);
    if (kind && name) segments.push(`${kind}:${name}`);
    current = current.parent;
  }
  return segments.reverse();
}

function tokenDigest(node, sourceFile) {
  const scanner = ts.createScanner(ts.ScriptTarget.Latest, true, ts.LanguageVariant.Standard, node.getText(sourceFile));
  const tokens = [];
  for (let token = scanner.scan(); token !== ts.SyntaxKind.EndOfFileToken; token = scanner.scan()) {
    tokens.push(`${ts.SyntaxKind[token]}:${scanner.getTokenText()}`);
  }
  return sha256(tokens.join("\0"));
}

function shapeEvidence(node, sourceFile) {
  const kind = declarationKind(node);
  const name = syntacticNameFor(node) ?? null;
  const modifiers = (node.modifiers ?? []).map((modifier) => ts.SyntaxKind[modifier.kind]).sort();
  const parameterCount = "parameters" in node && Array.isArray(node.parameters) ? node.parameters.length : 0;
  const typeParameterCount = "typeParameters" in node && node.typeParameters ? node.typeParameters.length : 0;
  const evidence = { kind, name, modifiers, parameterCount, typeParameterCount, tokenDigest: tokenDigest(node, sourceFile) };
  return { evidence, digest: sha256(JSON.stringify(evidence)) };
}

function symbolEvidence(checker, node, sourceFile) {
  const name = nameNodeFor(node);
  if (!name) return { available: false };
  const symbol = checker.getSymbolAtLocation(name);
  if (!symbol) return { available: false };
  let target = symbol;
  let aliasPath;
  if ((symbol.flags & ts.SymbolFlags.Alias) !== 0) {
    aliasPath = checker.getFullyQualifiedName(symbol);
    try {
      target = checker.getAliasedSymbol(symbol);
    } catch (_) {
      target = symbol;
    }
  }
  const declarations = (target.declarations ?? [])
    .map((declaration) => {
      const relativePath = fromVirtualPath(declaration.getSourceFile().fileName);
      const start = byteOffsetAtUtf16(declaration.getSourceFile().text, declaration.getStart(declaration.getSourceFile(), false));
      return relativePath && start !== undefined ? `${relativePath}:${start}` : undefined;
    })
    .filter((value) => value !== undefined)
    .sort();
  const result = {
    available: true,
    qualifiedName: checker.getFullyQualifiedName(target),
    declarationLocations: declarations,
    mergedDeclarationCount: declarations.length,
  };
  if (aliasPath !== undefined) result.aliasQualifiedName = aliasPath;
  return result;
}

function signatureEvidence(checker, node) {
  try {
    const signature = checker.getSignatureFromDeclaration(node);
    if (signature) {
      const value = checker.signatureToString(signature, node, ts.TypeFormatFlags.NoTruncation);
      return { value, digest: sha256(value) };
    }
    const type = checker.getTypeAtLocation(node);
    const value = checker.typeToString(type, node, ts.TypeFormatFlags.NoTruncation);
    return { value, digest: sha256(value) };
  } catch (_) {
    return { unavailable: true };
  }
}

function compilerOptionsFrom(requestOptions) {
  const defaults = {
    target: ts.ScriptTarget.ES2022,
    module: ts.ModuleKind.ESNext,
    moduleResolution: ts.ModuleResolutionKind.Bundler,
    jsx: ts.JsxEmit.Preserve,
    strict: true,
    noEmit: true,
    noLib: true,
    allowJs: false,
    skipLibCheck: true,
  };
  if (requestOptions === undefined) return { options: defaults, paths: undefined, baseUrl: "" };
  if (!requestOptions || Array.isArray(requestOptions) || typeof requestOptions !== "object") {
    return { error: "compilerOptions must be an object" };
  }
  const allowed = new Set(["strict", "jsx", "moduleResolution", "baseUrl", "paths"]);
  for (const key of Object.keys(requestOptions)) {
    if (!allowed.has(key)) return { error: `unsupported compiler option ${key}` };
  }
  const options = { ...defaults };
  if (requestOptions.strict !== undefined) {
    if (typeof requestOptions.strict !== "boolean") return { error: "strict must be boolean" };
    options.strict = requestOptions.strict;
  }
  if (requestOptions.jsx !== undefined) {
    const values = { preserve: ts.JsxEmit.Preserve, "react-jsx": ts.JsxEmit.ReactJSX, react: ts.JsxEmit.React };
    if (!(requestOptions.jsx in values)) return { error: "unsupported jsx option" };
    options.jsx = values[requestOptions.jsx];
  }
  if (requestOptions.moduleResolution !== undefined) {
    const values = { bundler: ts.ModuleResolutionKind.Bundler, node16: ts.ModuleResolutionKind.Node16, nodenext: ts.ModuleResolutionKind.NodeNext };
    if (!(requestOptions.moduleResolution in values)) return { error: "unsupported moduleResolution option" };
    options.moduleResolution = values[requestOptions.moduleResolution];
  }
  const baseUrl = requestOptions.baseUrl === undefined ? "" : safeRelativePath(requestOptions.baseUrl);
  if (baseUrl === undefined) return { error: "baseUrl must be a safe project-relative path" };
  const paths = requestOptions.paths;
  if (paths !== undefined) {
    if (!paths || Array.isArray(paths) || typeof paths !== "object") return { error: "paths must be an object" };
    for (const [alias, targets] of Object.entries(paths)) {
      if (typeof alias !== "string" || !Array.isArray(targets) || targets.length === 0) return { error: "invalid paths entry" };
      for (const target of targets) {
        const candidate = safeRelativePath(String(target).replaceAll("*", "segment"));
        if (!candidate) return { error: `unsafe paths target for ${alias}` };
      }
    }
  }
  return { options, paths, baseUrl };
}

function resolvePathCandidates(relativePath) {
  return [
    relativePath,
    `${relativePath}.ts`,
    `${relativePath}.tsx`,
    `${relativePath}.d.ts`,
    `${relativePath}/index.ts`,
    `${relativePath}/index.tsx`,
    `${relativePath}/index.d.ts`,
  ];
}

function makeModuleResolver(filesByRelativePath, paths, baseUrl) {
  const resolveTarget = (candidate) => {
    for (const pathCandidate of resolvePathCandidates(candidate)) {
      const normalized = safeRelativePath(pathCandidate);
      if (normalized && filesByRelativePath.has(normalized)) return normalized;
    }
    return undefined;
  };
  return (specifier, containingFile) => {
    const containingRelativePath = fromVirtualPath(containingFile);
    if (!containingRelativePath) return undefined;
    if (specifier.startsWith(".")) {
      return resolveTarget(path.posix.join(path.posix.dirname(containingRelativePath), specifier));
    }
    if (paths) {
      for (const [alias, targets] of Object.entries(paths)) {
        const star = alias.indexOf("*");
        const matched = star < 0 ? (specifier === alias ? "" : undefined)
          : (specifier.startsWith(alias.slice(0, star)) && specifier.endsWith(alias.slice(star + 1))
            ? specifier.slice(alias.slice(0, star).length, specifier.length - alias.slice(star + 1).length)
            : undefined);
        if (matched === undefined) continue;
        for (const target of targets) {
          const resolved = resolveTarget(path.posix.join(baseUrl, target.replaceAll("*", matched)));
          if (resolved) return resolved;
        }
      }
    }
    return undefined;
  };
}

function analyze(request) {
  const started = process.hrtime.bigint();
  if (!nodeVersionAtLeast(process.version, MINIMUM_NODE_VERSION)) {
    return fail("node-version-unsupported", `Node ${MINIMUM_NODE_VERSION} or newer is required`, process.version);
  }
  if (!/^[0-9a-f]{64}$/.test(request.snapshotId ?? "")) {
    return fail("invalid-snapshot-id", "snapshotId must be exactly 64 lowercase hexadecimal characters");
  }
  if (!Array.isArray(request.files) || request.files.length === 0 || request.files.length > MAX_FILES) {
    return fail("invalid-files", `files must contain 1 to ${MAX_FILES} entries`);
  }
  if (!Array.isArray(request.rootFiles) || request.rootFiles.length === 0) {
    return fail("invalid-root-files", "rootFiles must be a nonempty array");
  }
  if (request.timeoutMs !== undefined && (!Number.isInteger(request.timeoutMs) || request.timeoutMs < 1 || request.timeoutMs > MAX_TIMEOUT_MS)) {
    return fail("invalid-timeout", `timeoutMs must be an integer from 1 to ${MAX_TIMEOUT_MS}`);
  }
  const compiler = compilerOptionsFrom(request.compilerOptions);
  if (compiler.error) return fail("invalid-compiler-options", compiler.error);
  const files = [];
  let totalBytes = 0;
  for (const entry of request.files) {
    const file = decodeFile(entry);
    if (file.error) return fail("invalid-file", file.error);
    totalBytes += file.bytes.length;
    if (totalBytes > MAX_REQUEST_BYTES) return fail("request-too-large", "decoded file bytes exceed request limit");
    files.push(file);
  }
  const filesByRelativePath = new Map();
  const filesByVirtualPath = new Map();
  for (const file of files) {
    if (filesByRelativePath.has(file.relativePath)) return fail("duplicate-file", `duplicate file ${file.relativePath}`);
    filesByRelativePath.set(file.relativePath, file);
    filesByVirtualPath.set(file.virtualPath, file);
  }
  const rootFiles = [];
  for (const requestedPath of request.rootFiles) {
    const relativePath = safeRelativePath(requestedPath);
    if (!relativePath || !filesByRelativePath.has(relativePath)) return fail("invalid-root-file", `root file ${requestedPath} is absent from files`);
    rootFiles.push(toVirtualPath(relativePath));
  }
  const resolveModule = makeModuleResolver(filesByRelativePath, compiler.paths, compiler.baseUrl);
  const unresolvedModules = [];
  const host = {
    getSourceFile(fileName, languageVersion) {
      const file = filesByVirtualPath.get(fileName);
      if (!file) return undefined;
      return ts.createSourceFile(fileName, file.text, languageVersion, true, file.scriptKind);
    },
    getDefaultLibFileName: () => `${VIRTUAL_ROOT}/lib.d.ts`,
    writeFile: () => {},
    getCurrentDirectory: () => VIRTUAL_ROOT,
    getDirectories: () => [],
    fileExists(fileName) {
      return filesByVirtualPath.has(fileName);
    },
    readFile(fileName) {
      return filesByVirtualPath.get(fileName)?.text;
    },
    getCanonicalFileName: (fileName) => fileName,
    useCaseSensitiveFileNames: () => true,
    getNewLine: () => "\n",
    resolveModuleNames(moduleNames, containingFile) {
      return moduleNames.map((moduleName) => {
        const relativePath = resolveModule(moduleName, containingFile);
        if (!relativePath) {
          unresolvedModules.push({
            containingFile: fromVirtualPath(containingFile),
            moduleName,
          });
          return undefined;
        }
        const file = filesByRelativePath.get(relativePath);
        return { resolvedFileName: file.virtualPath, extension: file.extension, isExternalLibraryImport: false };
      });
    },
  };
  const program = ts.createProgram({ rootNames: rootFiles, options: compiler.options, host });
  const checker = program.getTypeChecker();
  const parserDiagnostics = program.getSyntacticDiagnostics().map((diagnostic) => diagnosticFor(diagnostic, filesByVirtualPath));
  const optionDiagnostics = program.getOptionsDiagnostics().map((diagnostic) => diagnosticFor(diagnostic, filesByVirtualPath));
  const typeCheckerDiagnostics = program.getSemanticDiagnostics().map((diagnostic) => diagnosticFor(diagnostic, filesByVirtualPath));
  const declarations = [];
  for (const file of [...files].sort((left, right) => left.relativePath.localeCompare(right.relativePath))) {
    const sourceFile = program.getSourceFile(file.virtualPath);
    if (!sourceFile) continue;
    const ordinalByScope = new Map();
    const visit = (node) => {
      const kind = declarationKind(node);
      if (kind) {
        const start = node.getStart(sourceFile, false);
        const end = node.getEnd();
        const nameNode = nameNodeFor(node);
        const startByte = byteOffsetAtUtf16(sourceFile.text, start);
        const endByte = byteOffsetAtUtf16(sourceFile.text, end);
        const nameStartByte = nameNode ? byteOffsetAtUtf16(sourceFile.text, nameNode.getStart(sourceFile, false)) : undefined;
        const nameEndByte = nameNode ? byteOffsetAtUtf16(sourceFile.text, nameNode.getEnd()) : undefined;
        if (startByte !== undefined && endByte !== undefined) {
          const syntacticName = syntacticNameFor(node) ?? null;
          const parentDeclarationPath = declarationSegments(node, sourceFile);
          const ordinalKey = `${parentDeclarationPath.join("/")}\0${kind}\0${syntacticName ?? ""}`;
          const overloadOrdinal = ordinalByScope.get(ordinalKey) ?? 0;
          ordinalByScope.set(ordinalKey, overloadOrdinal + 1);
          const shape = shapeEvidence(node, sourceFile);
          const visibility = exportStatus(node);
          const record = {
            path: file.relativePath,
            declarationKind: kind,
            declarationStartByte: startByte,
            declarationEndByte: endByte,
            parentDeclarationPath,
            exported: visibility.exported,
            default: visibility.default,
            local: visibility.local,
            syntacticName,
            overloadOrdinal,
            declarationShape: shape.evidence,
            declarationShapeDigest: shape.digest,
            signature: signatureEvidence(checker, node),
            symbol: symbolEvidence(checker, node, sourceFile),
          };
          if (nameStartByte !== undefined && nameEndByte !== undefined) {
            record.nameStartByte = nameStartByte;
            record.nameEndByte = nameEndByte;
          }
          declarations.push(record);
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
  }
  declarations.sort((left, right) => left.path.localeCompare(right.path)
    || left.declarationStartByte - right.declarationStartByte
    || left.declarationEndByte - right.declarationEndByte
    || String(left.syntacticName).localeCompare(String(right.syntacticName)));
  const elapsedMs = Number(process.hrtime.bigint() - started) / 1_000_000;
  const semanticComplete = parserDiagnostics.length === 0 && unresolvedModules.length === 0 && optionDiagnostics.length === 0;
  const typeResolutionComplete = semanticComplete && typeCheckerDiagnostics.length === 0;
  const result = {
    snapshotId: request.snapshotId,
    typescriptVersion: ts.version,
    parserComplete: parserDiagnostics.length === 0,
    resolutionComplete: unresolvedModules.length === 0 && optionDiagnostics.length === 0,
    semanticComplete,
    typeResolutionComplete,
    declarations,
    parserDiagnostics,
    resolutionDiagnostics: unresolvedModules.sort((left, right) => `${left.containingFile}\0${left.moduleName}`.localeCompare(`${right.containingFile}\0${right.moduleName}`)),
    typeCheckerDiagnostics,
    elapsedMs,
  };
  if (request.timeoutMs !== undefined && elapsedMs > request.timeoutMs) {
    return fail("adapter-timeout", `analysis exceeded requested ${request.timeoutMs}ms`, { elapsedMs });
  }
  return { protocolVersion: PROTOCOL_VERSION, status: "ok", result };
}

function conflict(code, message, detail = undefined) {
  const result = { protocolVersion: PROTOCOL_VERSION, status: "conflict", conflict: { code, message } };
  if (detail !== undefined) result.conflict.detail = detail;
  return result;
}

function replaceNode(request) {
  const analyzed = analyze(request);
  if (analyzed.status !== "ok") return analyzed;
  const target = request.target;
  if (!target || Array.isArray(target) || typeof target !== "object") {
    return fail("invalid-target", "replace-node target must be an object");
  }
  const relativePath = safeRelativePath(target.path);
  if (!relativePath) return fail("invalid-target", "replace-node target path is unsafe");
  if (!Number.isInteger(target.declarationStartByte) || !Number.isInteger(target.declarationEndByte)
      || target.declarationStartByte < 0 || target.declarationEndByte < target.declarationStartByte) {
    return fail("invalid-target", "replace-node target span is invalid");
  }
  if (typeof target.declarationKind !== "string" || typeof target.declarationShapeDigest !== "string") {
    return fail("invalid-target", "replace-node target evidence is incomplete");
  }
  if (!isValidHex(target.expectedPreimageHex) || !/^[0-9a-f]{64}$/.test(target.expectedPreimageSha256 ?? "")) {
    return fail("invalid-target", "replace-node target preimage evidence is invalid");
  }
  if (!isValidHex(request.replacementHex)) return fail("invalid-replacement", "replacementHex is invalid");
  const replacement = Buffer.from(request.replacementHex, "hex");
  const replacementText = replacement.toString("utf8");
  if (!Buffer.from(replacementText, "utf8").equals(replacement)) {
    return fail("invalid-replacement", "replacement bytes are not valid UTF-8");
  }
  if (!analyzed.result.parserComplete) {
    return conflict("incomplete-parser", "replace-node requires a parser-complete source project", {
      parserDiagnostics: analyzed.result.parserDiagnostics,
    });
  }
  const candidates = analyzed.result.declarations.filter((declaration) =>
    declaration.path === relativePath
    && declaration.declarationStartByte === target.declarationStartByte
    && declaration.declarationEndByte === target.declarationEndByte);
  if (candidates.length === 0) {
    return conflict("missing-anchor", "no declaration occupies the requested exact byte span", {
      candidatesConsidered: analyzed.result.declarations.filter((declaration) => declaration.path === relativePath),
    });
  }
  if (candidates.length !== 1) {
    return conflict("ambiguous-anchor", "multiple declarations occupy the requested exact byte span", {
      candidatesConsidered: candidates,
    });
  }
  const candidate = candidates[0];
  if (candidate.declarationKind !== target.declarationKind
      || candidate.declarationShapeDigest !== target.declarationShapeDigest) {
    return conflict("contradicting-evidence", "node kind or declaration-shape evidence changed", {
      candidatesConsidered: candidates,
      expectedKind: target.declarationKind,
      expectedShapeDigest: target.declarationShapeDigest,
    });
  }
  const sourceEntry = request.files.find((entry) => entry.path === relativePath);
  const decoded = decodeFile(sourceEntry);
  if (decoded.error) return fail("invalid-target", `replace-node target file is invalid: ${decoded.error}`);
  if (target.declarationEndByte > decoded.bytes.length) {
    return conflict("preimage-out-of-range", "replace-node target range exceeds exact source bytes");
  }
  const preimage = decoded.bytes.subarray(target.declarationStartByte, target.declarationEndByte);
  if (!preimage.equals(Buffer.from(target.expectedPreimageHex, "hex"))
      || sha256(preimage) !== target.expectedPreimageSha256) {
    return conflict("preimage-mismatch", "replace-node preimage bytes or hash changed", {
      expectedPreimageSha256: target.expectedPreimageSha256,
      actualPreimageSha256: sha256(preimage),
    });
  }
  const prefix = decoded.bytes.subarray(0, target.declarationStartByte);
  const suffix = decoded.bytes.subarray(target.declarationEndByte);
  const output = Buffer.concat([prefix, replacement, suffix]);
  if (output.length > MAX_FILE_BYTES) return fail("invalid-replacement", "replacement exceeds the per-file byte limit");
  const outputText = output.toString("utf8");
  if (!Buffer.from(outputText, "utf8").equals(output)) {
    return fail("invalid-replacement", "replacement result is not valid UTF-8");
  }
  const replacementRequest = {
    ...request,
    operation: "analyze",
    files: request.files.map((entry) => entry.path === relativePath
      ? { ...entry, contentsHex: output.toString("hex") }
      : entry),
  };
  const reparsed = analyze(replacementRequest);
  if (reparsed.status !== "ok" || !reparsed.result.parserComplete) {
    return conflict("post-parse-failure", "replacement source did not parse completely", {
      parserDiagnostics: reparsed.result?.parserDiagnostics ?? [],
    });
  }
  const postCandidates = reparsed.result.declarations.filter((declaration) =>
    declaration.path === relativePath
    && declaration.declarationStartByte === target.declarationStartByte
    && declaration.declarationKind === target.declarationKind
    && JSON.stringify(declaration.parentDeclarationPath) === JSON.stringify(candidate.parentDeclarationPath));
  if (postCandidates.length !== 1) {
    return conflict(postCandidates.length === 0 ? "post-context-missing" : "post-context-ambiguous",
      "replacement did not preserve one intended declaration context", { candidatesConsidered: postCandidates });
  }
  const outsideBytesUnchanged = output.subarray(0, target.declarationStartByte).equals(prefix)
    && output.subarray(target.declarationStartByte + replacement.length).equals(suffix);
  if (!outsideBytesUnchanged) {
    return conflict("outside-bytes-changed", "replace-node modified bytes outside the selected range");
  }
  return {
    protocolVersion: PROTOCOL_VERSION,
    status: "ok",
    result: {
      snapshotId: request.snapshotId,
      path: relativePath,
      originalSpan: {
        startByte: target.declarationStartByte,
        endByte: target.declarationEndByte,
      },
      newFileContentsHex: output.toString("hex"),
      parserComplete: reparsed.result.parserComplete,
      resolutionComplete: reparsed.result.resolutionComplete,
      typeResolutionComplete: reparsed.result.typeResolutionComplete,
      candidatesConsidered: candidates,
      evidence: [
        "exact-byte-span",
        "preimage-bytes",
        "preimage-sha256",
        "declaration-kind",
        "declaration-shape-digest",
        "post-parse-context",
        "outside-bytes-unchanged",
      ],
      confidence: "exact",
      fallbackUsed: false,
    },
  };
}

function handshake(request) {
  if (request.protocolVersion !== PROTOCOL_VERSION) {
    return fail("unsupported-protocol", `protocol version ${request.protocolVersion} is unsupported`);
  }
  return {
    protocolVersion: PROTOCOL_VERSION,
    status: "ok",
    result: {
      typescriptVersion: ts.version,
      minimumNodeVersion: MINIMUM_NODE_VERSION,
      requestLimitBytes: MAX_REQUEST_BYTES,
      responseLimitBytes: MAX_RESPONSE_BYTES,
      capabilities: ["analyze", "replace-node", "ts", "tsx", "virtual-files", "symbol-evidence"],
    },
  };
}

function dispatch(request) {
  if (!request || Array.isArray(request) || typeof request !== "object") {
    return fail("invalid-request", "request must be a JSON object");
  }
  if (request.protocolVersion !== PROTOCOL_VERSION) {
    return fail("unsupported-protocol", `protocol version ${request.protocolVersion} is unsupported`);
  }
  if (request.operation === "handshake") return handshake(request);
  if (request.operation === "analyze") return analyze(request);
  if (request.operation === "replace-node") return replaceNode(request);
  return fail("unsupported-operation", "operation must be handshake, analyze, or replace-node");
}

if (ts) {
  let requestBytes = 0;
  const chunks = [];
  process.stdin.on("data", (chunk) => {
    requestBytes += chunk.length;
    if (requestBytes > MAX_REQUEST_BYTES) {
      writeResponse(fail("request-too-large", `request exceeds ${MAX_REQUEST_BYTES} bytes`));
      process.stdin.destroy();
      return;
    }
    chunks.push(chunk);
  });
  process.stdin.on("end", () => {
    if (requestBytes > MAX_REQUEST_BYTES) return;
    try {
      const request = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      writeResponse(dispatch(request));
    } catch (error) {
      writeResponse(fail("malformed-json", "request is not valid JSON", String(error)));
    }
  });
  process.stdin.on("error", (error) => {
    process.stderr.write(`stdin error: ${String(error)}\n`);
  });
}
