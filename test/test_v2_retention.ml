module Encoding = Yeokcham_encoding
module Ledger = Yeokcham_v2_ledger
module Golden = Yeokcham_testkit.Golden_fixture
module Object = Yeokcham_v2_object
module Retention = Yeokcham_v2_retention
module V2_model = Yeokcham_v2_model

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
let () = Printf.printf "v2 retention property base seed: %d\n%!" base_seed

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let opaque_ref value =
  V2_model.Opaque_object_ref.of_hex (Printf.sprintf "%064x" value)
  |> require_ok V2_model.identity_error_to_string

let event_id value =
  V2_model.Ref_event_id.of_hex (Printf.sprintf "%064x" value)
  |> require_ok V2_model.identity_error_to_string

let read_golden name =
  Golden.read_lower_hex_file (Filename.concat "golden" name)
  |> require_ok Fun.id

let checkpoint value =
  {
    Retention.event_id = event_id value;
    event_object_ref = opaque_ref (1000 + value);
    checkpoint_snapshot_ref = opaque_ref (2000 + value);
  }

let stored_sizes history =
  List.concat_map
    (fun (checkpoint : Retention.checkpoint) ->
      [
        {
          Retention.sized_object_ref = checkpoint.Retention.event_object_ref;
          stored_bytes = 10L;
        };
        {
          Retention.sized_object_ref =
            checkpoint.Retention.checkpoint_snapshot_ref;
          stored_bytes =
            Int64.of_int
              (20
              + Char.code
                  (Ledger.Event_id.to_hex checkpoint.Retention.event_id).[63]
                mod 17);
        };
      ])
    history

let ids planned =
  List.map
    (fun planned ->
      Ledger.Event_id.to_hex planned.Retention.checkpoint.Retention.event_id)
    planned

let selected_history policy claims history sizes =
  Retention.select ~policy ~claims ~history ~object_sizes:sizes
  |> require_ok Retention.error_to_string

let protection_and_current_survive_quota_pressure () =
  let oldest = checkpoint 1 in
  let middle = checkpoint 2 in
  let current = checkpoint 3 in
  let history = [ oldest; middle; current ] in
  let sizes =
    [
      {
        Retention.sized_object_ref = oldest.Retention.event_object_ref;
        stored_bytes = 10L;
      };
      {
        Retention.sized_object_ref = oldest.Retention.checkpoint_snapshot_ref;
        stored_bytes = 70L;
      };
      {
        Retention.sized_object_ref = middle.Retention.event_object_ref;
        stored_bytes = 10L;
      };
      {
        Retention.sized_object_ref = middle.Retention.checkpoint_snapshot_ref;
        stored_bytes = 30L;
      };
      {
        Retention.sized_object_ref = current.Retention.event_object_ref;
        stored_bytes = 10L;
      };
      {
        Retention.sized_object_ref = current.Retention.checkpoint_snapshot_ref;
        stored_bytes = 20L;
      };
    ]
  in
  let policy =
    Retention.make_policy ~recent_count:3 ~storage_budget_bytes:(Some 130L)
    |> require_ok Retention.error_to_string
  in
  let claims =
    [
      Retention.protection
        ~snapshot_ref:oldest.Retention.checkpoint_snapshot_ref
        ~action:Retention.Protect ~reason:Retention.User_pin;
    ]
  in
  let plan = selected_history policy claims history sizes in
  Alcotest.(check (list string))
    "pin and current stay retained"
    [
      Ledger.Event_id.to_hex oldest.Retention.event_id;
      Ledger.Event_id.to_hex current.Retention.event_id;
    ]
    (ids plan.Retention.retained);
  Alcotest.(check int)
    "one optional checkpoint excluded" 1
    (List.length plan.Retention.excluded);
  (match plan.Retention.excluded with
  | [ planned ] when planned.Retention.decision = Retention.Budget_excluded ->
      ()
  | _ -> Alcotest.fail "quota exclusion was not explicit");
  Alcotest.(check int64)
    "exact retained encrypted source bytes" 110L plan.Retention.retained_bytes;
  Alcotest.(check (option int64))
    "required set fits the quota" None plan.Retention.required_overrun

let protected_overrun_is_reported_without_eviction () =
  let oldest = checkpoint 10 in
  let current = checkpoint 11 in
  let history = [ oldest; current ] in
  let sizes =
    [
      {
        Retention.sized_object_ref = oldest.Retention.event_object_ref;
        stored_bytes = 10L;
      };
      {
        Retention.sized_object_ref = oldest.Retention.checkpoint_snapshot_ref;
        stored_bytes = 70L;
      };
      {
        Retention.sized_object_ref = current.Retention.event_object_ref;
        stored_bytes = 10L;
      };
      {
        Retention.sized_object_ref = current.Retention.checkpoint_snapshot_ref;
        stored_bytes = 20L;
      };
    ]
  in
  let policy =
    Retention.make_policy ~recent_count:0 ~storage_budget_bytes:(Some 100L)
    |> require_ok Retention.error_to_string
  in
  let claims =
    [
      Retention.protection
        ~snapshot_ref:oldest.Retention.checkpoint_snapshot_ref
        ~action:Retention.Protect ~reason:Retention.User_pin;
    ]
  in
  let plan = selected_history policy claims history sizes in
  Alcotest.(check (list string))
    "required states remain visible despite quota"
    [
      Ledger.Event_id.to_hex oldest.Retention.event_id;
      Ledger.Event_id.to_hex current.Retention.event_id;
    ]
    (ids plan.Retention.retained);
  Alcotest.(check (option int64))
    "exact overrun" (Some 10L) plan.Retention.required_overrun

