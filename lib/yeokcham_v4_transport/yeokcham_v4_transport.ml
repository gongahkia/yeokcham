module Model = Yeokcham_v4_model
module Trust = Yeokcham_v4_trust
module Encoding = Yeokcham_encoding
module Hash = Yeokcham_hash.Sha256

type publication = {
  publication_repository_value : Trust.Repository_id.t;
  publication_publisher_value : Model.Device_id.t;
  publication_certificate_value : string;
  publication_parents_value : string list;
  publication_manifest_value : string;
  publication_signature : string;
  publication_id_value : string;
}

type publication_reference = {
  reference_id_value : string;
  reference_publisher_value : Model.Device_id.t;
  reference_certificate_value : string;
}

type remote_state = {
  remote_name_value : string;
  remote_cursor_value : string option;
  remote_known_publications_value : publication_reference list;
  remote_announced_manifests_value : string list;
  remote_announced_revisions_value : Model.Revision_id.t list;
  remote_review_inbox_value : string list;
}

type local_state = { local_remotes : remote_state list }

type error =
  | Invalid_digest of string
  | Invalid_remote_name of string
  | Invalid_publication of string
  | Noncanonical_bytes
  | Duplicate_publication of string
  | Missing_feed_parent of string
  | Cross_publisher_parent of string
  | Feed_cycle of string
  | Repository_mismatch
  | Unknown_publisher_certificate
  | Publisher_certificate_mismatch
  | Publisher_not_active
  | Trust_error of Trust.error
  | Encoding_error of Encoding.construction_error
  | Decode_error of Encoding.decode_error

let publication_schema_version = 1L
let local_state_schema_version = 1L
let publication_signature_domain = "yeokcham:v4:transport-publication:1\000"

let error_to_string = function
  | Invalid_digest value -> "invalid V4 transport digest: " ^ value
  | Invalid_remote_name value -> "invalid V4 transport remote name: " ^ value
  | Invalid_publication detail -> "invalid V4 transport publication: " ^ detail
  | Noncanonical_bytes -> "V4 transport record is not canonically encoded"
  | Duplicate_publication id -> "duplicate V4 transport publication: " ^ id
  | Missing_feed_parent id ->
      "V4 transport publication is missing feed parent: " ^ id
  | Cross_publisher_parent id ->
      "V4 transport publication parent has another publisher: " ^ id
  | Feed_cycle id -> "V4 transport publication feed has a cycle at: " ^ id
  | Repository_mismatch ->
      "V4 transport publication belongs to another repository"
  | Unknown_publisher_certificate ->
      "V4 transport publication names an unknown publisher certificate"
  | Publisher_certificate_mismatch ->
      "V4 transport publisher does not match its certificate"
  | Publisher_not_active ->
      "V4 transport publisher is not active at any current authority head"
  | Trust_error error -> Trust.error_to_string error
  | Encoding_error error -> Encoding.construction_error_to_string error
  | Decode_error error -> Encoding.decode_error_to_string error

let hex_of_bytes bytes =
  let alphabet = "0123456789abcdef" in
  String.init
    (String.length bytes * 2)
    (fun index ->
      let value = Char.code bytes.[index / 2] in
      if index mod 2 = 0 then alphabet.[value lsr 4]
      else alphabet.[value land 15])

let sha256 bytes =
  Hash.digest_string bytes |> Hash.to_raw_string |> hex_of_bytes

let valid_digest value =
  String.length value = 64
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       value

let ( let* ) = Result.bind
let construction = Result.map_error (fun error -> Encoding_error error)
let text value = Encoding.text value |> construction
let array values = Encoding.array values |> construction

let array_values name = function
  | Encoding.Array values -> Ok values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_publication (name ^ " must be an array"))

let exact_array name length value =
  let* values = array_values name value in
  if List.length values = length then Ok values
  else Error (Invalid_publication (name ^ " has the wrong field count"))

let text_field name = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_publication (name ^ " must be text"))

let bytes_field name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_publication (name ^ " must be bytes"))

let integer_field name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_publication (name ^ " must be an integer"))

let check_digest value =
  if valid_digest value then Ok () else Error (Invalid_digest value)

let strictly_sorted name compare values =
  let rec loop = function
    | [] | [ _ ] -> Ok ()
    | left :: (right :: _ as rest) ->
        if compare left right < 0 then loop rest
        else Error (Invalid_publication (name ^ " must be sorted and unique"))
  in
  loop values

