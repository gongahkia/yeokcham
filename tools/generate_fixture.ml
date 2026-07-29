let seed = ref 0
let destination = ref None

let set_destination value =
  match !destination with
  | None -> destination := Some value
  | Some _ -> raise (Arg.Bad "exactly one destination is required")

let options =
  [ ("--seed", Arg.Set_int seed, "SEED deterministic fixture seed") ]

let usage = "generate_fixture [--seed SEED] DESTINATION"

let () =
  Arg.parse options set_destination usage;
  match !destination with
  | None ->
      Arg.usage options usage;
      exit 2
  | Some destination -> (
      let fixture = Paengi_testkit.Fixture_spec.generate ~seed:!seed in
      match Paengi_testkit.Fixture_materializer.write ~destination fixture with
      | Error message ->
          prerr_endline message;
          exit 1
      | Ok () ->
          Printf.printf "generated %d entries at %s\n"
            (Paengi_testkit.Fixture_spec.entry_count fixture)
            destination)
