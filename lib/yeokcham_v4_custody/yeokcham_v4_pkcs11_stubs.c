#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* Minimal Cryptoki declarations.  Loading the module dynamically avoids a
 * vendor SDK dependency; only standard PKCS#11 functions are used. */
typedef unsigned char CK_BYTE;
typedef unsigned char CK_BBOOL;
typedef unsigned long CK_ULONG;
typedef CK_ULONG CK_RV;
typedef CK_ULONG CK_SLOT_ID;
typedef CK_ULONG CK_SESSION_HANDLE;
typedef CK_ULONG CK_OBJECT_HANDLE;
typedef CK_ULONG CK_FLAGS;
typedef CK_ULONG CK_ATTRIBUTE_TYPE;
typedef CK_ULONG CK_MECHANISM_TYPE;

typedef struct CK_VERSION { CK_BYTE major; CK_BYTE minor; } CK_VERSION;
typedef struct CK_TOKEN_INFO {
  CK_BYTE label[32]; CK_BYTE manufacturerID[32]; CK_BYTE model[16];
  CK_BYTE serialNumber[16]; CK_FLAGS flags; CK_ULONG ulMaxSessionCount;
  CK_ULONG ulSessionCount; CK_ULONG ulMaxRwSessionCount; CK_ULONG ulRwSessionCount;
  CK_ULONG ulMaxPinLen; CK_ULONG ulMinPinLen; CK_ULONG ulTotalPublicMemory;
  CK_ULONG ulFreePublicMemory; CK_ULONG ulTotalPrivateMemory;
  CK_ULONG ulFreePrivateMemory; CK_VERSION hardwareVersion;
  CK_VERSION firmwareVersion; CK_BYTE utcTime[16];
} CK_TOKEN_INFO;
typedef struct CK_ATTRIBUTE {
  CK_ATTRIBUTE_TYPE type; void *pValue; CK_ULONG ulValueLen;
} CK_ATTRIBUTE;
typedef struct CK_MECHANISM {
  CK_MECHANISM_TYPE mechanism; void *pParameter; CK_ULONG ulParameterLen;
} CK_MECHANISM;

typedef struct CK_FUNCTION_LIST {
  CK_VERSION version;
  void *functions[96];
} CK_FUNCTION_LIST;

typedef CK_RV (*C_GetFunctionListFn)(CK_FUNCTION_LIST **);
typedef CK_RV (*C_InitializeFn)(void *);
typedef CK_RV (*C_FinalizeFn)(void *);
typedef CK_RV (*C_GetSlotListFn)(CK_BBOOL, CK_SLOT_ID *, CK_ULONG *);
typedef CK_RV (*C_GetTokenInfoFn)(CK_SLOT_ID, CK_TOKEN_INFO *);
typedef CK_RV (*C_OpenSessionFn)(CK_SLOT_ID, CK_FLAGS, void *, void *, CK_SESSION_HANDLE *);
typedef CK_RV (*C_CloseSessionFn)(CK_SESSION_HANDLE);
typedef CK_RV (*C_LoginFn)(CK_SESSION_HANDLE, CK_ULONG, CK_BYTE *, CK_ULONG);
typedef CK_RV (*C_LogoutFn)(CK_SESSION_HANDLE);
typedef CK_RV (*C_GetAttributeValueFn)(CK_SESSION_HANDLE, CK_OBJECT_HANDLE, CK_ATTRIBUTE *, CK_ULONG);
typedef CK_RV (*C_FindObjectsInitFn)(CK_SESSION_HANDLE, CK_ATTRIBUTE *, CK_ULONG);
typedef CK_RV (*C_FindObjectsFn)(CK_SESSION_HANDLE, CK_OBJECT_HANDLE *, CK_ULONG, CK_ULONG *);
typedef CK_RV (*C_FindObjectsFinalFn)(CK_SESSION_HANDLE);
typedef CK_RV (*C_SignInitFn)(CK_SESSION_HANDLE, CK_MECHANISM *, CK_OBJECT_HANDLE);
typedef CK_RV (*C_SignFn)(CK_SESSION_HANDLE, CK_BYTE *, CK_ULONG, CK_BYTE *, CK_ULONG *);
typedef CK_RV (*C_GenerateKeyPairFn)(CK_SESSION_HANDLE, CK_MECHANISM *, CK_ATTRIBUTE *, CK_ULONG, CK_ATTRIBUTE *, CK_ULONG, CK_OBJECT_HANDLE *, CK_OBJECT_HANDLE *);

