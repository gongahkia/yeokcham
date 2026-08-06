type error =
  | Store_error of Paengi_store.error
  | Device_error of Paengi_device.error
  | Unexpected_object_type of {
      expected : Paengi_envelope.object_type;
      actual : Paengi_envelope.object_type;
    }

val error_to_string : error -> string

val store_identity :
  Paengi_store.repository ->
  Paengi_device.t ->
  (Paengi_store.Stored_object_id.t, error) result

val load_identity :
  Paengi_store.repository ->
  Paengi_store.Stored_object_id.t ->
  (Paengi_device.t, error) result

val registry_entry :
  Paengi_store.repository ->
  Paengi_store.Stored_object_id.t ->
  (Paengi_device.registry_entry, error) result

val registry_of_objects :
  Paengi_store.repository ->
  Paengi_store.Stored_object_id.t list ->
  (Paengi_device.registry, error) result
