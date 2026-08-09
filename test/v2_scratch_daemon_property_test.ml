module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Runner = Yeokcham_v2_scratch_daemon
module Scheduler = Yeokcham_v2_scratch_scheduler
module Store = Yeokcham_store
module V2_model = Yeokcham_v2_model
module Watcher = Yeokcham_watcher

let default_seed = 20_260_809

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | None -> default_seed
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed

let state_for name =
  let value = ref base_seed in
  String.iter
    (fun character ->
      value := !value * 65599 lxor Char.code character land max_int)
    name;
  Random.State.make [| !value |]

let () = Printf.printf "V2 scratch daemon property base seed: %d\n%!" base_seed

let identity of_bytes character =
  of_bytes (String.make 32 character) |> Result.get_ok

let repository_id = identity V2_model.Repository_id.of_bytes 'r'
let device_id = identity V2_model.Device_id.of_bytes 'd'
let encryption_key = Envelope.key_of_bytes (String.make 32 'e') |> Result.get_ok
let address_key = Address.key_of_bytes (String.make 32 'a') |> Result.get_ok

let signing_key =
  Mirage_crypto_ec.Ed25519.priv_of_octets
    (String.init 32 (fun index -> Char.chr (index + 1)))
  |> Result.get_ok

let capability =
  Bootstrap.make_capability ~encryption_key ~address_key ~signing_key
  |> Result.get_ok

let key_handle = identity Bootstrap.Key_handle.of_bytes 'h'

let bootstrap =
  Bootstrap.make ~repository_id ~device_id ~key_handle ~capability
    ~mandatory_features:0L
  |> Result.get_ok

let scheduler_config =
  Scheduler.make_config ~quiet_period:10L ~max_latency:30L |> Result.get_ok

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
  let root = Filename.temp_file "yeokcham-v2-scratch-daemon-property-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      match Store.init ~root with
      | Error _ -> false
      | Ok _ -> (
          match Bootstrap_store.initialize ~root bootstrap with
          | Error _ -> false
          | Ok _ -> (
              match Bootstrap_store.open_repository ~root ~capability with
              | Error _ -> false
              | Ok bootstrap_repository -> check root bootstrap_repository)))

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let nonce_source () =
  let next = ref 0 in
  fun () ->
    incr next;
    Envelope.nonce_of_bytes (String.make 12 (Char.chr !next))
    |> Result.map_error Envelope.error_to_string

let request path =
  { Watcher.reason = Watcher.Path_change; target = Watcher.Paths [ [ path ] ] }

let generated_unchanged_requests_never_publish_again =
  QCheck2.Test.make ~count:80
    ~name:"V2 daemon coalesces generated unchanged requests without publication"
    QCheck2.Gen.(list_size (int_range 0 30) (string_size (int_range 1 32)))
    (fun names ->
      with_repository (fun root bootstrap_repository ->
          write_file (Filename.concat root "work") "stable";
          let runner =
            Runner.create ~root ~bootstrap_repository ~config:scheduler_config
              ~nonce_source:(nonce_source ())
          in
          match Runner.observe runner ~at:0L (request "work") with
          | Error _ | Ok (Some _) -> false
          | Ok None -> (
              match Runner.advance runner ~at:10L with
              | Error _ | Ok None -> false
              | Ok (Some first) -> (
                  match first.Runner.publication with
                  | Runner.No_checkpoint -> false
                  | Runner.Published_checkpoint _ ->
                      List.mapi
                        (fun index name ->
                          let at = Int64.of_int ((index * 20) + 20) in
                          match Runner.observe runner ~at (request name) with
                          | Error _ | Ok (Some _) -> false
                          | Ok None -> (
                              match
                                Runner.advance runner ~at:Int64.(add at 10L)
                              with
                              | Ok (Some outcome) ->
                                  outcome.Runner.publication
                                  = Runner.No_checkpoint
                              | Error _ | Ok None -> false))
                        names
                      |> List.for_all Fun.id))))

let () =
  Alcotest.run "V2 scratch daemon properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "unchanged-requests")
            generated_unchanged_requests_never_publish_again;
        ] );
    ]