enum { V4_OK = 0, V4_UNAVAILABLE = 1, V4_KEY_MISSING = 2, V4_LOCKED = 3,
       V4_UNSUPPORTED = 4, V4_INVALID = 5, V4_KEY_AMBIGUOUS = 6,
       V4_NOT_NONEXTRACTABLE = 7 };

#define CKR_OK 0x00000000UL
#define CKR_CRYPTOKI_ALREADY_INITIALIZED 0x00000191UL
#define CKR_USER_ALREADY_LOGGED_IN 0x00000100UL
#define CKR_PIN_INCORRECT 0x000000A0UL
#define CKR_PIN_LOCKED 0x000000A4UL
#define CKR_USER_NOT_LOGGED_IN 0x00000101UL
#define CKR_MECHANISM_INVALID 0x00000070UL
#define CKR_KEY_TYPE_INCONSISTENT 0x00000063UL
#define CKF_RW_SESSION 0x00000002UL
#define CKF_SERIAL_SESSION 0x00000004UL
#define CKU_USER 1UL
#define CKO_PUBLIC_KEY 2UL
#define CKO_PRIVATE_KEY 3UL
#define CKK_EC_EDWARDS 0x00000040UL
#define CKA_CLASS 0x00000000UL
#define CKA_TOKEN 0x00000001UL
#define CKA_PRIVATE 0x00000002UL
#define CKA_LABEL 0x00000003UL
#define CKA_VALUE 0x00000011UL
#define CKA_KEY_TYPE 0x00000100UL
#define CKA_ID 0x00000102UL
#define CKA_SENSITIVE 0x00000103UL
#define CKA_EXTRACTABLE 0x00000162UL
#define CKA_EC_PARAMS 0x00000180UL
#define CKA_EC_POINT 0x00000181UL
#define CKA_SIGN 0x00000108UL
#define CKA_VERIFY 0x0000010AUL
#define CKM_EC_EDWARDS_KEY_PAIR_GEN 0x00001055UL
#define CKM_EDDSA 0x00001057UL

struct ctx {
  void *handle; CK_FUNCTION_LIST *f; int initialized;
  CK_SESSION_HANDLE session; int session_open; int logged_in;
};

static value result_for(int status, const char *bytes, size_t length) {
  CAMLparam0(); CAMLlocal3(result, option, text);
  if (bytes == NULL) option = Val_int(0);
  else { text = caml_alloc_string(length); memcpy((char *)String_val(text), bytes, length);
         option = caml_alloc_small(1, 0); Store_field(option, 0, text); }
  result = caml_alloc_small(2, 0); Store_field(result, 0, Val_int(status));
  Store_field(result, 1, option); CAMLreturn(result);
}

static int status_for(CK_RV rv) {
  if (rv == CKR_PIN_INCORRECT || rv == CKR_PIN_LOCKED || rv == CKR_USER_NOT_LOGGED_IN)
    return V4_LOCKED;
  if (rv == CKR_MECHANISM_INVALID || rv == CKR_KEY_TYPE_INCONSISTENT) return V4_UNSUPPORTED;
  return V4_UNAVAILABLE;
}

static void cleanup(struct ctx *ctx) {
  if (ctx->session_open) {
    if (ctx->logged_in) ((C_LogoutFn)ctx->f->functions[19])(ctx->session);
    ((C_CloseSessionFn)ctx->f->functions[13])(ctx->session);
  }
  if (ctx->initialized) ((C_FinalizeFn)ctx->f->functions[1])(NULL);
  if (ctx->handle != NULL) dlclose(ctx->handle);
}

static int open_module(const char *path, struct ctx *ctx) {
  C_GetFunctionListFn get_list; C_InitializeFn initialize; CK_RV rv;
  memset(ctx, 0, sizeof(*ctx));
  ctx->handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (ctx->handle == NULL) return V4_UNAVAILABLE;
  get_list = (C_GetFunctionListFn)dlsym(ctx->handle, "C_GetFunctionList");
  if (get_list == NULL || get_list(&ctx->f) != CKR_OK || ctx->f == NULL) return V4_UNAVAILABLE;
  initialize = (C_InitializeFn)ctx->f->functions[0];
  rv = initialize(NULL);
  if (rv == CKR_OK) ctx->initialized = 1;
  else if (rv != CKR_CRYPTOKI_ALREADY_INITIALIZED) return status_for(rv);
  return V4_OK;
}

