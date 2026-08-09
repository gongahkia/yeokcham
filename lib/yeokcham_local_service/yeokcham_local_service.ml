module Cutover = Yeokcham_cutover
module Store = Yeokcham_store

type root_availability =
  | V2_ready
  | Uninitialized
  | Legacy
  | Mixed_or_unknown of string
  | Incomplete of string

type error =
  | Cutover_error of Cutover.error
  | Store_error of Store.error
  | Root_unavailable of root_availability

type init_outcome =
  | Initialized
  | Already_initialized
  | Init_refused of root_availability

type archive_outcome = {
  archive_path : string;
  manifest_path : string;
  already_archived : bool;
}

type reset_outcome = Reset | Already_reset

let ( let* ) = Result.bind

let root_availability_to_string = function
  | V2_ready -> "V2 repository is ready"
  | Uninitialized -> "repository is not initialized; run init first"
  | Legacy ->
      "legacy repository detected; archive it explicitly before V2 use with \
       `yeokcham archive --name <archive-name>`"
  | Mixed_or_unknown detail ->
      "repository is mixed or unknown and was not opened: " ^ detail
  | Incomplete detail ->
      "repository is incomplete and was not opened: " ^ detail

let error_to_string = function
  | Cutover_error error -> Cutover.error_to_string error
  | Store_error error -> Store.error_to_string error
  | Root_unavailable availability -> root_availability_to_string availability

let availability_of_classification = function
  | Cutover.V2 -> V2_ready
  | Cutover.Empty -> Uninitialized
  | Cutover.Legacy -> Legacy
  | Cutover.Mixed_or_unknown detail -> Mixed_or_unknown detail
  | Cutover.Incomplete detail -> Incomplete detail

let classify ~root =
  Cutover.detect ~root
  |> Result.map availability_of_classification
  |> Result.map_error (fun error -> Cutover_error error)

let require_v2 ~root =
  let* availability = classify ~root in
  match availability with
  | V2_ready -> Ok ()
  | (Uninitialized | Legacy | Mixed_or_unknown _ | Incomplete _) as unavailable
    ->
      Error (Root_unavailable unavailable)

let initialize ~root =
  let* availability = classify ~root in
  match availability with
  | Uninitialized ->
      Store.init ~root
      |> Result.map (fun _ -> Initialized)
      |> Result.map_error (fun error -> Store_error error)
  | V2_ready ->
      Store.init ~root
      |> Result.map (fun _ -> Already_initialized)
      |> Result.map_error (fun error -> Store_error error)
  | (Legacy | Mixed_or_unknown _ | Incomplete _) as refused ->
      Ok (Init_refused refused)

let archive ~root ~archive_name =
  Cutover.archive ~root ~archive_name
  |> Result.map_error (fun error -> Cutover_error error)
  |> Result.map (function
    | Cutover.Archived result ->
        {
          archive_path = result.Cutover.archive_path;
          manifest_path = result.Cutover.manifest_path;
          already_archived = false;
        }
    | Cutover.Already_archived result ->
        {
          archive_path = result.Cutover.archive_path;
          manifest_path = result.Cutover.manifest_path;
          already_archived = true;
        })

let reset ~root ~archive_name ~confirm =
  Cutover.reset ~root ~archive_name ~confirm
  |> Result.map_error (fun error -> Cutover_error error)
  |> Result.map (function
    | Cutover.Reset -> Reset
    | Cutover.Already_reset -> Already_reset)
