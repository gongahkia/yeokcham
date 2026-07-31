import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";

const adapter = fileURLToPath(new URL("./adapter.mjs", import.meta.url));
const snapshotId = "1".repeat(64);

function response(request, options = {}) {
  const child = spawnSync(process.execPath, [adapter], {
    encoding: "utf8",
    input: JSON.stringify(request),
    maxBuffer: options.maxBuffer ?? 8 * 1024 * 1024,
  });
  assert.equal(child.error, undefined, `adapter did not start: ${child.error}`);
  assert.equal(child.stderr, "", `adapter wrote stderr: ${child.stderr}`);
  assert.notEqual(child.stdout, "", "adapter returned no protocol response");
  const lines = child.stdout.trimEnd().split("\n");
  assert.equal(lines.length, 1, "adapter stdout contained non-protocol output");
  return JSON.parse(lines[0]);
}

function file(path, language, text) {
  return { path, language, contentsHex: Buffer.from(text, "utf8").toString("hex") };
}

function request(files, rootFiles = files.map((entry) => entry.path), compilerOptions = {}) {
  return {
    protocolVersion: 1,
    operation: "analyze",
    snapshotId,
    rootFiles,
    files,
    compilerOptions,
    timeoutMs: 10_000,
  };
}

const handshake = response({ protocolVersion: 1, operation: "handshake" });
assert.equal(handshake.status, "ok");
assert.equal(handshake.result.typescriptVersion, "5.9.3");
assert.equal(handshake.result.minimumNodeVersion, "14.17.0");
assert.ok(handshake.result.capabilities.includes("virtual-files"));

const unsupported = response({ protocolVersion: 2, operation: "handshake" });
assert.equal(unsupported.status, "error");
assert.equal(unsupported.error.code, "unsupported-protocol");

const source = "\uFEFF// 😀\r\nexport function café<T>(value: T): T { return value; }\r\n";
const tsx = "export const View = () => <div title=\"😀\">hello</div>;\n";
const aliases = "export { café as publicCafé } from \"./source\";\nimport { café as localCafé } from \"./source\";\nexport default function Component() { return localCafé(\"x\"); }\n";
const analyzed = response(request([
  file("src/source.ts", "ts", source),
  file("src/view.tsx", "tsx", tsx),
  file("src/aliases.ts", "ts", aliases),
], ["src/source.ts", "src/view.tsx", "src/aliases.ts"], { strict: false, jsx: "preserve" }));
assert.equal(analyzed.status, "ok");
assert.equal(analyzed.result.parserComplete, true);
assert.equal(analyzed.result.resolutionComplete, true);
const café = analyzed.result.declarations.find((declaration) => declaration.syntacticName === "café");
assert.ok(café, "unicode declaration was not extracted");
assert.equal(café.nameStartByte, Buffer.from(source).indexOf(Buffer.from("café")));
assert.equal(café.nameEndByte, café.nameStartByte + Buffer.byteLength("café"));
assert.equal(café.exported, true);
assert.equal(café.local, false);
const view = analyzed.result.declarations.find((declaration) => declaration.path === "src/view.tsx" && declaration.syntacticName === "View");
assert.ok(view, "TSX arrow declaration was not extracted");
assert.equal(view.declarationKind, "arrow-function");
assert.equal(view.exported, true);
const importAlias = analyzed.result.declarations.find((declaration) => declaration.declarationKind === "import-alias");
const reexportAlias = analyzed.result.declarations.find((declaration) => declaration.declarationKind === "re-export-alias");
assert.ok(importAlias?.symbol.aliasQualifiedName, "import alias evidence was not retained");
assert.ok(reexportAlias?.symbol.aliasQualifiedName, "re-export alias evidence was not retained");