let encode_texts values =
  let rec loop reversed = function
    | [] -> array (List.rev reversed)
    | value :: rest ->
        let* value = text value in
        loop (value :: reversed) rest
  in
  loop [] values

let decode_texts name value =
  let* values = array_values name value in
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | value :: rest ->
        let* value = text_field name value in
        loop (value :: reversed) rest
  in
  loop [] values

let check_certificate value = check_digest value

let unsigned_value ~repository ~publisher ~certificate ~parents ~manifest =
  let* () = check_certificate certificate in
  let* () = check_digest manifest in
  let* () =
    List.fold_left
      (fun result parent ->
        let* () = result in
        check_digest parent)
      (Ok ()) parents
  in
  let* () = strictly_sorted "publication parents" String.compare parents in
  let* repository = text (Trust.Repository_id.to_string repository) in
  let* publisher = text (Model.Device_id.to_string publisher) in
  let* certificate = text certificate in
  let* parents = encode_texts parents in
  let* manifest = text manifest in
  let* algorithm = text Trust.algorithm in
  array
    [
      Encoding.integer publication_schema_version;
      repository;
      publisher;
      certificate;
      parents;
      manifest;
      algorithm;
    ]

let unsigned_bytes ~repository ~publisher ~certificate ~parents ~manifest =
  unsigned_value ~repository ~publisher ~certificate ~parents ~manifest
  |> Result.map Encoding.encode

let publication_bytes publication =
  let unsigned =
    unsigned_value ~repository:publication.publication_repository_value
      ~publisher:publication.publication_publisher_value
      ~certificate:publication.publication_certificate_value
      ~parents:publication.publication_parents_value
      ~manifest:publication.publication_manifest_value
    |> Result.get_ok
  in
  Encoding.array [ unsigned; Encoding.bytes publication.publication_signature ]
  |> Result.get_ok |> Encoding.encode

let create_publication ~repository ~publisher ~certificate ~parents ~manifest
    ~signing_capability =
  let* signing_device =
    Trust.device_of_public_key (Trust.signing_public_key signing_capability)
    |> Result.map_error (fun error -> Trust_error error)
  in
  if not (Trust.device_equal signing_device publisher) then
    Error (Invalid_publication "signing capability does not match publisher")
  else
    let* unsigned =
      unsigned_bytes ~repository
        ~publisher:(Trust.device_id publisher)
        ~certificate ~parents ~manifest
    in
    let signature =
      Trust.sign_detached signing_capability
        ~domain:publication_signature_domain unsigned
    in
    let provisional =
      {
        publication_repository_value = repository;
        publication_publisher_value = Trust.device_id publisher;
        publication_certificate_value = certificate;
        publication_parents_value = parents;
        publication_manifest_value = manifest;
        publication_signature = signature;
        publication_id_value = "";
      }
    in
    let publication_id_value = sha256 (publication_bytes provisional) in
    Ok { provisional with publication_id_value }

let publication_id publication = publication.publication_id_value

let publication_repository publication =
  publication.publication_repository_value

let publication_publisher publication = publication.publication_publisher_value

let publication_certificate publication =
  publication.publication_certificate_value

let publication_parents publication = publication.publication_parents_value
let publication_manifest publication = publication.publication_manifest_value
let encode_publication = publication_bytes

let decode_device_id value =
  Model.Device_id.of_string value
  |> Result.map_error (fun error ->
      Invalid_publication (Model.error_to_string error))

