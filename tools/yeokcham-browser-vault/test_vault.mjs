import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { webcrypto } from "node:crypto";

import {
  associatedDataForRecord,
  BrowserVault,
  VaultError,
} from "./browser_vault.mjs";

const encoder = new TextEncoder();

function base64Url(value) {
  return Buffer.from(value).toString("base64url");
}

function clone(value) {
  return value === undefined ? undefined : JSON.parse(JSON.stringify(value));
}

function equalBytes(actual, expected, message) {
  assert.deepEqual([...actual], [...expected], message);
}

async function expectVaultError(action, code) {
  await assert.rejects(action, (error) => error instanceof VaultError && error.code === code);
}

class MemoryVaultStore {
  constructor({ occupiedOnPut = false, failRead = false, failPut = false } = {}) {
    this.record = undefined;
    this.occupiedOnPut = occupiedOnPut;
    this.failRead = failRead;
    this.failPut = failPut;
    this.putCalls = 0;
    this.removeCalls = 0;
  }

  async read() {
    if (this.failRead) throw new Error("IndexedDB unavailable");
    return clone(this.record);
  }

  async putIfAbsent(record) {
    this.putCalls += 1;
    if (this.failPut) throw new Error("IndexedDB unavailable");
    if (this.occupiedOnPut || this.record) return false;
    this.record = clone(record);
    return true;
  }

  async remove() {
    this.removeCalls += 1;
    this.record = undefined;
  }
}

class FakeWebAuthn {
  constructor({ origin, credentialId = Uint8Array.from({ length: 32 }, (_, index) => index + 1), prf = Uint8Array.from({ length: 32 }, (_, index) => 255 - index) } = {}) {
    this.origin = origin;
    this.credentialId = credentialId;
    this.prf = prf;
    this.flags = 0x05;
    this.clientOrigin = origin;
    this.rpIdForHash = undefined;
    this.prfEnabled = true;
    this.credentialType = "public-key";
    this.failCreate = false;
    this.failGet = false;
    this.getCalls = 0;
    this.createCalls = 0;
  }

  async create(options) {
    this.createCalls += 1;
    if (this.failCreate) throw new Error("WebAuthn unavailable");
    const publicKey = options.publicKey;
    assert.equal(publicKey.rp.id, new URL(this.origin).hostname);
    assert.equal(publicKey.authenticatorSelection.userVerification, "required");
    assert.equal(publicKey.authenticatorSelection.residentKey, "required");
    assert.equal(publicKey.extensions.prf.eval.first.length, 32);
    return {
      type: this.credentialType,
      rawId: this.credentialId.slice().buffer,
      getClientExtensionResults: () => ({ prf: { enabled: this.prfEnabled } }),
    };
  }

  async get(options) {
    this.getCalls += 1;
    if (this.failGet) throw new Error("WebAuthn unavailable");
    const publicKey = options.publicKey;
    const encodedId = base64Url(this.credentialId);
    assert.deepEqual([...publicKey.allowCredentials[0].id], [...this.credentialId]);
    assert.equal(publicKey.userVerification, "required");
    assert.deepEqual([...publicKey.extensions.prf.evalByCredential[encodedId].first].length, 32);
    const hash = new Uint8Array(await webcrypto.subtle.digest("SHA-256", encoder.encode(this.rpIdForHash ?? publicKey.rpId)));
    const authenticatorData = new Uint8Array(37);
    authenticatorData.set(hash, 0);
    authenticatorData[32] = this.flags;
    const clientData = encoder.encode(JSON.stringify({
      type: "webauthn.get",
      challenge: base64Url(publicKey.challenge),
      origin: this.clientOrigin,
      crossOrigin: false,
    }));
    return {
      type: this.credentialType,
      rawId: this.credentialId.slice().buffer,
      response: {
        clientDataJSON: clientData.buffer,
        authenticatorData: authenticatorData.buffer,
      },
      getClientExtensionResults: () => ({ prf: { results: { first: this.prf.slice().buffer } } }),
    };
  }
}

