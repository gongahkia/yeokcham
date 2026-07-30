module Capsule = Paengi_capsule
module Id = Paengi_id
module Scratch = Paengi_scratch
module Snapshot = Paengi_snapshot
module Store = Paengi_store

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let raw_id seed =
  Bytes.init 32 (fun index -> Char.chr ((seed + index) land 0xff))
  |> Bytes.unsafe_to_string

let stored_id seed = Store.Stored_object_id.of_raw_bytes (raw_id seed) |> Option.get

let capsule_id seed =
  Id.Capsule_id.of_bytes (raw_id seed) |> require_ok Id.parse_error_to_string

let revision_id seed =
  Id.Capsule_revision_id.of_bytes (raw_id seed)
  |> require_ok Id.parse_error_to_string

let snapshot_id seed =
  Snapshot.Snapshot.of_stored_object_id (stored_id seed)

let content_id seed = Snapshot.Content.of_stored_object_id (stored_id seed)

let file mode content = Scratch.File { mode; content }

let capsule () =
  Capsule.create ~id:(capsule_id 1) ~title:"exact files"
    ~description:"preserves stored content IDs"
    ~dependencies:
      [
        Capsule.Requires_capsule
          { capsule = capsule_id 2; revision = Some (revision_id 3) };
        Capsule.Ordered_after (capsule_id 4);
      ]
  |> require_ok Capsule.construction_error_to_string

let revision ~operations =
  Capsule.create_revision ~id:(revision_id 5) ~capsule:(capsule ()) ~parent:None
    ~declared_base:(snapshot_id 6) ~operations ~expected_result:(Some (snapshot_id 7))
    ~evidence:
      [
        {
          Capsule.command = [ "dune"; "runtest" ];
          environment_fingerprint = Some "test-host";
          snapshot = snapshot_id 7;
          status = Capsule.Passed;
          stdout_digest = Some (content_id 8);
          stderr_digest = None;
          started_at = 10L;
          duration_ms = 11L;
        };
      ]
    ~created_at:12L
  |> require_ok Capsule.construction_error_to_string

let revision_applies_exact_transitions () =
  let first = file Snapshot.Regular (content_id 20) in
  let second = file Snapshot.Regular (content_id 21) in
  let executable = file Snapshot.Executable (content_id 21) in
  let third = file Snapshot.Regular (content_id 22) in
  let state =
    Scratch.State.create [ ([ "src" ], Scratch.Directory); ([ "src"; "a" ], first) ]
    |> require_ok Scratch.error_to_string
  in
  let target =
    Scratch.State.create
      [
        ([ "src" ], Scratch.Directory);
        ([ "src"; "b" ], executable);
        ([ "src"; "c" ], third);
      ]
    |> require_ok Scratch.error_to_string
  in
  let applied =
    Capsule.apply ~actual_base:(snapshot_id 6) ~state
      (revision
         ~operations:
           [
             Capsule.Exact_file_transition
               {
                 Capsule.transition_path = [ "src"; "a" ];
                 expected_entry = Some first;
                 replacement_entry = Some second;
               };
             Capsule.Mode_change
               {
                 path = [ "src"; "a" ];
                 expected = Snapshot.Regular;
                 replacement = Snapshot.Executable;
               };
             Capsule.Move
               {
                 source = [ "src"; "a" ];
                 destination = [ "src"; "b" ];
                 prior = executable;
               };
             Capsule.Exact_file_transition
               {
                 Capsule.transition_path = [ "src"; "c" ];
                 expected_entry = None;
                 replacement_entry = Some third;
               };
           ])
  in
  Alcotest.(check bool) "exact transitions reach expected state" true
    (Scratch.State.equal target applied.Capsule.state);
  Alcotest.(check int) "all operations apply exactly" 4
    (List.length applied.Capsule.outcomes);
  Alcotest.(check int) "exact application has no conflicts" 0
    (List.length applied.Capsule.conflicts)

let declared_base_mismatch_is_a_value () =
  let state = Scratch.State.create [] |> require_ok Scratch.error_to_string in
  let applied =
    Capsule.apply ~actual_base:(snapshot_id 9) ~state (revision ~operations:[])
  in
  Alcotest.(check bool) "state is unchanged" true
    (Scratch.State.equal state applied.Capsule.state);
  if
    not
      (List.exists
         (function Capsule.Declared_base_mismatch _ -> true | _ -> false)
         applied.Capsule.conflicts)
  then Alcotest.fail "base mismatch was not returned as an application conflict"