static int selected_slot(struct ctx *ctx, const char *label, CK_SLOT_ID *out) {
  C_GetSlotListFn list = (C_GetSlotListFn)ctx->f->functions[4];
  C_GetTokenInfoFn info = (C_GetTokenInfoFn)ctx->f->functions[6];
  CK_SLOT_ID *slots = NULL; CK_ULONG count = 0, i; CK_RV rv;
  rv = list(1, NULL, &count); if (rv != CKR_OK || count == 0 || count > 1024) return V4_UNAVAILABLE;
  slots = calloc(count, sizeof(*slots)); if (slots == NULL) return V4_UNAVAILABLE;
  rv = list(1, slots, &count); if (rv != CKR_OK) { free(slots); return V4_UNAVAILABLE; }
  for (i = 0; i < count; ++i) {
    CK_TOKEN_INFO token; char token_label[33]; size_t end = 32;
    if (info(slots[i], &token) != CKR_OK) continue;
    while (end > 0 && token.label[end - 1] == ' ') --end;
    memcpy(token_label, token.label, end); token_label[end] = '\0';
    if (strcmp(token_label, label) == 0) { *out = slots[i]; free(slots); return V4_OK; }
  }
  free(slots); return V4_KEY_MISSING;
}

static int open_session(struct ctx *ctx, const char *label, const char *pin) {
  C_OpenSessionFn open = (C_OpenSessionFn)ctx->f->functions[12];
  C_LoginFn login = (C_LoginFn)ctx->f->functions[18]; CK_SLOT_ID slot; CK_RV rv; int status;
  status = selected_slot(ctx, label, &slot); if (status != V4_OK) return status;
  /* Key generation changes token state and therefore needs a read/write
     session. It is also valid for the read-only operations used here. */
  rv = open(slot, CKF_SERIAL_SESSION | CKF_RW_SESSION, NULL, NULL, &ctx->session);
  if (rv != CKR_OK) return status_for(rv);
  ctx->session_open = 1;
  if (pin == NULL) return V4_OK;
  rv = login(ctx->session, CKU_USER, (CK_BYTE *)pin, (CK_ULONG)strlen(pin));
  if (rv == CKR_OK || rv == CKR_USER_ALREADY_LOGGED_IN) { ctx->logged_in = (rv == CKR_OK); return V4_OK; }
  return status_for(rv);
}

static int find_key(struct ctx *ctx, CK_ULONG class_, const char *key_id, size_t key_id_len, CK_OBJECT_HANDLE *out) {
  C_FindObjectsInitFn init = (C_FindObjectsInitFn)ctx->f->functions[26];
  C_FindObjectsFn find = (C_FindObjectsFn)ctx->f->functions[27];
  C_FindObjectsFinalFn finish = (C_FindObjectsFinalFn)ctx->f->functions[28];
  CK_ATTRIBUTE attrs[2]; CK_OBJECT_HANDLE found[2]; CK_ULONG count = 0; CK_RV rv;
  attrs[0].type = CKA_CLASS; attrs[0].pValue = &class_; attrs[0].ulValueLen = sizeof(class_);
  attrs[1].type = CKA_ID; attrs[1].pValue = (void *)key_id; attrs[1].ulValueLen = (CK_ULONG)key_id_len;
  rv = init(ctx->session, attrs, 2); if (rv != CKR_OK) return status_for(rv);
  rv = find(ctx->session, found, 2, &count); finish(ctx->session);
  if (rv != CKR_OK) return status_for(rv);
  if (count == 0) return V4_KEY_MISSING;
  if (count != 1) return V4_KEY_AMBIGUOUS;
  *out = found[0]; return V4_OK;
}