function createVault({ origin = "https://vault.example.test", store = new MemoryVaultStore(), webAuthn = new FakeWebAuthn({ origin }), crypto = webcrypto } = {}) {
  return { vault: new BrowserVault({ origin, store, webAuthn, crypto }), origin, store, webAuthn };
}

async function enrolledFixture(capability = encoder.encode("repository capability for browser vault")) {
  const fixture = createVault();
  await fixture.vault.enroll(capability);
  return { ...fixture, capability };
}

const vectorRecord = {
  version: 1,
  origin: "https://vault.example.test",
  rpId: "vault.example.test",
  credentialId: base64Url(encoder.encode("credential")),
  salt: base64Url(Uint8Array.from({ length: 32 }, () => "s".charCodeAt(0))),
  iv: base64Url(Uint8Array.from({ length: 12 }, () => "i".charCodeAt(0))),
  ciphertext: base64Url(Uint8Array.from({ length: 17 }, () => 0)),
};

const fixturePath = fileURLToPath(new URL("./golden/v2-browser-vault-aad-v1.hex", import.meta.url));
const expectedAad = (await readFile(fixturePath, "utf8")).trim();
assert.equal(Buffer.from(associatedDataForRecord(vectorRecord)).toString("hex"), expectedAad);

const source = await readFile(fileURLToPath(new URL("./browser_vault.mjs", import.meta.url)), "utf8");
assert.equal(source.includes("localStorage"), false, "vault implementation must not use localStorage");

{
  const { vault, store, webAuthn, capability } = await enrolledFixture();
  assert.equal(vault.isUnlocked, false, "enrolment does not retain a plaintext session");
  assert.equal(store.putCalls, 1);
  const persistent = JSON.stringify(store.record);
  assert.equal(persistent.includes(new TextDecoder().decode(capability)), false, "IndexedDB record contains no plaintext repository capability");
  assert.equal(persistent.includes(base64Url(capability)), false, "IndexedDB record contains no base64 plaintext repository capability");
  assert.equal(Object.hasOwn(store.record, "key"), false, "IndexedDB record has no stored vault key");
  const restarted = new BrowserVault({ origin: "https://vault.example.test", store, webAuthn, crypto: webcrypto });
  const beforeRestartAssertion = webAuthn.getCalls;
  equalBytes(await restarted.unlock(), capability, "restart restores exact bytes after a fresh assertion");
  assert.equal(webAuthn.getCalls, beforeRestartAssertion + 1, "restart requires a new passkey assertion");
  assert.equal(restarted.isUnlocked, true);
  restarted.logout();
  assert.equal(restarted.isUnlocked, false, "logout discards the library-held session");
}

{
  const { store, webAuthn } = await enrolledFixture();
  const wrongOrigin = new BrowserVault({ origin: "https://other.example.test", store, webAuthn, crypto: webcrypto });
  await expectVaultError(() => wrongOrigin.unlock(), "origin-mismatch");
  assert.equal(webAuthn.getCalls, 1, "origin mismatch rejects before another assertion");
}

{
  const { store, webAuthn } = await enrolledFixture();
  webAuthn.rpIdForHash = "other.example.test";
  const restarted = new BrowserVault({ origin: "https://vault.example.test", store, webAuthn, crypto: webcrypto });
  await expectVaultError(() => restarted.unlock(), "origin-mismatch");
}

{
  const { store, webAuthn } = await enrolledFixture();
  webAuthn.credentialType = "password";
  const restarted = new BrowserVault({ origin: "https://vault.example.test", store, webAuthn, crypto: webcrypto });
  await expectVaultError(() => restarted.unlock(), "webauthn-invalid");
}

{
  const { store, webAuthn } = await enrolledFixture();
  const last = store.record.ciphertext.at(-1);
  store.record.ciphertext = `${store.record.ciphertext.slice(0, -1)}${last === "A" ? "B" : "A"}`;
  const restarted = new BrowserVault({ origin: "https://vault.example.test", store, webAuthn, crypto: webcrypto });
  await expectVaultError(() => restarted.unlock(), "vault-corrupt");
  assert.equal(restarted.isUnlocked, false);
}

