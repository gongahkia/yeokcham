module Health = Yeokcham_v4_health

let identifier value =
  let digit = "abcdef".[value mod 6] in
  String.make 64 digit

let observations =
  QCheck2.Gen.(list_size (int_range 0 6) (int_range 0 3))
  |> QCheck2.Gen.map (fun states ->
      states
      |> List.mapi (fun identifier_seed state ->
          let status =
            match state with
            | 0 -> Health.Present
            | 1 -> Health.Missing
            | 2 -> Health.Malformed
            | _ -> Health.Id_mismatch (identifier (identifier_seed + 1))
          in
          Health.Object_observation
            { object_id = identifier identifier_seed; status; references = [] }))

let diagnosis_is_stable_under_observation_order =
  QCheck2.Test.make ~count:300
    ~name:
      "V4 health diagnosis is canonical and independent of observation order"
    observations (fun observations ->
      Health.verify observations = Health.verify (List.rev observations))

let () =
  Alcotest.run "V4 health properties"
    [
      ( "health",
        [
          QCheck_alcotest.to_alcotest
            diagnosis_is_stable_under_observation_order;
        ] );
    ]
