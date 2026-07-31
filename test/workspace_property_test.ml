module Id = Paengi_id
module Workspace = Paengi_workspace

let default_seed = 20_260_801

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

let () = Printf.printf "workspace property base seed: %d\n%!" base_seed
let state_for name = Random.State.make [| stable_seed name |]

let raw_id seed =
  Bytes.init 32 (fun index -> Char.chr ((seed + index) land 0xff))
  |> Bytes.unsafe_to_string

let capsule_id seed = Id.Capsule_id.of_bytes (raw_id seed) |> Result.get_ok

let revision_id seed =
  Id.Capsule_revision_id.of_bytes (raw_id seed) |> Result.get_ok

let deterministic_tie_break_ignores_selection_permutations =
  QCheck2.Test.make ~count:100
    ~name:
      "workspace order uses revision-ID tie-break independent of selection \
       permutation"
    QCheck2.Gen.(list_size (int_range 0 24) (int_range 0 1_000))
    (fun ranks ->
      let selected =
        ranks
        |> List.mapi (fun index rank ->
            ( rank,
              Workspace.
                {
                  capsule = capsule_id (index + 1);
                  revision = revision_id (index + 1);
                  dependencies = [];
                } ))
        |> List.sort (fun (left, _) (right, _) -> Int.compare left right)
        |> List.map snd
      in
      match Workspace.derive_order ~selected ~explicit_order:None with
      | Error _ -> false
      | Ok order ->
          let actual =
            Workspace.revisions order
            |> List.map (fun selection -> selection.Workspace.revision)
          in
          let expected =
            List.init (List.length ranks) (fun index -> revision_id (index + 1))
          in
          List.for_all2 Id.Capsule_revision_id.equal actual expected)

let () =
  Alcotest.run "workspace properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "deterministic-tie-break")
            deterministic_tie_break_ignores_selection_permutations;
        ] );
    ]
