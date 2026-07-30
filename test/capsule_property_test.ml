module Capsule = Paengi_capsule
module Id = Paengi_id
module Scratch = Paengi_scratch
module Snapshot = Paengi_snapshot
module Store = Paengi_store

let default_seed = 20_260_730

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed
  | None -> default_seed

let stable_seed name =
  let value = ref base_seed in
  String.iter
    (fun character ->
      value := !value * 65599 lxor Char.code character land max_int)
    name;
  !value

let () = Printf.printf "capsule property base seed: %d\n%!" base_seed
let state_for name = Random.State.make [| stable_seed name |]

let raw_id seed =
  Bytes.init 32 (fun index -> Char.chr ((seed + index) land 0xff))
  |> Bytes.unsafe_to_string

let stored_id seed =
  Store.Stored_object_id.of_raw_bytes (raw_id seed) |> Option.get

let content_id seed = Snapshot.Content.of_stored_object_id (stored_id seed)
let snapshot_id seed = Snapshot.Snapshot.of_stored_object_id (stored_id seed)
let capsule_id seed = Id.Capsule_id.of_bytes (raw_id seed) |> Result.get_ok

let revision_id seed =
  Id.Capsule_revision_id.of_bytes (raw_id seed) |> Result.get_ok

let capsule =
  Capsule.create ~id:(capsule_id 1) ~title:"generated"
    ~description:"generated exact transitions" ~dependencies:[]
  |> Result.get_ok

let exact_creations_reach_the_generated_state =
  QCheck2.Test.make ~count:100
    ~name:"exact capsule creations reproduce their generated state"
    QCheck2.Gen.(list_size (int_range 0 24) (pair (int_range 0 255) bool))
    (fun values ->
      let entries, operations =
        List.mapi
          (fun index (seed, executable) ->
            let entry =
              Scratch.File
                {
                  mode =
                    (if executable then Snapshot.Executable
                     else Snapshot.Regular);
                  content = content_id (seed + index + 10);
                }
            in
            let path = [ Printf.sprintf "file-%02d" index ] in
            ( (path, entry),
              Capsule.Exact_file_transition
                {
                  Capsule.transition_path = path;
                  expected_entry = None;
                  replacement_entry = Some entry;
                } ))
          values
        |> List.split
      in
      let expected = Scratch.State.create entries |> Result.get_ok in
      let revision =
        Capsule.create_revision ~id:(revision_id 2) ~capsule ~parent:None
          ~declared_base:(snapshot_id 3) ~operations ~expected_result:None
          ~evidence:[] ~created_at:0L
        |> Result.get_ok
      in
      let initial = Scratch.State.create [] |> Result.get_ok in
      let applied =
        Capsule.apply ~actual_base:(snapshot_id 3) ~state:initial revision
      in
      Scratch.State.equal expected applied.Capsule.state
      && applied.Capsule.conflicts = []
      && List.length applied.Capsule.outcomes = List.length operations)

let derived_transitions_replay_between_generated_states =
  QCheck2.Test.make ~count:100
    ~name:"derived exact transitions replay between generated states"
    QCheck2.Gen.(list_size (int_range 0 20) (pair (int_range 0 255) bool))
    (fun values ->
      let from_entries, target_entries =
        List.mapi
          (fun index (seed, executable) ->
            let path = [ Printf.sprintf "file-%02d" index ] in
            let mode =
              if executable then Snapshot.Executable else Snapshot.Regular
            in
            ( (path, Scratch.File { mode; content = content_id (seed + 40) }),
              ( path,
                Scratch.File
                  {
                    mode =
                      (if executable then Snapshot.Regular
                       else Snapshot.Executable);
                    content = content_id (seed + 140);
                  } ) ))
          values
        |> List.split
      in
      let from = Scratch.State.create from_entries |> Result.get_ok in
      let target = Scratch.State.create target_entries |> Result.get_ok in
      let operations =
        Capsule.Draft.operations_between ~from ~to_:target |> Result.get_ok
      in
      let revision =
        Capsule.create_revision ~id:(revision_id 4) ~capsule ~parent:None
          ~declared_base:(snapshot_id 5) ~operations ~expected_result:None
          ~evidence:[] ~created_at:0L
        |> Result.get_ok
      in
      let applied =
        Capsule.apply ~actual_base:(snapshot_id 5) ~state:from revision
      in
      Scratch.State.equal target applied.Capsule.state
      && applied.Capsule.conflicts = [])

let catalog_history_is_newest_to_oldest =
  QCheck2.Test.make ~count:100
    ~name:"immutable revision catalog retains newest-to-oldest history"
    QCheck2.Gen.(int_range 1 16)
    (fun count ->
      let catalog =
        Capsule.Catalog.add_capsule Capsule.Catalog.empty capsule
        |> Result.get_ok
      in
      let catalog, ids =
        List.init count Fun.id
        |> List.fold_left
             (fun (catalog, reversed_ids) index ->
               let identity = revision_id (index + 10) in
               let parent =
                 match reversed_ids with
                 | [] -> None
                 | identity :: _ -> Some identity
               in
               let revision =
                 Capsule.create_revision ~id:identity ~capsule ~parent
                   ~declared_base:(snapshot_id 6) ~operations:[]
                   ~expected_result:None ~evidence:[]
                   ~created_at:(Int64.of_int index)
                 |> Result.get_ok
               in
               ( Capsule.Catalog.add_revision catalog revision |> Result.get_ok,
                 identity :: reversed_ids ))
             (catalog, [])
      in
      let history =
        Capsule.Catalog.history catalog (Capsule.id capsule) |> Result.get_ok
      in
      List.length history = count
      && List.for_all2
           (fun expected revision ->
             Id.Capsule_revision_id.equal expected
               (Capsule.revision_id revision))
           ids history)

let () =
  Alcotest.run "capsule properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "exact-creations")
            exact_creations_reach_the_generated_state;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "derived-transitions")
            derived_transitions_replay_between_generated_states;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "catalog-history")
            catalog_history_is_newest_to_oldest;
        ] );
    ]
