module Scratch = Yeokcham_scratch
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store

let fail render error =
  prerr_endline (render error);
  exit 2

let checkpoint_id value =
  match Store.Stored_object_id.of_hex value with
  | Ok identity -> Scratch.Checkpoint_id.of_stored_object_id identity
  | Error error -> fail Store.Stored_object_id.parse_error_to_string error

let () =
  match Array.to_list Sys.argv with
  | [ _; "--root"; root; "--checkpoint"; checkpoint ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          let scratch = Scratch.open_repository store in
          match
            Scratch.resolve_checkpoint scratch (checkpoint_id checkpoint)
          with
          | Error error -> fail Scratch.error_to_string error
          | Ok resolved ->
              Scratch.resolved_checkpoint resolved
              |> Scratch.Checkpoint.snapshot
              |> Snapshot.Snapshot.stored_object_id
              |> Store.Stored_object_id.to_hex |> print_endline))
  | _ ->
      prerr_endline
        "usage: workspace_base_v1 --root <absolute-root> --checkpoint \
         <checkpoint-id>";
      exit 2
