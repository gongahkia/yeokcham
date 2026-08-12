const VAULT_VERSION = 1;
const VAULT_DOMAIN = "yeokcham-browser-vault-v1";
const DATABASE_NAME = "io.github.gongahkia.yeokcham.browser-vault";
const STORE_NAME = "vaults";
const STORE_KEY = "v1";
const MAX_CAPABILITY_BYTES = 4096;
const CREDENTIAL_ID_MAX_BYTES = 1024;
const PRF_SALT_BYTES = 32;
const AES_GCM_IV_BYTES = 12;
const AES_GCM_TAG_BYTES = 16;
const WEBAUTHN_CHALLENGE_BYTES = 32;
const WEBAUTHN_TIMEOUT_MS = 60_000;

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

export class VaultError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "VaultError";
    this.code = code;
  }
}

function fail(code, message) {
  throw new VaultError(code, message);
}

function bytes(value, code, message) {
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  if (ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  }
  fail(code, message);
}

function copies(value) {
  return new Uint8Array(value);
}

function equalBytes(left, right) {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference === 0;
}

function base64UrlEncode(value) {
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

function base64UrlDecode(value, code, message) {
  if (typeof value !== "string" || value.length === 0 || !/^[A-Za-z0-9_-]+$/u.test(value)) {
    fail(code, message);
  }
  const padded = `${value.replaceAll("-", "+").replaceAll("_", "/")}${"=".repeat((4 - (value.length % 4)) % 4)}`;
  let binary;
  try {
    binary = atob(padded);
  } catch {
    fail(code, message);
  }
  const decoded = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  if (base64UrlEncode(decoded) !== value) fail(code, message);
  return decoded;
}

function validateOrigin(origin) {
  if (typeof origin !== "string") fail("origin-invalid", "browser vault origin is invalid");
  let parsed;
  try {
    parsed = new URL(origin);
  } catch {
    fail("origin-invalid", "browser vault origin is invalid");
  }
  if (parsed.protocol !== "https:" || parsed.origin !== origin || parsed.hostname.length === 0) {
    fail("origin-invalid", "browser vault requires one exact HTTPS origin");
  }
  return { origin, rpId: parsed.hostname };
}

function requireCrypto(crypto) {
  if (!crypto?.subtle || typeof crypto.getRandomValues !== "function") {
    fail("webcrypto-unavailable", "browser WebCrypto is unavailable");
  }
  return crypto;
}

function randomBytes(crypto, length) {
  const output = new Uint8Array(length);
  crypto.getRandomValues(output);
  return output;
}

function cloneRecord(record) {
  return {
    version: record.version,
    origin: record.origin,
    rpId: record.rpId,
    credentialId: record.credentialId,
    salt: record.salt,
    iv: record.iv,
    ciphertext: record.ciphertext,
  };
}

export function associatedDataForRecord(record) {
  return encoder.encode(
    [
      VAULT_DOMAIN,
      String(record.version),
      record.origin,
      record.rpId,
      record.credentialId,
      record.salt,
      record.iv,
    ].join("\0"),
  );
}

function validateRecord(record, expectedOrigin) {
  if (!record || typeof record !== "object" || Array.isArray(record)) {
    fail("vault-corrupt", "browser vault record is malformed");
  }
  if (record.version !== VAULT_VERSION) {
    fail("vault-version-unsupported", "browser vault version is unsupported");
  }
  const configured = validateOrigin(expectedOrigin);
  if (record.origin !== configured.origin || record.rpId !== configured.rpId) {
    fail("origin-mismatch", "browser vault origin or relying-party ID does not match");
  }
  const credentialId = base64UrlDecode(record.credentialId, "vault-corrupt", "browser vault credential ID is malformed");
  const salt = base64UrlDecode(record.salt, "vault-corrupt", "browser vault PRF salt is malformed");
  const iv = base64UrlDecode(record.iv, "vault-corrupt", "browser vault IV is malformed");
  const ciphertext = base64UrlDecode(record.ciphertext, "vault-corrupt", "browser vault ciphertext is malformed");
  if (credentialId.length === 0 || credentialId.length > CREDENTIAL_ID_MAX_BYTES) {
    fail("vault-corrupt", "browser vault credential ID length is invalid");
  }
  if (salt.length !== PRF_SALT_BYTES || iv.length !== AES_GCM_IV_BYTES) {
    fail("vault-corrupt", "browser vault cryptographic field length is invalid");
  }
  if (ciphertext.length <= AES_GCM_TAG_BYTES || ciphertext.length > MAX_CAPABILITY_BYTES + AES_GCM_TAG_BYTES) {
    fail("vault-corrupt", "browser vault ciphertext length is invalid");
  }
  return { record: cloneRecord(record), credentialId, salt, iv, ciphertext };
}

function extensionResults(credential) {
  if (typeof credential?.getClientExtensionResults !== "function") {
    fail("webauthn-invalid", "WebAuthn response has no extension results");
  }
  try {
    return credential.getClientExtensionResults();
  } catch {
    fail("webauthn-invalid", "WebAuthn extension results are invalid");
  }
}

function requirePublicKeyCredential(credential) {
  if (credential?.type !== "public-key") {
    fail("webauthn-invalid", "WebAuthn response is not a public-key credential");
  }
}

function createdCredentialId(credential) {
  requirePublicKeyCredential(credential);
  const credentialId = bytes(
    credential?.rawId,
    "webauthn-invalid",
    "WebAuthn creation response has no credential ID",
  );
  if (credentialId.length === 0 || credentialId.length > CREDENTIAL_ID_MAX_BYTES) {
    fail("webauthn-invalid", "WebAuthn credential ID length is invalid");
  }
  return copies(credentialId);
}

function requireCreationPrf(credential) {
  const prf = extensionResults(credential)?.prf;
  if (prf?.enabled !== true) {
    fail("prf-unavailable", "the selected passkey does not support the required PRF extension");
  }
}

async function rpIdHash(crypto, rpId) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(rpId)));
}

