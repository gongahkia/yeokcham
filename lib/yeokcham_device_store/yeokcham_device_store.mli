type error =
  | Store_error of Yeokcham_store.error
  | Device_error of Yeokcham_device.error
  | Unexpected_object_type of {
      expected : Yeokcham_envelope.object_type;
      actual : Yeokcham_envelope.object_type;
    }

val error_to_string : error -> string

val store_identity :
  Yeokcham_store.repository ->
  Yeokcham_device.t ->
  (Yeokcham_store.Stored_object_id.t, error) result

val load_identity :
  Yeokcham_store.repository ->
  Yeokcham_store.Stored_object_id.t ->
  (Yeokcham_device.t, error) result

val registry_entry :
  Yeokcham_store.repository ->
  Yeokcham_store.Stored_object_id.t ->
  (Yeokcham_device.registry_entry, error) result

val registry_of_objects :
  Yeokcham_store.repository ->
  Yeokcham_store.Stored_object_id.t list ->
  (Yeokcham_device.registry, error) result