const replaceSource = "// keep this comment\r\nexport function greet(name: string): string { return `hello ${name}`; }\r\n// keep this suffix\r\n";
const replaceAnalysis = response(request([file("src/replace.ts", "ts", replaceSource)], ["src/replace.ts"], { strict: false }));
const replaceDeclaration = replaceAnalysis.result.declarations.find((declaration) => declaration.syntacticName === "greet");
assert.ok(replaceDeclaration, "replace target declaration was not extracted");
const replaceBytes = Buffer.from(replaceSource, "utf8");
const preimage = replaceBytes.subarray(replaceDeclaration.declarationStartByte, replaceDeclaration.declarationEndByte);
const replacement = Buffer.from("export function greet(name: string): string { return `welcome ${name}`; }", "utf8");
const replacementRequest = {
  protocolVersion: 1,
  operation: "replace-node",
  snapshotId,
  rootFiles: ["src/replace.ts"],
  files: [file("src/replace.ts", "ts", replaceSource)],
  compilerOptions: { strict: false },
  timeoutMs: 10_000,
  target: {
    path: "src/replace.ts",
    declarationStartByte: replaceDeclaration.declarationStartByte,
    declarationEndByte: replaceDeclaration.declarationEndByte,
    expectedPreimageHex: preimage.toString("hex"),
    expectedPreimageSha256: createHash("sha256").update(preimage).digest("hex"),
    declarationKind: replaceDeclaration.declarationKind,
    declarationShapeDigest: replaceDeclaration.declarationShapeDigest,
  },
  replacementHex: replacement.toString("hex"),
};
const replaced = response(replacementRequest);
assert.equal(replaced.status, "ok");
assert.equal(replaced.result.confidence, "exact");
assert.equal(replaced.result.fallbackUsed, false);
const replacedBytes = Buffer.from(replaced.result.newFileContentsHex, "hex");
assert.ok(replacedBytes.subarray(0, replaceDeclaration.declarationStartByte)
  .equals(replaceBytes.subarray(0, replaceDeclaration.declarationStartByte)), "replace changed prefix bytes");
assert.ok(replacedBytes.subarray(replaceDeclaration.declarationStartByte + replacement.length)
  .equals(replaceBytes.subarray(replaceDeclaration.declarationEndByte)), "replace changed suffix bytes");
const stalePreimage = response({
  ...replacementRequest,
  target: { ...replacementRequest.target, expectedPreimageSha256: "0".repeat(64) },
});
assert.equal(stalePreimage.status, "conflict");
assert.equal(stalePreimage.conflict.code, "preimage-mismatch");
const brokenReplacement = response({
  ...replacementRequest,
  replacementHex: Buffer.from("export function greet(", "utf8").toString("hex"),
});
assert.equal(brokenReplacement.status, "conflict");
assert.equal(brokenReplacement.conflict.code, "post-parse-failure");

const damaged = response(request([file("src/damaged.ts", "ts", "export function broken( {\n")], ["src/damaged.ts"]));
assert.equal(damaged.status, "ok");
assert.equal(damaged.result.parserComplete, false);
assert.equal(damaged.result.semanticComplete, false);

const unresolved = response(request([file("src/missing.ts", "ts", "import { x } from \"./absent\"; export const y = x;\n")], ["src/missing.ts"]));
assert.equal(unresolved.status, "ok");
assert.equal(unresolved.result.resolutionComplete, false);
assert.equal(unresolved.result.semanticComplete, false);

const paths = response(request([
  file("src/lib/value.ts", "ts", "export const value = 1;\n"),
  file("src/use.ts", "ts", "import { value } from \"@/value\"; export const result = value;\n"),
], ["src/use.ts"], { strict: false, baseUrl: "src/lib", paths: { "@/*": ["*"] } }));
assert.equal(paths.status, "ok");
assert.equal(paths.result.resolutionComplete, true);

const unsafePath = response(request([file("../outside.ts", "ts", "export const x = 1;\n")], ["../outside.ts"]));
assert.equal(unsafePath.status, "error");
assert.equal(unsafePath.error.code, "invalid-file");

const unsupportedOption = response(request([file("src/a.ts", "ts", "export const x = 1;\n")], ["src/a.ts"], { plugins: [] }));
assert.equal(unsupportedOption.status, "error");
assert.equal(unsupportedOption.error.code, "invalid-compiler-options");

const oneDeclaration = "export function f00000() {}\n";
const repeated = oneDeclaration.repeat(18_000);
const tooLargeResponse = response(request([
  file("src/one.ts", "ts", repeated),
  file("src/two.ts", "ts", repeated),
  file("src/three.ts", "ts", repeated),
  file("src/four.ts", "ts", repeated),
], ["src/one.ts", "src/two.ts", "src/three.ts", "src/four.ts"]), { maxBuffer: 8 * 1024 * 1024 });
assert.equal(tooLargeResponse.status, "error");
assert.equal(tooLargeResponse.error.code, "response-too-large");

process.stdout.write("adapter protocol tests passed\n");