let text_edit_requires_explicit_exact_fallback () =
  let before = file Snapshot.Regular (content_id 30) in
  let after = file Snapshot.Regular (content_id 31) in
  let state =
    Scratch.State.create [ ([ "file" ], before) ]
    |> require_ok Scratch.error_to_string
  in
  let edit =
    {
      Capsule.edit_path = [ "file" ];
      anchor =
        {
          Capsule.before_context = "before";
          selected = "selected";
          after_context = "after";
        };
      replacement = "replacement";
      fallback_transition =
        {
          Capsule.transition_path = [ "file" ];
          expected_entry = Some before;
          replacement_entry = Some after;
        };
    }
  in
  let applied =
    Capsule.apply ~actual_base:(snapshot_id 6) ~state
      (revision ~operations:[ Capsule.Text_edit edit ])
  in
  Alcotest.(check bool) "text edit does not silently apply" true
    (Scratch.State.equal state applied.Capsule.state);
  if
    not
      (List.exists
         (function
           | Capsule.Text_fallback_required { edit = actual; _ } ->
               actual.Capsule.edit_path = [ "file" ]
           | _ -> false)
         applied.Capsule.conflicts)
  then Alcotest.fail "text fallback was not explicit";
  let fallback =
    Capsule.apply_text_fallback state edit
    |> require_ok Fun.id
  in
  let expected =
    Scratch.State.create [ ([ "file" ], after) ]
    |> require_ok Scratch.error_to_string
  in
  Alcotest.(check bool) "selected fallback is exact" true
    (Scratch.State.equal expected fallback)

let capsule_and_revision_metadata_are_immutable_values () =
  let capsule = capsule () in
  let revision = revision ~operations:[] in
  Alcotest.(check bool) "stable capsule ID is preserved" true
    (Id.Capsule_id.equal (capsule_id 1) (Capsule.id capsule));
  Alcotest.(check string) "title is preserved" "exact files" (Capsule.title capsule);
  Alcotest.(check int) "dependencies are preserved" 2
    (List.length (Capsule.dependencies capsule));
  Alcotest.(check bool) "revision keeps capsule identity" true
    (Id.Capsule_id.equal (Capsule.id capsule) (Capsule.revision_capsule revision));
  Alcotest.(check bool) "revision ID is preserved" true
    (Id.Capsule_revision_id.equal (revision_id 5) (Capsule.revision_id revision));
  Alcotest.(check int) "evidence is preserved" 1
    (List.length (Capsule.revision_evidence revision))

let construction_rejects_nonpersistable_identities () =
  let short = Id.Capsule_id.of_bytes "short" |> Result.get_ok in
  let short_error =
    Capsule.create ~id:short ~title:"title" ~description:"description"
      ~dependencies:[]
  in
  if
    not
      (match short_error with
      | Error (Capsule.Invalid_capsule_id_length 5) -> true
      | Error _ | Ok _ -> false)
  then Alcotest.fail "short capsule ID was accepted";
  let empty_title =
    Capsule.create ~id:(capsule_id 40) ~title:"" ~description:"description"
      ~dependencies:[]
  in
  if
    not
      (match empty_title with
      | Error Capsule.Empty_title -> true
      | Error _ | Ok _ -> false)
  then Alcotest.fail "empty title was accepted"

let () =
  Alcotest.run "capsule core"
    [
      ( "unit",
        [
          Alcotest.test_case "revision applies exact transitions" `Quick
            revision_applies_exact_transitions;
          Alcotest.test_case "declared base mismatch is a value" `Quick
            declared_base_mismatch_is_a_value;
          Alcotest.test_case "text fallback remains explicit" `Quick
            text_edit_requires_explicit_exact_fallback;
          Alcotest.test_case "capsule and revision metadata are immutable values"
            `Quick capsule_and_revision_metadata_are_immutable_values;
          Alcotest.test_case "construction rejects nonpersistable identities"
            `Quick construction_rejects_nonpersistable_identities;
        ] );
    ]