static int public_key_for(struct ctx *ctx, const char *key_id, size_t key_id_len, char raw[32]) {
  C_GetAttributeValueFn get = (C_GetAttributeValueFn)ctx->f->functions[24];
  CK_OBJECT_HANDLE object; CK_ATTRIBUTE attr; CK_RV rv; void *point; int status;
  status = find_key(ctx, CKO_PUBLIC_KEY, key_id, key_id_len, &object); if (status != V4_OK) return status;
  attr.type = CKA_EC_POINT; attr.pValue = NULL; attr.ulValueLen = 0;
  rv = get(ctx->session, object, &attr, 1); if (rv != CKR_OK || attr.ulValueLen == (CK_ULONG)-1 || attr.ulValueLen > 128) return status_for(rv);
  point = malloc(attr.ulValueLen); if (point == NULL) return V4_UNAVAILABLE;
  attr.pValue = point; rv = get(ctx->session, object, &attr, 1);
  if (rv != CKR_OK) { free(point); return status_for(rv); }
  if (attr.ulValueLen == 32) memcpy(raw, point, 32);
  else if (attr.ulValueLen >= 34 && ((CK_BYTE *)point)[0] == 0x04 && ((CK_BYTE *)point)[1] == attr.ulValueLen - 2)
    memcpy(raw, ((CK_BYTE *)point) + attr.ulValueLen - 32, 32);
  else { free(point); return V4_INVALID; }
  free(point); return V4_OK;
}

static int private_key_is_nonextractable(struct ctx *ctx, const char *key_id, size_t key_id_len) {
  C_GetAttributeValueFn get = (C_GetAttributeValueFn)ctx->f->functions[24];
  CK_OBJECT_HANDLE object; CK_BBOOL sensitive = 0, extractable = 1;
  CK_ATTRIBUTE attrs[2]; CK_RV rv; int status;
  status = find_key(ctx, CKO_PRIVATE_KEY, key_id, key_id_len, &object);
  if (status != V4_OK) return status;
  attrs[0] = (CK_ATTRIBUTE){ CKA_SENSITIVE, &sensitive, sizeof(sensitive) };
  attrs[1] = (CK_ATTRIBUTE){ CKA_EXTRACTABLE, &extractable, sizeof(extractable) };
  rv = get(ctx->session, object, attrs, 2);
  if (rv != CKR_OK) return status_for(rv);
  return sensitive && !extractable ? V4_OK : V4_NOT_NONEXTRACTABLE;
}

CAMLprim value caml_yeokcham_v4_pkcs11_public(value module_path, value token_label, value key_id) {
  CAMLparam3(module_path, token_label, key_id); struct ctx ctx; char raw[32]; int status;
  status = open_module(String_val(module_path), &ctx);
  if (status == V4_OK) status = open_session(&ctx, String_val(token_label), NULL);
  if (status == V4_OK) status = public_key_for(&ctx, String_val(key_id), caml_string_length(key_id), raw);
  cleanup(&ctx); CAMLreturn(result_for(status, status == V4_OK ? raw : NULL, 32));
}

CAMLprim value caml_yeokcham_v4_pkcs11_sign(value module_path, value token_label, value key_id, value pin, value data) {
  CAMLparam5(module_path, token_label, key_id, pin, data); struct ctx ctx; CK_OBJECT_HANDLE key;
  CK_MECHANISM mechanism; C_SignInitFn init; C_SignFn sign; CK_ULONG length = 0; CK_RV rv; CK_BYTE *out = NULL; int status;
  status = open_module(String_val(module_path), &ctx);
  if (status == V4_OK) status = open_session(&ctx, String_val(token_label), String_val(pin));
  if (status == V4_OK) status = find_key(&ctx, CKO_PRIVATE_KEY, String_val(key_id), caml_string_length(key_id), &key);
  if (status == V4_OK) {
    mechanism.mechanism = CKM_EDDSA; mechanism.pParameter = NULL; mechanism.ulParameterLen = 0;
    init = (C_SignInitFn)ctx.f->functions[42]; sign = (C_SignFn)ctx.f->functions[43];
    rv = init(ctx.session, &mechanism, key);
    if (rv != CKR_OK) status = status_for(rv);
    else { rv = sign(ctx.session, (CK_BYTE *)String_val(data), caml_string_length(data), NULL, &length);
           if (rv != CKR_OK || length != 64) status = (rv == CKR_OK ? V4_INVALID : status_for(rv));
           else { out = malloc(length); if (out == NULL) status = V4_UNAVAILABLE;
                  else { rv = sign(ctx.session, (CK_BYTE *)String_val(data), caml_string_length(data), out, &length);
                         if (rv != CKR_OK || length != 64) status = (rv == CKR_OK ? V4_INVALID : status_for(rv)); } } }
  }
  cleanup(&ctx); { value result = result_for(status, status == V4_OK ? (const char *)out : NULL, 64); free(out); CAMLreturn(result); }
}

