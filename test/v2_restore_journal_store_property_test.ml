module Journal = Yeokcham_v2_restore_journal
module Journal_store = Yeokcham_v2_restore_journal_store
module Ledger = Yeokcham_v2_ledger
module Model = Yeokcham_v2_model
module Store = Yeokcham_store

let default_seed = 20_260_809

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

let () =
  Printf.printf "V2 restore-journal store property base seed: %d\n%!" base_seed

let identity of_bytes character =
  of_bytes (String.make 32 character) |> Result.get_ok

let repository_id = identity Model.Repository_id.of_bytes 'r'
let operation_id = identity Model.Transaction_id.of_bytes 'o'

let prepared action_count =
  Journal.make_prepared ~repository_id ~operation_id
    ~safety_event_id:(identity Ledger.Event_id.of_bytes 'e')
    ~target_event_id:(identity Ledger.Event_id.of_bytes 't')
    ~safety_snapshot:(identity Model.Opaque_object_ref.of_bytes 's')
    ~target_snapshot:(identity Model.Opaque_object_ref.of_bytes 't')
    ~action_count ~mandatory_features:0L

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

let with_v2_repository run =
  let root = Filename.temp_file "yeokcham-v2-restore-journal-property-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      match Store.init ~root with
      | Error _ -> false
      | Ok _ -> (
          match Journal_store.open_repository ~root ~repository_id with
          | Error _ -> false
          | Ok repository -> run repository))

let complete repository initial action_count =
  let append record = Result.is_ok (Journal_store.append repository record) in
  let rec append_actions record next_completed =
    if next_completed > action_count then
      match Journal.advance record Journal.Materialized with
      | Error _ -> false
      | Ok materialized -> (
          match Journal.advance materialized Journal.Published with
          | Error _ -> false
          | Ok published -> append materialized && append published)
    else
      match Journal.advance record (Journal.Applying next_completed) with
      | Error _ -> false
      | Ok next -> append next && append_actions next (next_completed + 1)
  in
  match Journal.advance initial (Journal.Applying 0) with
  | Error _ -> false
  | Ok started -> append initial && append started && append_actions started 1

let generated_durable_chains_reopen_exactly =
  QCheck2.Test.make ~count:80
    ~name:"V2 restore journal durable generated chains reopen exactly"
    QCheck2.Gen.(int_range 1 20)
    (fun action_count ->
      with_v2_repository (fun repository ->
          match prepared action_count with
          | Error _ -> false
          | Ok initial ->
              if complete repository initial action_count then
                match Journal_store.scan repository with
                | Error _ -> false
                | Ok records -> (
                    List.length records = action_count + 4
                    &&
                    match List.rev records with
                    | latest :: _ ->
                        Journal.generation latest
                        = Int64.of_int (action_count + 3)
                        && Journal.phase latest = Journal.Published
                    | [] -> false)
              else false))

let () =
  Alcotest.run "V2 durable restore journal storage properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "durable-generated-chains")
            generated_durable_chains_reopen_exactly;
        ] );
    ]