let decode_publication bytes =
  let* value =
    Encoding.decode bytes |> Result.map_error (fun error -> Decode_error error)
  in
  let* fields = exact_array "transport publication" 2 value in
  match fields with
  | [ unsigned; signature ] -> (
      let* unsigned =
        exact_array "transport publication unsigned body" 7 unsigned
      in
      let* signature =
        bytes_field "transport publication signature" signature
      in
      if String.length signature <> 64 then
        Error (Trust_error (Trust.Invalid_signature (String.length signature)))
      else
        match unsigned with
        | [
         version;
         repository;
         publisher;
         certificate;
         parents;
         manifest;
         algorithm;
        ] ->
            let* version =
              integer_field "transport publication version" version
            in
            if not (Int64.equal version publication_schema_version) then
              Error
                (Invalid_publication "unsupported transport publication version")
            else
              let* repository =
                text_field "transport publication repository" repository
              in
              let* repository =
                Trust.Repository_id.of_string repository
                |> Result.map_error (fun error -> Invalid_publication error)
              in
              let* publisher =
                text_field "transport publication publisher" publisher
              in
              let* publisher = decode_device_id publisher in
              let* certificate =
                text_field "transport publication certificate" certificate
              in
              let* () = check_certificate certificate in
              let* parents =
                decode_texts "transport publication parents" parents
              in
              let* () =
                List.fold_left
                  (fun result parent ->
                    let* () = result in
                    check_digest parent)
                  (Ok ()) parents
              in
              let* () =
                strictly_sorted "publication parents" String.compare parents
              in
              let* manifest =
                text_field "transport publication manifest" manifest
              in
              let* () = check_digest manifest in
              let* algorithm =
                text_field "transport publication algorithm" algorithm
              in
              if not (String.equal algorithm Trust.algorithm) then
                Error
                  (Invalid_publication
                     "unsupported transport signature algorithm")
              else
                let* canonical_unsigned =
                  unsigned_bytes ~repository ~publisher ~certificate ~parents
                    ~manifest
                in
                let canonical =
                  Encoding.array
                    [
                      Encoding.decode canonical_unsigned |> Result.get_ok;
                      Encoding.bytes signature;
                    ]
                  |> Result.get_ok |> Encoding.encode
                in
                if not (String.equal canonical bytes) then
                  Error Noncanonical_bytes
                else
                  Ok
                    {
                      publication_repository_value = repository;
                      publication_publisher_value = publisher;
                      publication_certificate_value = certificate;
                      publication_parents_value = parents;
                      publication_manifest_value = manifest;
                      publication_signature = signature;
                      publication_id_value = sha256 bytes;
                    }
        | _ -> assert false)
  | _ -> assert false

let verify_publication ~authority publication =
  let expected_repository =
    Trust.repository (Trust.authority_membership authority)
  in
  if
    not
      (Trust.Repository_id.equal expected_repository
         publication.publication_repository_value)
  then Error Repository_mismatch
  else
    let certificate =
      Trust.certificates (Trust.authority_membership authority)
      |> List.find_opt (fun certificate ->
          String.equal
            (Trust.certificate_id certificate)
            publication.publication_certificate_value)
    in
    match certificate with
    | None -> Error Unknown_publisher_certificate
    | Some certificate ->
        let device = Trust.certificate_subject certificate in
        if
          not
            (Model.Device_id.equal (Trust.device_id device)
               publication.publication_publisher_value)
        then Error Publisher_certificate_mismatch
        else if
          not
            (List.exists
               (fun epoch ->
                 Trust.authority_device_active authority ~epoch device)
               (Trust.authority_heads authority))
        then Error Publisher_not_active
        else
          let* unsigned =
            unsigned_bytes ~repository:publication.publication_repository_value
              ~publisher:publication.publication_publisher_value
              ~certificate:publication.publication_certificate_value
              ~parents:publication.publication_parents_value
              ~manifest:publication.publication_manifest_value
          in
          Trust.verify_detached ~device ~domain:publication_signature_domain
            ~signature:publication.publication_signature unsigned
          |> Result.map_error (fun error -> Trust_error error)

let publication_reference publication =
  {
    reference_id_value = publication.publication_id_value;
    reference_publisher_value = publication.publication_publisher_value;
    reference_certificate_value = publication.publication_certificate_value;
  }

let reference_id reference = reference.reference_id_value
let reference_publisher reference = reference.reference_publisher_value
let reference_certificate reference = reference.reference_certificate_value

let validate_references references =
  let references =
    List.sort
      (fun left right ->
        String.compare left.reference_id_value right.reference_id_value)
      references
  in
  let rec loop = function
    | [] | [ _ ] -> Ok ()
    | left :: (right :: _ as rest) ->
        if String.equal left.reference_id_value right.reference_id_value then
          Error (Duplicate_publication left.reference_id_value)
        else loop rest
  in
  loop references