CAMLprim value caml_yeokcham_v4_pkcs11_create(value module_path, value token_label, value key_id, value key_label, value pin) {
  CAMLparam5(module_path, token_label, key_id, key_label, pin); struct ctx ctx;
  CK_MECHANISM mechanism; C_GenerateKeyPairFn generate; CK_OBJECT_HANDLE public_key, private_key;
  CK_ULONG public_class = CKO_PUBLIC_KEY, private_class = CKO_PRIVATE_KEY, key_type = CKK_EC_EDWARDS;
  CK_BBOOL yes = 1, no = 0; CK_BYTE oid[] = { 0x06, 0x03, 0x2b, 0x65, 0x70 };
  CK_ATTRIBUTE public_template[7], private_template[9]; char raw[32]; CK_RV rv; int status;
  status = open_module(String_val(module_path), &ctx);
  if (status == V4_OK) status = open_session(&ctx, String_val(token_label), String_val(pin));
  if (status == V4_OK) {
    public_template[0] = (CK_ATTRIBUTE){ CKA_CLASS, &public_class, sizeof(public_class) };
    public_template[1] = (CK_ATTRIBUTE){ CKA_TOKEN, &yes, sizeof(yes) };
    public_template[2] = (CK_ATTRIBUTE){ CKA_PRIVATE, &no, sizeof(no) };
    public_template[3] = (CK_ATTRIBUTE){ CKA_KEY_TYPE, &key_type, sizeof(key_type) };
    public_template[4] = (CK_ATTRIBUTE){ CKA_EC_PARAMS, oid, sizeof(oid) };
    public_template[5] = (CK_ATTRIBUTE){ CKA_ID, (void *)String_val(key_id), caml_string_length(key_id) };
    public_template[6] = (CK_ATTRIBUTE){ CKA_LABEL, (void *)String_val(key_label), caml_string_length(key_label) };
    private_template[0] = (CK_ATTRIBUTE){ CKA_CLASS, &private_class, sizeof(private_class) };
    private_template[1] = (CK_ATTRIBUTE){ CKA_TOKEN, &yes, sizeof(yes) };
    private_template[2] = (CK_ATTRIBUTE){ CKA_PRIVATE, &yes, sizeof(yes) };
    private_template[3] = (CK_ATTRIBUTE){ CKA_KEY_TYPE, &key_type, sizeof(key_type) };
    private_template[4] = (CK_ATTRIBUTE){ CKA_SIGN, &yes, sizeof(yes) };
    private_template[5] = (CK_ATTRIBUTE){ CKA_SENSITIVE, &yes, sizeof(yes) };
    private_template[6] = (CK_ATTRIBUTE){ CKA_EXTRACTABLE, &no, sizeof(no) };
    private_template[7] = (CK_ATTRIBUTE){ CKA_ID, (void *)String_val(key_id), caml_string_length(key_id) };
    private_template[8] = (CK_ATTRIBUTE){ CKA_LABEL, (void *)String_val(key_label), caml_string_length(key_label) };
    mechanism.mechanism = CKM_EC_EDWARDS_KEY_PAIR_GEN; mechanism.pParameter = NULL; mechanism.ulParameterLen = 0;
    /* PKCS#11 C_GenerateKeyPair follows C_GenerateKey at slot 59 (zero-based).
       Slot 60 is C_WrapKey; calling it through this incompatible signature can
       make a token appear not to support Ed25519 even when it does. */
    generate = (C_GenerateKeyPairFn)ctx.f->functions[59];
    rv = generate(ctx.session, &mechanism, public_template, 7, private_template, 9, &public_key, &private_key);
    if (rv != CKR_OK) status = status_for(rv);
    else {
      status = private_key_is_nonextractable(&ctx, String_val(key_id), caml_string_length(key_id));
      if (status == V4_OK)
        status = public_key_for(&ctx, String_val(key_id), caml_string_length(key_id), raw);
    }
  }
  cleanup(&ctx); CAMLreturn(result_for(status, status == V4_OK ? raw : NULL, 32));
}