let claims_fold_in_causal_order () =
  let oldest = checkpoint 20 in
  let current = checkpoint 21 in
  let history = [ oldest; current ] in
  let policy =
    Retention.make_policy ~recent_count:1 ~storage_budget_bytes:None
    |> require_ok Retention.error_to_string
  in
  let claims =
    [
      Retention.protection
        ~snapshot_ref:oldest.Retention.checkpoint_snapshot_ref
        ~action:Retention.Protect ~reason:Retention.User_pin;
      Retention.protection
        ~snapshot_ref:oldest.Retention.checkpoint_snapshot_ref
        ~action:Retention.Unprotect ~reason:Retention.User_pin;
    ]
  in
  let plan = selected_history policy claims history (stored_sizes history) in
  Alcotest.(check (list string))
    "latest claim controls its exact snapshot"
    [ Ledger.Event_id.to_hex current.Retention.event_id ]
    (ids plan.Retention.retained)

let cleanup_candidates_preserve_retained_and_external_snapshots () =
  let oldest = checkpoint 30 in
  let middle = checkpoint 31 in
  let current = checkpoint 32 in
  let history = [ oldest; middle; current ] in
  let candidates =
    Retention.cleanup_candidates ~history ~retained:[ oldest; current ]
      ~externally_referenced:[ middle.Retention.checkpoint_snapshot_ref ]
    |> require_ok Retention.error_to_string
  in
  Alcotest.(check int)
    "only source ledger objects need cleanup" 3 (List.length candidates);
  Alcotest.(check bool)
    "all cleanup entries are retired ledger objects" true
    (List.for_all
       (fun candidate ->
         candidate.Retention.candidate_kind = Retention.Ledger_event)
       candidates);
  let candidates =
    Retention.cleanup_candidates ~history ~retained:[ oldest; current ]
      ~externally_referenced:[]
    |> require_ok Retention.error_to_string
  in
  Alcotest.(check int)
    "unretained unreferenced snapshot becomes a candidate" 4
    (List.length candidates);
  Alcotest.(check bool)
    "candidate includes the discarded snapshot" true
    (List.exists
       (fun candidate ->
         V2_model.Opaque_object_ref.equal
           candidate.Retention.candidate_object_ref
           middle.Retention.checkpoint_snapshot_ref
         && candidate.Retention.candidate_kind = Retention.Scratch_snapshot)
       candidates)

let canonical_records_reject_invalid_generation_shapes () =
  let active_ref =
    Ledger.Ref_name.of_string "scratch-compact-device-head" |> require_ok Fun.id
  in
  let retired_ref =
    Ledger.Ref_name.of_string "scratch-device" |> require_ok Fun.id
  in
  let candidate =
    {
      Retention.candidate_object_ref = opaque_ref 333;
      candidate_kind = Retention.Ledger_event;
    }
  in
  let generation =
    Retention.make_generation ~active_ref ~active_head:(event_id 334)
      ~retired_refs:[ retired_ref ] ~cleanup_candidates:[ candidate ]
    |> require_ok Retention.error_to_string
  in
  let decoded =
    Retention.decode_generation (Retention.encode_generation generation)
    |> require_ok Retention.error_to_string
  in
  Alcotest.(check string)
    "generation codec re-encodes identically"
    (Retention.encode_generation generation)
    (Retention.encode_generation decoded);
  let duplicate_retired_ref =
   (function
   | Retention.Duplicate_retired_ref _ -> true
   | _ -> false)
   [@warning "-4"]
  in
  (match
     Retention.make_generation ~active_ref ~active_head:(event_id 335)
       ~retired_refs:[ retired_ref; retired_ref ]
       ~cleanup_candidates:[]
   with
  | Error error when duplicate_retired_ref error -> ()
  | Error error ->
      Alcotest.failf "wrong generation validation error: %s"
        (Retention.error_to_string error)
  | Ok _ -> Alcotest.fail "duplicate retired ref was accepted");
  let later_retired_ref =
    Ledger.Ref_name.of_string "scratch-z" |> require_ok Fun.id
  in
  let later_candidate =
    {
      Retention.candidate_object_ref = opaque_ref 337;
      candidate_kind = Retention.Ledger_event;
    }
  in
  let noncanonical_generation =
    let array values =
      Encoding.array values |> require_ok Encoding.construction_error_to_string
    in
    array
      [
        Encoding.integer 1L;
        Encoding.text (Ledger.Ref_name.to_string active_ref)
        |> require_ok Encoding.construction_error_to_string;
        Encoding.bytes (Ledger.Event_id.to_bytes (event_id 336));
        array
          [
            Encoding.text (Ledger.Ref_name.to_string later_retired_ref)
            |> require_ok Encoding.construction_error_to_string;
            Encoding.text (Ledger.Ref_name.to_string retired_ref)
            |> require_ok Encoding.construction_error_to_string;
          ];
        array
          [
            array
              [
                Encoding.bytes
                  (V2_model.Opaque_object_ref.to_bytes
                     later_candidate.Retention.candidate_object_ref);
                Encoding.integer 0L;
              ];
            array
              [
                Encoding.bytes
                  (V2_model.Opaque_object_ref.to_bytes
                     candidate.Retention.candidate_object_ref);
                Encoding.integer 0L;
              ];
          ];
        Encoding.integer 0L;
      ]
    |> Encoding.encode
  in
  match Retention.decode_generation noncanonical_generation with
  | Error error ->
      Alcotest.(check string)
        "noncanonical generation ordering rejects"
        "invalid V2 retention record: noncanonical V2 scratch generation"
        (Retention.error_to_string error)
  | Ok _ -> Alcotest.fail "noncanonical generation ordering was accepted"