let validate_feed ~known publications =
  let* () = validate_references known in
  let by_id = Hashtbl.create (List.length publications) in
  let add publication =
    let id = publication.publication_id_value in
    if Hashtbl.mem by_id id then Error (Duplicate_publication id)
    else (
      Hashtbl.add by_id id publication;
      Ok ())
  in
  let* () =
    List.fold_left
      (fun result publication ->
        let* () = result in
        add publication)
      (Ok ()) publications
  in
  let known_by_id = Hashtbl.create (List.length known) in
  List.iter
    (fun reference ->
      Hashtbl.add known_by_id reference.reference_id_value reference)
    known;
  let parent_reference parent =
    match Hashtbl.find_opt by_id parent with
    | Some parent_publication ->
        Ok
          ( publication_publisher parent_publication,
            publication_certificate parent_publication )
    | None -> (
        match Hashtbl.find_opt known_by_id parent with
        | Some reference ->
            Ok
              ( reference.reference_publisher_value,
                reference.reference_certificate_value )
        | None -> Error (Missing_feed_parent parent))
  in
  let* () =
    List.fold_left
      (fun result publication ->
        let* () = result in
        List.fold_left
          (fun result parent ->
            let* () = result in
            let* publisher, certificate = parent_reference parent in
            if
              Model.Device_id.equal publisher
                publication.publication_publisher_value
              && String.equal certificate
                   publication.publication_certificate_value
            then Ok ()
            else Error (Cross_publisher_parent parent))
          (Ok ()) publication.publication_parents_value)
      (Ok ()) publications
  in
  let visiting = Hashtbl.create (List.length publications) in
  let visited = Hashtbl.create (List.length publications) in
  let rec visit id =
    if Hashtbl.mem visited id then Ok ()
    else if Hashtbl.mem visiting id then Error (Feed_cycle id)
    else (
      Hashtbl.add visiting id ();
      let* () =
        match Hashtbl.find_opt by_id id with
        | None -> Ok ()
        | Some publication ->
            List.fold_left
              (fun result parent ->
                let* () = result in
                if Hashtbl.mem by_id parent then visit parent else Ok ())
              (Ok ()) publication.publication_parents_value
      in
      Hashtbl.remove visiting id;
      Hashtbl.add visited id ();
      Ok ())
  in
  List.fold_left
    (fun result publication ->
      let* () = result in
      visit publication.publication_id_value)
    (Ok ()) publications

let valid_remote_character = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' -> true
  | _ -> false

let validate_remote_name name =
  if
    String.length name = 0
    || String.length name > 64
    || not (String.for_all valid_remote_character name)
  then Error (Invalid_remote_name name)
  else Ok ()

let strictly_sorted_digests name values =
  let* () =
    List.fold_left
      (fun result value ->
        let* () = result in
        check_digest value)
      (Ok ()) values
  in
  strictly_sorted name String.compare values

let remote_state ~name ~cursor ~known ~announced_manifests ~announced_revisions
    ~review_inbox =
  let* () = validate_remote_name name in
  let* () = validate_references known in
  let known =
    List.sort
      (fun left right ->
        String.compare left.reference_id_value right.reference_id_value)
      known
  in
  let* () = strictly_sorted_digests "announced manifests" announced_manifests in
  let* () =
    strictly_sorted "announced revisions" Model.Revision_id.compare
      announced_revisions
  in
  let* () = strictly_sorted_digests "review inbox" review_inbox in
  Ok
    {
      remote_name_value = name;
      remote_cursor_value = cursor;
      remote_known_publications_value = known;
      remote_announced_manifests_value = announced_manifests;
      remote_announced_revisions_value = announced_revisions;
      remote_review_inbox_value = review_inbox;
    }

let empty_local_state = { local_remotes = [] }
let remote_name remote = remote.remote_name_value
let remote_cursor remote = remote.remote_cursor_value
let remote_known_publications remote = remote.remote_known_publications_value
let remote_announced_manifests remote = remote.remote_announced_manifests_value
let remote_announced_revisions remote = remote.remote_announced_revisions_value
let remote_review_inbox remote = remote.remote_review_inbox_value
let remotes state = state.local_remotes

let find_remote state ~name =
  List.find_opt
    (fun remote -> String.equal remote.remote_name_value name)
    state.local_remotes

let with_remote state remote =
  let rec insert reversed = function
    | [] -> Ok { local_remotes = List.rev (remote :: reversed) }
    | current :: rest ->
        let compared =
          String.compare remote.remote_name_value current.remote_name_value
        in
        if compared = 0 then
          Ok { local_remotes = List.rev_append reversed (remote :: rest) }
        else if compared < 0 then
          Ok
            {
              local_remotes =
                List.rev_append reversed (remote :: current :: rest);
            }
        else insert (current :: reversed) rest
  in
  insert [] state.local_remotes

let remove_remote state ~name =
  {
    local_remotes =
      List.filter
        (fun remote -> not (String.equal remote.remote_name_value name))
        state.local_remotes;
  }

let encode_reference reference =
  let* id = text reference.reference_id_value in
  let* publisher =
    text (Model.Device_id.to_string reference.reference_publisher_value)
  in
  let* certificate = text reference.reference_certificate_value in
  array [ id; publisher; certificate ]

