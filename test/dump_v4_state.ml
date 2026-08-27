let () =
  let project =
    Yeokcham_v4_model.init
      ~creator:
        (Yeokcham_v4_model.Device_id.of_string "device-alice" |> Result.get_ok)
      ~initial_snapshot:
        (Yeokcham_v4_model.Snapshot_id.of_string "snapshot-base" |> Result.get_ok)
      ~initial_draft:
        (Yeokcham_v4_model.Draft_id.of_string "draft-one" |> Result.get_ok)
      ~title:"fixture"
  in
  match Yeokcham_v4_record.encode_project project with
  | Error error ->
      prerr_endline (Yeokcham_v4_record.error_to_string error);
      exit 1
  | Ok bytes ->
      String.iter
        (fun character -> Printf.printf "%02x" (Char.code character))
        bytes;
      print_char '\n'
