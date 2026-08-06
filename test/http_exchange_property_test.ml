module Encoding = Paengi_encoding
module Envelope = Paengi_envelope
module Exchange = Paengi_exchange
module Http = Paengi_http_exchange
module Store = Paengi_store

let default_seed = 20_260_806

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | None -> default_seed
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed

let stable_seed name =
  let value = ref base_seed in
  String.iter
    (fun character ->
      value := !value * 65599 lxor Char.code character land max_int)
    name;
  !value

let state_for name = Random.State.make [| stable_seed name |]
let () = Printf.printf "HTTP exchange property base seed: %d\n%!" base_seed

let require = function
  | Ok value -> value
  | Error _ -> failwith "HTTP exchange property setup failed"

let content bytes =
  Envelope.create ~object_type:Envelope.Content
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features
    ~payload:(Encoding.bytes bytes) ()
  |> require

let session = Exchange.session_id_of_bytes "http-property-01" |> require

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

let with_repositories run =
  let root = Filename.temp_file "paengi-http-property-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  let source_root = Filename.concat root "source" in
  let destination_root = Filename.concat root "destination" in
  Unix.mkdir source_root 0o700;
  Unix.mkdir destination_root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      let source = Store.init ~root:source_root |> require in
      let destination = Store.init ~root:destination_root |> require in
      run source destination)

let send server request =
  match Http.handle !server request with
  | Ok (next, response) ->
      server := next;
      Ok response
  | Error error -> Error error

let state_machine_restart =
  let generator =
    QCheck2.Gen.triple
      (QCheck2.Gen.int_range 1 24)
      (QCheck2.Gen.int_range 0 24)
      QCheck2.Gen.bool
  in
  QCheck2.Test.make ~count:100
    ~name:"HTTP exchange restarts after bounded interruption without ref change"
    generator (fun (count, limit, corrupt) ->
      with_repositories (fun source destination ->
          let objects =
            List.init count (fun index ->
                Store.put source (content (string_of_int index)) |> require)
            |> List.sort Store.Stored_object_id.compare
          in
          let local =
            Store.put destination (content "destination") |> require
          in
          let reference =
            Store.compare_and_swap_ref destination ~name:"scratch-head"
              ~expected:None ~target:(Some local)
            |> require
          in
          let first_server = ref (Http.create_server destination |> require) in
          let interrupted = min limit (count - 1) in
          let first =
            Http.transfer_with ~interrupt_after:interrupted ~source
              ~send:(send first_server) ~session_id:session ~object_ids:objects
              ()
          in
          let interruption = Result.is_error first in
          let restart_server =
            ref (Http.create_server destination |> require)
          in
          let restarted =
            Http.transfer_with ~source ~send:(send restart_server)
              ~session_id:session ~object_ids:objects ()
          in
          let all_objects =
            Result.is_ok restarted
            && List.for_all
                 (fun object_id ->
                   Result.is_ok (Store.get destination object_id))
                 objects
          in
          let unchanged_ref =
            Store.read_ref destination ~name:"scratch-head"
            |> Result.fold
                 ~ok:(Option.exists (Store.Mutable_ref.equal reference))
                 ~error:(fun _ -> false)
          in
          let corruption =
            (not corrupt)
            || Result.is_error
                 (Http.handle !restart_server
                    "POST /v1/exchange HTTP/1.1\r\n\
                     Content-Length: 1\r\n\
                     \r\n\
                     \000")
          in
          interruption && all_objects && unchanged_ref && corruption))

let () =
  Alcotest.run "HTTP exchange properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "restart-corruption")
            state_machine_restart;
        ] );
    ]