async function validateAssertion({ credential, challenge, expected, crypto }) {
  requirePublicKeyCredential(credential);
  const returnedCredentialId = bytes(
    credential?.rawId,
    "webauthn-invalid",
    "WebAuthn assertion has no credential ID",
  );
  if (!equalBytes(returnedCredentialId, expected.credentialId)) {
    fail("credential-mismatch", "WebAuthn assertion selected a different credential");
  }
  const response = credential?.response;
  let clientData;
  try {
    clientData = JSON.parse(decoder.decode(bytes(
      response?.clientDataJSON,
      "webauthn-invalid",
      "WebAuthn assertion has no client data",
    )));
  } catch (error) {
    if (error instanceof VaultError) throw error;
    fail("webauthn-invalid", "WebAuthn client data is malformed");
  }
  if (
    !clientData ||
    clientData.type !== "webauthn.get" ||
    clientData.challenge !== base64UrlEncode(challenge) ||
    clientData.origin !== expected.record.origin ||
    clientData.crossOrigin === true
  ) {
    fail("origin-mismatch", "WebAuthn assertion is not bound to the expected origin and challenge");
  }
  const authenticatorData = bytes(
    response?.authenticatorData,
    "webauthn-invalid",
    "WebAuthn assertion has no authenticator data",
  );
  if (authenticatorData.length < 37) {
    fail("webauthn-invalid", "WebAuthn authenticator data is truncated");
  }
  if (!equalBytes(authenticatorData.slice(0, 32), await rpIdHash(crypto, expected.record.rpId))) {
    fail("origin-mismatch", "WebAuthn authenticator data has the wrong relying-party ID");
  }
  const flags = authenticatorData[32];
  if ((flags & 0x01) === 0) fail("user-presence-missing", "WebAuthn assertion lacks user presence");
  if ((flags & 0x04) === 0) fail("user-verification-missing", "WebAuthn assertion lacks user verification");
  const prfOutput = extensionResults(credential)?.prf?.results?.first;
  const prf = bytes(prfOutput, "prf-unavailable", "WebAuthn assertion did not return a PRF result");
  if (prf.length !== 32) fail("prf-unavailable", "WebAuthn PRF result has an invalid length");
  return copies(prf);
}

async function passkeyPrf({ webAuthn, expected, crypto }) {
  if (typeof webAuthn?.get !== "function") {
    fail("webauthn-unavailable", "browser WebAuthn assertion API is unavailable");
  }
  const challenge = randomBytes(crypto, WEBAUTHN_CHALLENGE_BYTES);
  const credentialId = base64UrlEncode(expected.credentialId);
  let credential;
  try {
    credential = await webAuthn.get({
      publicKey: {
        challenge,
        rpId: expected.record.rpId,
        allowCredentials: [{ type: "public-key", id: copies(expected.credentialId) }],
        userVerification: "required",
        timeout: WEBAUTHN_TIMEOUT_MS,
        extensions: { prf: { evalByCredential: { [credentialId]: { first: copies(expected.salt) } } } },
      },
    });
  } catch {
    fail("webauthn-unavailable", "browser WebAuthn assertion is unavailable or rejected");
  }
  return validateAssertion({ credential, challenge, expected, crypto });
}

