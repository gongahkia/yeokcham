module Encoding = Paengi_encoding
module Envelope = Paengi_envelope
module Store = Paengi_store

let default_seed = 20_260_729

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | None -> default_seed
  | Some value -> (
      match int_of_string_opt value with
      | Some seed -> seed
      | None -> default_seed)

let stable_seed name =
  let value = ref base_seed in
  String.iter
    (fun character ->
      value := !value * 65599 lxor Char.code character land max_int)
    name;
  !value

let state_for name = Random.State.make [| stable_seed name |]
let () = Printf.printf "store property base seed: %d\n%!" base_seed

let require_envelope = function
  | Ok envelope -> envelope
  | Error error -> failwith (Envelope.creation_error_to_string error)

let content_envelope bytes =
  Envelope.create ~object_type:Envelope.Content
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features
    ~payload:(Encoding.bytes bytes) ()
  |> require_envelope

let rec remove_tree path =
  try
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun name -> remove_tree (Filename.concat path name));
        Unix.rmdir path
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
    | Unix.S_SOCK ->
        Unix.unlink path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_repository check =
  let root = Filename.temp_file "paengi-store-property-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      match Store.init ~root with
      | Error _ -> false
      | Ok repository -> check root repository)

let bytes_generator = QCheck2.Gen.string_size (QCheck2.Gen.int_range 0 4096)

let restart_round_trip =
  QCheck2.Test.make ~count:100 ~name:"store put/reopen/get is exact"
    bytes_generator (fun bytes ->
      with_repository (fun root repository ->
          let envelope = content_envelope bytes in
          match Store.put repository envelope with
          | Error _ -> false
          | Ok id -> (
              match Store.put repository envelope with
              | Error _ -> false
              | Ok duplicate -> (
                  if not (Store.Stored_object_id.equal id duplicate) then false
                  else
                    match Store.open_repository ~root with
                    | Error _ -> false
                    | Ok reopened -> (
                        match Store.get reopened id with
                        | Ok actual ->
                            String.equal (Envelope.encode envelope)
                              (Envelope.encode actual)
                        | Error _ -> false)))))

let () =
  Alcotest.run "object store properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "restart-round-trip")
            restart_round_trip;
        ] );
    ]
