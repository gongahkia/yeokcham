[@@@warning "-41-42"]

module Release = Yeokcham_release
module Store = Yeokcham_store

let fail render error =
  prerr_endline (render error);
  exit 2

let release_id value =
  match Yeokcham_id.Release_id.of_hex value with
  | Ok identity -> identity
  | Error error -> fail Yeokcham_id.parse_error_to_string error

let () =
  match Array.to_list Sys.argv with
  | [ _; "--root"; root; "--release"; release ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          match Release.Durable.read store (release_id release) with
          | Error error -> fail Release.error_to_string error
          | Ok release ->
              Release.release_evidence release
              |> List.iter (fun evidence ->
                  Printf.printf "release=%s evidence=%s object=%s\n"
                    (Yeokcham_id.Release_id.to_hex (Release.release_id release))
                    (Yeokcham_id.Validation_id.to_hex
                       evidence.Release.evidence_id)
                    (Store.Stored_object_id.to_hex
                       evidence.Release.evidence_object_id))))
  | _ ->
      prerr_endline
        "usage: release_evidence_v1 --root <absolute-root> --release \
         <release-id>";
      exit 2
