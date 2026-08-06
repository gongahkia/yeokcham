module Bundle = Paengi_bundle
module Object_id = Paengi_store.Stored_object_id
module Store = Paengi_store

type error =
  | Store_error of Store.error
  | Bundle_error of Bundle.error
  | Entropy_failure of string

let ( let* ) = Result.bind

let error_to_string = function
  | Store_error error -> Store.error_to_string error
  | Bundle_error error -> Bundle.error_to_string error
  | Entropy_failure detail -> "bundle entropy failure: " ^ detail

let random_nonce () =
  try
    Mirage_crypto_rng_unix.use_default ();
    Mirage_crypto_rng.generate 12
    |> Bundle.nonce_of_bytes
    |> Result.map_error (fun error -> Bundle_error error)
  with _ -> Error (Entropy_failure "OS CSPRNG unavailable")

let export repository ~key ~object_ids =
  if List.length object_ids > Bundle.max_entries then
    Error (Bundle_error (Bundle.Invalid_entry_count (List.length object_ids)))
  else
    let rec entries values = function
      | [] -> Ok (List.rev values)
      | object_id :: rest ->
          let* envelope =
            Store.get repository object_id
            |> Result.map_error (fun error -> Store_error error)
          in
          let* entry =
            Bundle.entry_of_envelope ~object_id envelope
            |> Result.map_error (fun error -> Bundle_error error)
          in
          entries (entry :: values) rest
    in
    let* entries = entries [] object_ids in
    let* plaintext =
      Bundle.make_plaintext entries
      |> Result.map_error (fun error -> Bundle_error error)
    in
    let* nonce = random_nonce () in
    Bundle.seal ~repository_format:Store.repository_format ~key ~nonce plaintext
    |> Result.map Bundle.encode
    |> Result.map_error (fun error -> Bundle_error error)

let import repository ~key bytes =
  let* bundle =
    Bundle.decode bytes |> Result.map_error (fun error -> Bundle_error error)
  in
  let* plaintext =
    Bundle.open_bundle ~repository_format:Store.repository_format ~key bundle
    |> Result.map_error (fun error -> Bundle_error error)
  in
  let rec publish published = function
    | [] -> Ok (List.rev published)
    | entry :: rest ->
        let expected = Bundle.entry_object_id entry in
        let* actual =
          Store.put repository (Bundle.entry_envelope entry)
          |> Result.map_error (fun error -> Store_error error)
        in
        if not (Object_id.equal expected actual) then
          Error
            (Bundle_error (Bundle.Object_identity_mismatch { expected; actual }))
        else publish (actual :: published) rest
  in
  publish [] (Bundle.plaintext_entries plaintext)