let canonical_records_match_goldens () =
  let protection =
    Retention.protection ~snapshot_ref:(opaque_ref 400)
      ~action:Retention.Protect ~reason:Retention.User_pin
  in
  let generation =
    Retention.make_generation
      ~active_ref:
        (Ledger.Ref_name.of_string "scratch-compact-device-head"
        |> require_ok Fun.id)
      ~active_head:(event_id 401)
      ~retired_refs:
        [ Ledger.Ref_name.of_string "scratch-device" |> require_ok Fun.id ]
      ~cleanup_candidates:
        [
          {
            Retention.candidate_object_ref = opaque_ref 402;
            candidate_kind = Retention.Ledger_event;
          };
        ]
    |> require_ok Retention.error_to_string
  in
  Alcotest.(check string)
    "protection payload golden"
    (read_golden "v2-scratch-protection-v1.cbor.hex")
    (Retention.encode_protection protection);
  Alcotest.(check string)
    "generation payload golden"
    (read_golden "v2-scratch-generation-v1.cbor.hex")
    (Retention.encode_generation generation);
  Alcotest.(check string)
    "protection frame golden"
    (read_golden "v2-object-scratch-protection-frame-v1.cbor.hex")
    (Object.scratch_protection protection |> Object.encode);
  Alcotest.(check string)
    "generation frame golden"
    (read_golden "v2-object-scratch-generation-frame-v1.cbor.hex")
    (Object.scratch_generation generation |> Object.encode)

let size_order_does_not_change_selection =
  QCheck2.Test.make ~count:160
    ~name:"V2 ordinal retention selection ignores object-size input order"
    QCheck2.Gen.(int_range 1 24)
    (fun count ->
      let history = List.init count (fun index -> checkpoint (500 + index)) in
      let policy =
        Retention.make_policy ~recent_count:(count / 2)
          ~storage_budget_bytes:None
        |> require_ok Retention.error_to_string
      in
      let claims =
        [
          Retention.protection
            ~snapshot_ref:(List.hd history).Retention.checkpoint_snapshot_ref
            ~action:Retention.Protect ~reason:Retention.User_pin;
        ]
      in
      let sizes = stored_sizes history in
      let forward = selected_history policy claims history sizes in
      let reverse = selected_history policy claims history (List.rev sizes) in
      ids forward.Retention.retained = ids reverse.Retention.retained
      && ids forward.Retention.excluded = ids reverse.Retention.excluded
      && Int64.equal forward.Retention.retained_bytes
           reverse.Retention.retained_bytes)

let () =
  Alcotest.run "V2 scratch retention"
    [
      ( "unit",
        [
          Alcotest.test_case "protection and current survive quota pressure"
            `Quick protection_and_current_survive_quota_pressure;
          Alcotest.test_case "protected overrun remains explicit" `Quick
            protected_overrun_is_reported_without_eviction;
          Alcotest.test_case "claims fold in causal order" `Quick
            claims_fold_in_causal_order;
          Alcotest.test_case "cleanup candidates preserve live snapshots" `Quick
            cleanup_candidates_preserve_retained_and_external_snapshots;
          Alcotest.test_case
            "canonical records reject invalid generation shapes" `Quick
            canonical_records_reject_invalid_generation_shapes;
          Alcotest.test_case "canonical records match goldens" `Quick
            canonical_records_match_goldens;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "size-order-selection")
            size_order_does_not_change_selection;
        ] );
    ]
