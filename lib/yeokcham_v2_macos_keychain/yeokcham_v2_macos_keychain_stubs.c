#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

#include <stdbool.h>

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

enum yeokcham_lookup_status {
  YEOKCHAM_FOUND = 0,
  YEOKCHAM_MISSING = 1,
  YEOKCHAM_LOCKED = 2,
  YEOKCHAM_UNAVAILABLE = 3,
  YEOKCHAM_NON_EXPORTABLE_KEY = 4,
  YEOKCHAM_UNSUPPORTED_KEY_ITEM = 5,
};

enum yeokcham_store_status {
  YEOKCHAM_STORED = 0,
  YEOKCHAM_ALREADY_PRESENT = 1,
  YEOKCHAM_STORE_LOCKED = 2,
  YEOKCHAM_STORE_UNAVAILABLE = 3,
};

enum yeokcham_remove_status {
  YEOKCHAM_REMOVED = 0,
  YEOKCHAM_REMOVE_MISSING = 1,
  YEOKCHAM_REMOVE_LOCKED = 2,
  YEOKCHAM_REMOVE_UNAVAILABLE = 3,
};

static int is_locked_status(OSStatus status) {
  return status == errSecInteractionNotAllowed || status == errSecAuthFailed ||
         status == errSecUserCanceled;
}

static CFStringRef cf_string_of_value(value input) {
  return CFStringCreateWithBytes(
      kCFAllocatorDefault, (const UInt8 *)String_val(input),
      (CFIndex)caml_string_length(input), kCFStringEncodingUTF8, false);
}

static CFDataRef cf_data_of_value(value input) {
  return CFDataCreate(kCFAllocatorDefault, (const UInt8 *)String_val(input),
                      (CFIndex)caml_string_length(input));
}

static CFMutableDictionaryRef generic_password_query(value service,
                                                     value account) {
  CFMutableDictionaryRef query = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 8, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CFStringRef service_string = cf_string_of_value(service);
  CFStringRef account_string = cf_string_of_value(account);
  if (query == NULL || service_string == NULL || account_string == NULL) {
    if (query != NULL) {
      CFRelease(query);
    }
    if (service_string != NULL) {
      CFRelease(service_string);
    }
    if (account_string != NULL) {
      CFRelease(account_string);
    }
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

static CFMutableDictionaryRef key_query(value legacy_key_tag) {
  CFMutableDictionaryRef query = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 5, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CFDataRef tag = cf_data_of_value(legacy_key_tag);
  if (query == NULL || tag == NULL) {
    if (query != NULL) {
      CFRelease(query);
    }
    if (tag != NULL) {
      CFRelease(tag);
    }
    return NULL;
  }
  CFDictionarySetValue(query, kSecClass, kSecClassKey);
  CFDictionarySetValue(query, kSecAttrApplicationTag, tag);
  CFDictionarySetValue(query, kSecUseDataProtectionKeychain, kCFBooleanTrue);
  CFDictionarySetValue(query, kSecReturnRef, kCFBooleanTrue);
  CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne);
  CFRelease(tag);
  return query;
}

static int probe_legacy_key(value legacy_key_tag) {
  CFMutableDictionaryRef query = key_query(legacy_key_tag);
  CFTypeRef result = NULL;
  if (query == NULL) {
    return YEOKCHAM_UNAVAILABLE;
  }
  OSStatus status = SecItemCopyMatching(query, &result);
  CFRelease(query);
  if (status == errSecItemNotFound) {
    return YEOKCHAM_MISSING;
  }
  if (is_locked_status(status)) {
    return YEOKCHAM_LOCKED;
  }
  if (status != errSecSuccess || result == NULL ||
      CFGetTypeID(result) != SecKeyGetTypeID()) {
    if (result != NULL) {
      CFRelease(result);
    }
    return YEOKCHAM_UNAVAILABLE;
  }
  CFErrorRef error = NULL;
  CFDataRef external =
      SecKeyCopyExternalRepresentation((SecKeyRef)result, &error);
  CFRelease(result);
  if (error != NULL) {
    CFRelease(error);
  }
  if (external == NULL) {
    return YEOKCHAM_NON_EXPORTABLE_KEY;
  }
  CFRelease(external);
  return YEOKCHAM_UNSUPPORTED_KEY_ITEM;
}

static value lookup_result(int status, CFDataRef data) {
  CAMLparam0();
  CAMLlocal3(result, payload, contents);
  if (data == NULL) {
    payload = Val_int(0);
  } else {
    CFIndex length = CFDataGetLength(data);
    if (length < 0 || (uintnat)length > Max_wosize) {
      payload = Val_int(0);
      status = YEOKCHAM_UNAVAILABLE;
    } else {
      contents = caml_alloc_string((mlsize_t)length);
      CFDataGetBytes(data, CFRangeMake(0, length),
                     (UInt8 *)String_val(contents));
      payload = caml_alloc_small(1, 0);
      Store_field(payload, 0, contents);
    }
  }
  result = caml_alloc_small(2, 0);
  Store_field(result, 0, Val_int(status));
  Store_field(result, 1, payload);
  CAMLreturn(result);
}

CAMLprim value caml_yeokcham_v2_macos_keychain_lookup(value service,
                                                       value account,
                                                       value legacy_key_tag) {
  CAMLparam3(service, account, legacy_key_tag);
  CAMLlocal1(outcome);
  CFMutableDictionaryRef query = generic_password_query(service, account);
  CFTypeRef result = NULL;
  if (query == NULL) {
    CAMLreturn(lookup_result(YEOKCHAM_UNAVAILABLE, NULL));
  }
  CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);
  CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne);
  OSStatus status = SecItemCopyMatching(query, &result);
  CFRelease(query);
  if (status == errSecSuccess && result != NULL &&
      CFGetTypeID(result) == CFDataGetTypeID()) {
    outcome = lookup_result(YEOKCHAM_FOUND, (CFDataRef)result);
    CFRelease(result);
    CAMLreturn(outcome);
  }
  if (result != NULL) {
    CFRelease(result);
  }
  if (status == errSecItemNotFound) {
    int key_status = probe_legacy_key(legacy_key_tag);
    CAMLreturn(lookup_result(key_status, NULL));
  }
  if (is_locked_status(status)) {
    CAMLreturn(lookup_result(YEOKCHAM_LOCKED, NULL));
  }
  CAMLreturn(lookup_result(YEOKCHAM_UNAVAILABLE, NULL));
}