{
  const { store, webAuthn } = await enrolledFixture();
  webAuthn.clientOrigin = "https://phish.example.test";
  const restarted = new BrowserVault({ origin: "https://vault.example.test", store, webAuthn, crypto: webcrypto });
  await expectVaultError(() => restarted.unlock(), "origin-mismatch");
  assert.equal(restarted.isUnlocked, false);
}

{
  const { store, webAuthn } = await enrolledFixture();
  webAuthn.flags = 0x01;
  const restarted = new BrowserVault({ origin: "https://vault.example.test", store, webAuthn, crypto: webcrypto });
  await expectVaultError(() => restarted.unlock(), "user-verification-missing");
}

{
  const unavailable = createVault({ webAuthn: {} });
  await expectVaultError(() => unavailable.vault.enroll(encoder.encode("key")), "webauthn-unavailable");
  const unsupportedPrf = createVault();
  unsupportedPrf.webAuthn.prfEnabled = false;
  await expectVaultError(() => unsupportedPrf.vault.enroll(encoder.encode("key")), "prf-unavailable");
  assert.equal(unsupportedPrf.store.record, undefined, "PRF failure writes no vault record");
}

{
  const collision = createVault({ store: new MemoryVaultStore({ occupiedOnPut: true }) });
  await expectVaultError(() => collision.vault.enroll(encoder.encode("key")), "vault-already-enrolled");
  assert.equal(collision.store.record, undefined, "create collision does not overwrite browser storage");
}

{
  const unavailableRead = createVault({ store: new MemoryVaultStore({ failRead: true }) });
  await expectVaultError(() => unavailableRead.vault.enroll(encoder.encode("key")), "storage-unavailable");
  const unavailablePut = createVault({ store: new MemoryVaultStore({ failPut: true }) });
  await expectVaultError(() => unavailablePut.vault.enroll(encoder.encode("key")), "storage-unavailable");
  assert.equal(unavailablePut.store.record, undefined, "failed storage writes no browser vault record");
}

{
  const { vault, store } = await enrolledFixture();
  const repositoryState = "unchanged signed repository state";
  await vault.remove();
  assert.equal(store.record, undefined, "removal deletes only the browser-local record");
  assert.equal(store.removeCalls, 1);
  assert.equal(repositoryState, "unchanged signed repository state");
  await expectVaultError(() => vault.unlock(), "vault-missing");
}

function seededBytes(seed, length) {
  let state = seed >>> 0;
  const output = new Uint8Array(length);
  for (let index = 0; index < length; index += 1) {
    state = (state * 1_664_525 + 1_013_904_223) >>> 0;
    output[index] = state >>> 24;
  }
  return output;
}

const baseSeed = Number.parseInt(process.env.PROPERTY_TEST_SEED ?? "20260813", 10) || 20260813;
for (let index = 0; index < 120; index += 1) {
  const origin = `https://vault-${index}.example.test`;
  const capability = seededBytes(baseSeed ^ (index * 0x9e3779b9), 1 + ((baseSeed + index) % 512));
  const store = new MemoryVaultStore();
  const webAuthn = new FakeWebAuthn({ origin, credentialId: seededBytes(baseSeed + index, 32) });
  const first = new BrowserVault({ origin, store, webAuthn, crypto: webcrypto });
  await first.enroll(capability);
  const beforeRestartAssertion = webAuthn.getCalls;
  const restarted = new BrowserVault({ origin, store, webAuthn, crypto: webcrypto });
  equalBytes(await restarted.unlock(), capability, `generated restart case ${index} preserves capability bytes`);
  assert.equal(webAuthn.getCalls, beforeRestartAssertion + 1, `generated restart case ${index} needs a fresh assertion`);
}

process.stdout.write("browser vault tests passed\n");
