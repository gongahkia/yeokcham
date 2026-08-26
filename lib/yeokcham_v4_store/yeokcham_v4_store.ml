module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Model = Yeokcham_v4_model
module Record = Yeokcham_v4_record
module Store = Yeokcham_store

type error =
  | Store_error of Store.error
  | Record_error of Record.error
  | Envelope_error of Envelope.creation_error
  | Existing_repository of string
  | Bootstrap_error of string
  | Missing_state_head
  | Empty_state_head
  | Unexpected_object_type of Envelope.object_type

let error_to_string = function
  | Store_error error -> Store.error_to_string error
  | Record_error error -> Record.error_to_string error
  | Envelope_error error -> Envelope.creation_error_to_string error
  | Existing_repository path ->
      "refusing to initialize V4 over an existing repository: " ^ path
  | Bootstrap_error detail -> "V4 initialization bootstrap failed: " ^ detail
  | Missing_state_head -> "V4 repository has no project-state head"
  | Empty_state_head -> "V4 project-state head has no object target"
  | Unexpected_object_type object_type ->
      Printf.sprintf "V4 project-state head points to object type %d"
        (Envelope.object_type_code object_type)

type repository = { store : Store.repository }

type loaded = {
  project : Model.project;
  head : Store.Mutable_ref.t;
  object_id : Store.Stored_object_id.t;
}

let state_head_name = "v4-project-state"
let underlying_store repository = repository.store
let ( let* ) = Result.bind
let repository_metadata_path root = Filename.concat root ".yeokcham"

let payload_for_project project =
  let* encoded =
    Record.encode_project project
    |> Result.map_error (fun error -> Record_error error)
  in
  Encoding.decode encoded
  |> Result.map_error (fun error -> Record_error (Record.Decode_error error))

let store_project store project =
  let* payload = payload_for_project project in
  let* envelope =
    Envelope.create ~object_type:Envelope.V4_project_state
      ~object_format_version:Envelope.current_object_format_version
      ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
    |> Result.map_error (fun error -> Envelope_error error)
  in
  Store.put store envelope |> Result.map_error (fun error -> Store_error error)

let decode_project_object store object_id =
  let* object_ =
    Store.get store object_id
    |> Result.map_error (fun error -> Store_error error)
  in
  if Envelope.object_type object_ <> Envelope.V4_project_state then
    Error (Unexpected_object_type (Envelope.object_type object_))
  else
    Envelope.payload object_ |> Encoding.encode |> Record.decode_project
    |> Result.map_error (fun error -> Record_error error)

let current_head repository =
  Store.read_ref repository.store ~name:state_head_name
  |> Result.map_error (fun error -> Store_error error)

let load repository =
  let* head = current_head repository in
  match head with
  | None -> Error Missing_state_head
  | Some head -> (
      match Store.Mutable_ref.target head with
      | None -> Error Empty_state_head
      | Some object_id ->
          let* project = decode_project_object repository.store object_id in
          Ok { project; head; object_id })

let init_with ~root ~bootstrap =
  let metadata = repository_metadata_path root in
  if Sys.file_exists metadata then Error (Existing_repository metadata)
  else
    let* store =
      Store.init ~root |> Result.map_error (fun error -> Store_error error)
    in
    let* project =
      bootstrap store |> Result.map_error (fun error -> Bootstrap_error error)
    in
    let* object_id = store_project store project in
    let* _ =
      Store.compare_and_swap_ref store ~name:state_head_name ~expected:None
        ~target:(Some object_id)
      |> Result.map_error (fun error -> Store_error error)
    in
    Ok { store }

let init ~root ~project = init_with ~root ~bootstrap:(fun _ -> Ok project)

let open_repository ~root =
  let* store =
    Store.open_repository ~root
    |> Result.map_error (fun error -> Store_error error)
  in
  let repository = { store } in
  let* _ = load repository in
  Ok repository

let save repository ~expected ~project =
  let* object_id = store_project repository.store project in
  let* head =
    Store.compare_and_swap_ref repository.store ~name:state_head_name
      ~expected:(Some expected) ~target:(Some object_id)
    |> Result.map_error (fun error -> Store_error error)
  in
  Ok { project; head; object_id }