async function aesGcmKey(crypto, prf, usage) {
  try {
    return await crypto.subtle.importKey("raw", prf, { name: "AES-GCM" }, false, [usage]);
  } catch {
    fail("webcrypto-unavailable", "browser could not import a transient AES-GCM key");
  }
}

async function encryptCapability({ crypto, record, prf, capability }) {
  const key = await aesGcmKey(crypto, prf, "encrypt");
  try {
    return new Uint8Array(await crypto.subtle.encrypt(
      { name: "AES-GCM", iv: base64UrlDecode(record.iv, "vault-corrupt", "browser vault IV is malformed"), additionalData: associatedDataForRecord(record), tagLength: 128 },
      key,
      capability,
    ));
  } catch {
    fail("webcrypto-unavailable", "browser could not encrypt the local vault");
  }
}

async function decryptCapability({ crypto, record, prf, ciphertext }) {
  const key = await aesGcmKey(crypto, prf, "decrypt");
  try {
    return new Uint8Array(await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: base64UrlDecode(record.iv, "vault-corrupt", "browser vault IV is malformed"), additionalData: associatedDataForRecord(record), tagLength: 128 },
      key,
      ciphertext,
    ));
  } catch {
    fail("vault-corrupt", "browser vault ciphertext failed authenticated decryption");
  }
}

function normalizeCapability(capability) {
  const normalized = bytes(capability, "capability-invalid", "browser vault capability must be bytes");
  if (normalized.length === 0 || normalized.length > MAX_CAPABILITY_BYTES) {
    fail("capability-invalid", "browser vault capability length is invalid");
  }
  return copies(normalized);
}

async function readVaultRecord(store) {
  try {
    return await store.read();
  } catch (error) {
    if (error instanceof VaultError) throw error;
    fail("storage-unavailable", "browser vault storage could not read the local record");
  }
}

async function putVaultRecord(store, record) {
  try {
    return await store.putIfAbsent(cloneRecord(record));
  } catch (error) {
    if (error instanceof VaultError) throw error;
    fail("storage-unavailable", "browser vault storage could not write the local record");
  }
}

export class BrowserVault {
  constructor({ origin, store, webAuthn, crypto = globalThis.crypto }) {
    const configured = validateOrigin(origin);
    if (!store || typeof store.read !== "function" || typeof store.putIfAbsent !== "function" || typeof store.remove !== "function") {
      fail("storage-unavailable", "browser vault storage boundary is unavailable");
    }
    this.origin = configured.origin;
    this.store = store;
    this.webAuthn = webAuthn;
    this.crypto = requireCrypto(crypto);
    this.active = undefined;
  }

  get isUnlocked() {
    return this.active !== undefined;
  }

  logout() {
    if (this.active) this.active.fill(0);
    this.active = undefined;
  }

  async enroll(capability) {
    this.logout();
    if (await readVaultRecord(this.store)) fail("vault-already-enrolled", "browser vault already has an enrolled record");
    if (typeof this.webAuthn?.create !== "function") {
      fail("webauthn-unavailable", "browser WebAuthn creation API is unavailable");
    }
    const plaintext = normalizeCapability(capability);
    const salt = randomBytes(this.crypto, PRF_SALT_BYTES);
    try {
      let credential;
      try {
        credential = await this.webAuthn.create({
          publicKey: {
            challenge: randomBytes(this.crypto, WEBAUTHN_CHALLENGE_BYTES),
            rp: { id: validateOrigin(this.origin).rpId, name: "Yeokcham local vault" },
            user: { id: randomBytes(this.crypto, 32), name: "yeokcham-local-vault", displayName: "Yeokcham local vault" },
            pubKeyCredParams: [{ type: "public-key", alg: -7 }],
            authenticatorSelection: { residentKey: "required", userVerification: "required" },
            attestation: "none",
            timeout: WEBAUTHN_TIMEOUT_MS,
            extensions: { prf: { eval: { first: copies(salt) } } },
          },
        });
      } catch {
        fail("webauthn-unavailable", "browser WebAuthn credential creation is unavailable or rejected");
      }
      const credentialId = createdCredentialId(credential);
      requireCreationPrf(credential);
      const record = {
        version: VAULT_VERSION,
        origin: this.origin,
        rpId: validateOrigin(this.origin).rpId,
        credentialId: base64UrlEncode(credentialId),
        salt: base64UrlEncode(salt),
        iv: base64UrlEncode(randomBytes(this.crypto, AES_GCM_IV_BYTES)),
        ciphertext: base64UrlEncode(new Uint8Array(AES_GCM_TAG_BYTES + plaintext.length)),
      };
      const expected = validateRecord(record, this.origin);
      const prf = await passkeyPrf({ webAuthn: this.webAuthn, expected, crypto: this.crypto });
      try {
        record.ciphertext = base64UrlEncode(await encryptCapability({ crypto: this.crypto, record, prf, capability: plaintext }));
        if (!(await putVaultRecord(this.store, record))) {
          fail("vault-already-enrolled", "browser vault became occupied during enrolment");
        }
      } finally {
        prf.fill(0);
      }
    } finally {
      plaintext.fill(0);
      salt.fill(0);
    }
  }

