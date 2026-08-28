#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

enum { FOUND = 0, MISSING = 1, LOCKED = 2, UNAVAILABLE = 3 };
enum { STORED = 0, ALREADY_PRESENT = 1, STORE_LOCKED = 2, STORE_UNAVAILABLE = 3 };

static int locked(OSStatus status) {
  return status == errSecInteractionNotAllowed || status == errSecAuthFailed ||
         status == errSecUserCanceled;
}

static CFStringRef string_of(value input) {
  return CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)String_val(input),
      (CFIndex)caml_string_length(input), kCFStringEncodingUTF8, false);
}

static CFMutableDictionaryRef query_for(value service, value account) {
  CFMutableDictionaryRef query = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 8, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CFStringRef service_string = string_of(service);
  CFStringRef account_string = string_of(account);
  if (query == NULL || service_string == NULL || account_string == NULL) {
    if (query != NULL) CFRelease(query);
    if (service_string != NULL) CFRelease(service_string);
    if (account_string != NULL) CFRelease(account_string);
    return NULL;
  }
  CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword);
  CFDictionarySetValue(query, kSecAttrService, service_string);
  CFDictionarySetValue(query, kSecAttrAccount, account_string);
  CFDictionarySetValue(query, kSecAttrSynchronizable, kCFBooleanFalse);
  CFDictionarySetValue(query, kSecUseDataProtectionKeychain, kCFBooleanTrue);
  CFRelease(service_string);
  CFRelease(account_string);
  return query;
}

static value result_for(int status, CFDataRef data) {
  CAMLparam0();
  CAMLlocal3(result, option, bytes);
  if (data == NULL || CFDataGetLength(data) < 0 ||
      (uintnat)CFDataGetLength(data) > Max_wosize) {
    option = Val_int(0);
  } else {
    CFIndex length = CFDataGetLength(data);
    bytes = caml_alloc_string((mlsize_t)length);
    CFDataGetBytes(data, CFRangeMake(0, length), (UInt8 *)String_val(bytes));
    option = caml_alloc_small(1, 0);
    Store_field(option, 0, bytes);
  }
  result = caml_alloc_small(2, 0);
  Store_field(result, 0, Val_int(status));
  Store_field(result, 1, option);
  CAMLreturn(result);
}

CAMLprim value caml_yeokcham_v4_macos_keychain_lookup(value service, value account) {
  CAMLparam2(service, account);
  CAMLlocal1(outcome);
  CFMutableDictionaryRef query = query_for(service, account);
  CFTypeRef result = NULL;
  if (query == NULL) CAMLreturn(result_for(UNAVAILABLE, NULL));
  CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);
  CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne);
  OSStatus status = SecItemCopyMatching(query, &result);
  CFRelease(query);
  if (status == errSecSuccess && result != NULL && CFGetTypeID(result) == CFDataGetTypeID()) {
    outcome = result_for(FOUND, (CFDataRef)result);
    CFRelease(result);
    CAMLreturn(outcome);
  }
  if (result != NULL) CFRelease(result);
  if (status == errSecItemNotFound) CAMLreturn(result_for(MISSING, NULL));
  if (locked(status)) CAMLreturn(result_for(LOCKED, NULL));
  CAMLreturn(result_for(UNAVAILABLE, NULL));
}

CAMLprim value caml_yeokcham_v4_macos_keychain_store(value service, value account, value contents) {
  CAMLparam3(service, account, contents);
  CFMutableDictionaryRef query = query_for(service, account);
  CFDataRef data = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)String_val(contents),
      (CFIndex)caml_string_length(contents));
  if (query == NULL || data == NULL) {
    if (query != NULL) CFRelease(query);
    if (data != NULL) CFRelease(data);
    CAMLreturn(Val_int(STORE_UNAVAILABLE));
  }
  CFDictionarySetValue(query, kSecValueData, data);
  CFDictionarySetValue(query, kSecAttrAccessible,
      kSecAttrAccessibleWhenUnlockedThisDeviceOnly);
  CFDictionarySetValue(query, kSecAttrLabel, CFSTR("Yeokcham V4 device signing key"));
  OSStatus status = SecItemAdd(query, NULL);
  CFRelease(data);
  CFRelease(query);
  if (status == errSecSuccess) CAMLreturn(Val_int(STORED));
  if (status == errSecDuplicateItem) CAMLreturn(Val_int(ALREADY_PRESENT));
  if (locked(status)) CAMLreturn(Val_int(STORE_LOCKED));
  CAMLreturn(Val_int(STORE_UNAVAILABLE));
}