CAMLprim value caml_yeokcham_v2_macos_keychain_store(value service,
                                                      value account,
                                                      value contents) {
  CAMLparam3(service, account, contents);
  CFMutableDictionaryRef query = generic_password_query(service, account);
  CFDataRef data = cf_data_of_value(contents);
  if (query == NULL || data == NULL) {
    if (query != NULL) {
      CFRelease(query);
    }
    if (data != NULL) {
      CFRelease(data);
    }
    CAMLreturn(Val_int(YEOKCHAM_STORE_UNAVAILABLE));
  }
  CFDictionarySetValue(query, kSecValueData, data);
  CFDictionarySetValue(query, kSecAttrAccessible,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly);
  CFDictionarySetValue(query, kSecAttrLabel,
                       CFSTR("Yeokcham V2 local device capability"));
  OSStatus status = SecItemAdd(query, NULL);
  CFRelease(data);
  CFRelease(query);
  if (status == errSecSuccess) {
    CAMLreturn(Val_int(YEOKCHAM_STORED));
  }
  if (status == errSecDuplicateItem) {
    CAMLreturn(Val_int(YEOKCHAM_ALREADY_PRESENT));
  }
  if (is_locked_status(status)) {
    CAMLreturn(Val_int(YEOKCHAM_STORE_LOCKED));
  }
  CAMLreturn(Val_int(YEOKCHAM_STORE_UNAVAILABLE));
}

CAMLprim value caml_yeokcham_v2_macos_keychain_remove(value service,
                                                       value account) {
  CAMLparam2(service, account);
  CFMutableDictionaryRef query = generic_password_query(service, account);
  if (query == NULL) {
    CAMLreturn(Val_int(YEOKCHAM_REMOVE_UNAVAILABLE));
  }
  OSStatus status = SecItemDelete(query);
  CFRelease(query);
  if (status == errSecSuccess) {
    CAMLreturn(Val_int(YEOKCHAM_REMOVED));
  }
  if (status == errSecItemNotFound) {
    CAMLreturn(Val_int(YEOKCHAM_REMOVE_MISSING));
  }
  if (is_locked_status(status)) {
    CAMLreturn(Val_int(YEOKCHAM_REMOVE_LOCKED));
  }
  CAMLreturn(Val_int(YEOKCHAM_REMOVE_UNAVAILABLE));
}