let encode_references references =
  let rec loop reversed = function
    | [] -> array (List.rev reversed)
    | reference :: rest ->
        let* encoded = encode_reference reference in
        loop (encoded :: reversed) rest
  in
  loop [] references

let encode_revisions revisions =
  revisions
  |> List.map (fun revision -> Model.Revision_id.to_string revision)
  |> encode_texts

let encode_option_text = function
  | None -> Ok Encoding.null
  | Some value -> text value

let encode_remote remote =
  let* name = text remote.remote_name_value in
  let* cursor = encode_option_text remote.remote_cursor_value in
  let* known = encode_references remote.remote_known_publications_value in
  let* manifests = encode_texts remote.remote_announced_manifests_value in
  let* revisions = encode_revisions remote.remote_announced_revisions_value in
  let* inbox = encode_texts remote.remote_review_inbox_value in
  array [ name; cursor; known; manifests; revisions; inbox ]

let encode_local_state state =
  let rec loop reversed = function
    | [] -> array (List.rev reversed)
    | remote :: rest ->
        let* encoded = encode_remote remote in
        loop (encoded :: reversed) rest
  in
  let* remotes = loop [] state.local_remotes in
  array [ Encoding.integer local_state_schema_version; remotes ]
  |> Result.map Encoding.encode

let decode_reference value =
  let* fields = exact_array "transport publication reference" 3 value in
  match fields with
  | [ id; publisher; certificate ] ->
      let* id = text_field "transport reference ID" id in
      let* () = check_digest id in
      let* publisher = text_field "transport reference publisher" publisher in
      let* publisher = decode_device_id publisher in
      let* certificate =
        text_field "transport reference certificate" certificate
      in
      let* () = check_certificate certificate in
      Ok
        {
          reference_id_value = id;
          reference_publisher_value = publisher;
          reference_certificate_value = certificate;
        }
  | _ -> assert false

let decode_references value =
  let* values = array_values "transport references" value in
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | value :: rest ->
        let* reference = decode_reference value in
        loop (reference :: reversed) rest
  in
  loop [] values

let decode_revisions value =
  let* values = decode_texts "transport announced revisions" value in
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | value :: rest ->
        let* revision =
          Model.Revision_id.of_string value
          |> Result.map_error (fun error ->
              Invalid_publication (Model.error_to_string error))
        in
        loop (revision :: reversed) rest
  in
  loop [] values

let decode_option_text name = function
  | Encoding.Null -> Ok None
  | Encoding.Text value -> Ok (Some value)
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ ->
      Error (Invalid_publication (name ^ " must be text or null"))

let decode_remote value =
  let* fields = exact_array "transport remote" 6 value in
  match fields with
  | [ name; cursor; known; manifests; revisions; inbox ] ->
      let* name = text_field "transport remote name" name in
      let* cursor = decode_option_text "transport cursor" cursor in
      let* known = decode_references known in
      let* manifests = decode_texts "transport announced manifests" manifests in
      let* revisions = decode_revisions revisions in
      let* inbox = decode_texts "transport review inbox" inbox in
      remote_state ~name ~cursor ~known ~announced_manifests:manifests
        ~announced_revisions:revisions ~review_inbox:inbox
  | _ -> assert false

let decode_local_state bytes =
  let* value =
    Encoding.decode bytes |> Result.map_error (fun error -> Decode_error error)
  in
  let* fields = exact_array "transport local state" 2 value in
  match fields with
  | [ version; remotes ] ->
      let* version = integer_field "transport local state version" version in
      if not (Int64.equal version local_state_schema_version) then
        Error (Invalid_publication "unsupported transport local state version")
      else
        let* values = array_values "transport remotes" remotes in
        let rec loop reversed = function
          | [] -> Ok (List.rev reversed)
          | value :: rest ->
              let* remote = decode_remote value in
              loop (remote :: reversed) rest
        in
        let* remotes = loop [] values in
        let rec sorted = function
          | [] | [ _ ] -> Ok ()
          | left :: (right :: _ as rest) ->
              if
                String.compare left.remote_name_value right.remote_name_value
                < 0
              then sorted rest
              else
                Error
                  (Invalid_publication
                     "transport remotes must be sorted and unique")
        in
        let* () = sorted remotes in
        let state = { local_remotes = remotes } in
        let* canonical = encode_local_state state in
        if String.equal canonical bytes then Ok state
        else Error Noncanonical_bytes
  | _ -> assert false
