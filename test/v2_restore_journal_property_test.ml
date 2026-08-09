module Journal = Yeokcham_v2_restore_journal
module Ledger = Yeokcham_v2_ledger
module Model = Yeokcham_v2_model

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
let () = Printf.printf "V2 restore-journal property base seed: %d\n%!" base_seed

let identity of_bytes character =
  of_bytes (String.make 32 character) |> Result.get_ok

let make action_count =
  Journal.make_prepared
    ~repository_id:(identity Model.Repository_id.of_bytes 'r')
    ~operation_id:(identity Model.Transaction_id.of_bytes 'o')
    ~safety_event_id:(identity Ledger.Event_id.of_bytes 'e')
    ~target_event_id:(identity Ledger.Event_id.of_bytes 't')
    ~safety_snapshot:(identity Model.Opaque_object_ref.of_bytes 's')
    ~target_snapshot:(identity Model.Opaque_object_ref.of_bytes 't')
    ~action_count ~mandatory_features:0L

let generated_journal_traces_are_canonical =
  QCheck2.Test.make ~count:180
    ~name:"V2 restore journal generated traces are canonical and complete"
    QCheck2.Gen.(int_range 1 64)
    (fun action_count ->
      let rec complete record next_completed =
        if next_completed > action_count then
          Result.bind (Journal.advance record Journal.Materialized)
            (fun materialized -> Journal.advance materialized Journal.Published)
        else
          Result.bind (Journal.advance record (Journal.Applying next_completed))
            (fun record -> complete record (next_completed + 1))
      in
      match make action_count with
      | Error _ -> false
      | Ok prepared -> (
          match Journal.advance prepared (Journal.Applying 0) with
          | Error _ -> false
          | Ok started -> (
              match complete started 1 with
              | Error _ -> false
              | Ok published -> (
                  match Journal.decode (Journal.encode published) with
                  | Error _ -> false
                  | Ok decoded ->
                      Journal.generation decoded
                      = Int64.of_int (action_count + 3)
                      && Journal.phase decoded = Journal.Published
                      && Journal.completed_actions decoded = action_count))))

let () =
  Alcotest.run "V2 opaque restore journal properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "generated-journal-traces")
            generated_journal_traces_are_canonical;
        ] );
    ]