  async unlock() {
    this.logout();
    const stored = await readVaultRecord(this.store);
    if (!stored) fail("vault-missing", "browser vault has no enrolled record");
    const expected = validateRecord(stored, this.origin);
    const prf = await passkeyPrf({ webAuthn: this.webAuthn, expected, crypto: this.crypto });
    try {
      const plaintext = await decryptCapability({ crypto: this.crypto, record: expected.record, prf, ciphertext: expected.ciphertext });
      if (plaintext.length === 0 || plaintext.length > MAX_CAPABILITY_BYTES) {
        plaintext.fill(0);
        fail("vault-corrupt", "browser vault plaintext length is invalid");
      }
      this.active = plaintext;
      return copies(plaintext);
    } finally {
      prf.fill(0);
    }
  }

  async remove() {
    this.logout();
    try {
      await this.store.remove();
    } catch {
      fail("storage-unavailable", "browser vault could not remove its local record");
    }
  }
}

function requestResult(request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("IndexedDB request failed"));
  });
}

function transactionResult(transaction) {
  return new Promise((resolve, reject) => {
    transaction.oncomplete = () => resolve();
    transaction.onabort = () => reject(transaction.error ?? new Error("IndexedDB transaction aborted"));
    transaction.onerror = () => reject(transaction.error ?? new Error("IndexedDB transaction failed"));
  });
}

export class IndexedDbVaultStore {
  constructor(indexedDb = globalThis.indexedDB) {
    if (!indexedDb || typeof indexedDb.open !== "function") {
      fail("storage-unavailable", "browser IndexedDB is unavailable");
    }
    this.indexedDb = indexedDb;
  }

  async database() {
    const open = this.indexedDb.open(DATABASE_NAME, VAULT_VERSION);
    open.onupgradeneeded = () => {
      if (!open.result.objectStoreNames.contains(STORE_NAME)) {
        open.result.createObjectStore(STORE_NAME);
      }
    };
    try {
      return await requestResult(open);
    } catch {
      fail("storage-unavailable", "browser IndexedDB could not open the vault");
    }
  }

  async read() {
    const database = await this.database();
    const transaction = database.transaction(STORE_NAME, "readonly");
    try {
      const value = await requestResult(transaction.objectStore(STORE_NAME).get(STORE_KEY));
      await transactionResult(transaction);
      return value === undefined ? undefined : cloneRecord(value);
    } catch {
      fail("storage-unavailable", "browser IndexedDB could not read the vault");
    } finally {
      database.close();
    }
  }

  async putIfAbsent(record) {
    const database = await this.database();
    const transaction = database.transaction(STORE_NAME, "readwrite");
    const request = transaction.objectStore(STORE_NAME).add(cloneRecord(record), STORE_KEY);
    try {
      await requestResult(request);
      await transactionResult(transaction);
      return true;
    } catch (error) {
      if (error?.name === "ConstraintError") return false;
      fail("storage-unavailable", "browser IndexedDB could not store the vault");
    } finally {
      database.close();
    }
  }

  async remove() {
    const database = await this.database();
    const transaction = database.transaction(STORE_NAME, "readwrite");
    try {
      await requestResult(transaction.objectStore(STORE_NAME).delete(STORE_KEY));
      await transactionResult(transaction);
    } finally {
      database.close();
    }
  }
}

export function browserWebAuthn(navigatorLike = globalThis.navigator) {
  if (!navigatorLike?.credentials || typeof navigatorLike.credentials.create !== "function" || typeof navigatorLike.credentials.get !== "function") {
    fail("webauthn-unavailable", "browser WebAuthn API is unavailable");
  }
  return {
    create: (options) => navigatorLike.credentials.create(options),
    get: (options) => navigatorLike.credentials.get(options),
  };
}
