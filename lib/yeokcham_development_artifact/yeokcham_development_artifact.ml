type artifact_kind = Client_archive | Fedora_rpm | Relay_oci

type artifact = {
  kind : artifact_kind;
  filename : string;
  sha256 : string;
  size : int64;
}

type signing_identity = {
  workflow_identity : string;
  oidc_issuer : string;
  certificate_sha256 : string;
  bundle_filename : string;
}

type record = {
  source_commit : string;
  source_timestamp : int64;
  architecture : string;
  ocaml_version : string;
  dune_version : string;
  opam_lock_sha256 : string;
  builder_image : string;
  fedora_image : string;
  sbom_sha256 : string;
  signing : signing_identity;
  artifacts : artifact list;
}

let schema_version = 1

let valid_text value =
  String.length value > 0
  && String.length value <= 4096
  && not
       (String.exists
          (function '\000' | '\r' | '\n' -> true | _ -> false)
          value)

let is_lower_hex ~length value =
  String.length value = length
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       value

let artifact_kind_to_string = function
  | Client_archive -> "client-archive"
  | Fedora_rpm -> "fedora-rpm"
  | Relay_oci -> "relay-oci"

let compare_artifact left right = String.compare left.filename right.filename

let make ~source_commit ~source_timestamp ~architecture ~ocaml_version
    ~dune_version ~opam_lock_sha256 ~builder_image ~fedora_image ~sbom_sha256
    ~signing ~artifacts =
  if
    not
      (is_lower_hex ~length:40 source_commit
      || is_lower_hex ~length:64 source_commit)
  then Error "development build record has an invalid source commit"
  else if source_timestamp < 0L then
    Error "development build record has an invalid source timestamp"
  else if
    not
      (List.for_all valid_text
         [
           architecture;
           ocaml_version;
           dune_version;
           builder_image;
           fedora_image;
           signing.workflow_identity;
           signing.oidc_issuer;
           signing.bundle_filename;
         ])
  then Error "development build record has invalid text"
  else if
    not
      (List.for_all (is_lower_hex ~length:64)
         [ opam_lock_sha256; sbom_sha256; signing.certificate_sha256 ])
  then Error "development build record has an invalid SHA-256"
  else if artifacts = [] then Error "development build record has no artifacts"
  else if
    not
      (List.for_all
         (fun artifact ->
           valid_text artifact.filename
           && artifact.size >= 0L
           && is_lower_hex ~length:64 artifact.sha256)
         artifacts)
  then Error "development build record has an invalid artifact"
  else
    let artifacts = List.sort compare_artifact artifacts in
    let names = List.map (fun artifact -> artifact.filename) artifacts in
    if List.length names <> List.length (List.sort_uniq String.compare names)
    then Error "development build record has duplicate artifact filenames"
    else
      Ok
        {
          source_commit;
          source_timestamp;
          architecture;
          ocaml_version;
          dune_version;
          opam_lock_sha256;
          builder_image;
          fedora_image;
          sbom_sha256;
          signing;
          artifacts;
        }

let encode record =
  let artifact artifact =
    `Assoc
      [
        ("kind", `String (artifact_kind_to_string artifact.kind));
        ("filename", `String artifact.filename);
        ("sha256", `String artifact.sha256);
        ("size", `Intlit (Int64.to_string artifact.size));
      ]
  in
  `Assoc
    [
      ("schema_version", `Int schema_version);
      ("source_commit", `String record.source_commit);
      ("source_timestamp", `Intlit (Int64.to_string record.source_timestamp));
      ("architecture", `String record.architecture);
      ("ocaml_version", `String record.ocaml_version);
      ("dune_version", `String record.dune_version);
      ("opam_lock_sha256", `String record.opam_lock_sha256);
      ("builder_image", `String record.builder_image);
      ("fedora_image", `String record.fedora_image);
      ("sbom_sha256", `String record.sbom_sha256);
      ( "signing",
        `Assoc
          [
            ("workflow_identity", `String record.signing.workflow_identity);
            ("oidc_issuer", `String record.signing.oidc_issuer);
            ("certificate_sha256", `String record.signing.certificate_sha256);
            ("bundle_filename", `String record.signing.bundle_filename);
          ] );
      ("artifacts", `List (List.map artifact record.artifacts));
    ]
  |> Yojson.Safe.to_string

let duplicate values =
  let sorted = List.sort String.compare values in
  let rec loop = function
    | left :: right :: _ when String.equal left right -> true
    | _ :: rest -> loop rest
    | [] -> false
  in
  loop sorted

let exact_fields expected fields =
  let names = List.map fst fields in
  (not (duplicate names))
  && List.sort String.compare names = List.sort String.compare expected

let ( let* ) = Result.bind

let field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error ("development build record is missing " ^ name)

let string_field name fields =
  let* value = field name fields in
  match value with
  | `String value -> Ok value
  | _ -> Error ("development build record " ^ name ^ " must be text")

let int64_field name fields =
  let* value = field name fields in
  let value =
    match value with
    | `Int value -> Some (string_of_int value)
    | `Intlit value -> Some value
    | _ -> None
  in
  match Option.bind value Int64.of_string_opt with
  | Some value -> Ok value
  | None -> Error ("development build record " ^ name ^ " must be an integer")

let artifact_kind_of_string = function
  | "client-archive" -> Ok Client_archive
  | "fedora-rpm" -> Ok Fedora_rpm
  | "relay-oci" -> Ok Relay_oci
  | _ -> Error "development build record has an unknown artifact kind"

let decode_artifact = function
  | `Assoc fields
    when exact_fields [ "kind"; "filename"; "sha256"; "size" ] fields ->
      let* kind =
        Result.bind (string_field "kind" fields) artifact_kind_of_string
      in
      let* filename = string_field "filename" fields in
      let* sha256 = string_field "sha256" fields in
      let* size = int64_field "size" fields in
      Ok { kind; filename; sha256; size }
  | `Assoc _ -> Error "development build record artifact has unknown fields"
  | _ -> Error "development build record artifact must be an object"

let decode_artifacts = function
  | `List values ->
      List.fold_left
        (fun result value ->
          let* reversed = result in
          let* artifact = decode_artifact value in
          Ok (artifact :: reversed))
        (Ok []) values
      |> Result.map List.rev
  | _ -> Error "development build record artifacts must be an array"

let decode_signing = function
  | `Assoc fields
    when exact_fields
           [
             "workflow_identity";
             "oidc_issuer";
             "certificate_sha256";
             "bundle_filename";
           ]
           fields ->
      let* workflow_identity = string_field "workflow_identity" fields in
      let* oidc_issuer = string_field "oidc_issuer" fields in
      let* certificate_sha256 = string_field "certificate_sha256" fields in
      let* bundle_filename = string_field "bundle_filename" fields in
      Ok { workflow_identity; oidc_issuer; certificate_sha256; bundle_filename }
  | `Assoc _ -> Error "development build record signing has unknown fields"
  | _ -> Error "development build record signing must be an object"

let decode input =
  let value =
    try Ok (Yojson.Safe.from_string input)
    with Yojson.Json_error message ->
      Error ("invalid development build record JSON: " ^ message)
  in
  let* value = value in
  match value with
  | `Assoc fields
    when exact_fields
           [
             "schema_version";
             "source_commit";
             "source_timestamp";
             "architecture";
             "ocaml_version";
             "dune_version";
             "opam_lock_sha256";
             "builder_image";
             "fedora_image";
             "sbom_sha256";
             "signing";
             "artifacts";
           ]
           fields ->
      let* version = field "schema_version" fields in
      let* () =
        match version with
        | `Int value when value = schema_version -> Ok ()
        | _ -> Error "unsupported development build record schema version"
      in
      let* source_commit = string_field "source_commit" fields in
      let* source_timestamp = int64_field "source_timestamp" fields in
      let* architecture = string_field "architecture" fields in
      let* ocaml_version = string_field "ocaml_version" fields in
      let* dune_version = string_field "dune_version" fields in
      let* opam_lock_sha256 = string_field "opam_lock_sha256" fields in
      let* builder_image = string_field "builder_image" fields in
      let* fedora_image = string_field "fedora_image" fields in
      let* sbom_sha256 = string_field "sbom_sha256" fields in
      let* signing = Result.bind (field "signing" fields) decode_signing in
      let* artifacts =
        Result.bind (field "artifacts" fields) decode_artifacts
      in
      let* record =
        make ~source_commit ~source_timestamp ~architecture ~ocaml_version
          ~dune_version ~opam_lock_sha256 ~builder_image ~fedora_image
          ~sbom_sha256 ~signing ~artifacts
      in
      if String.equal input (encode record) then Ok record
      else Error "development build record bytes are noncanonical"
  | `Assoc _ -> Error "development build record has unknown or duplicate fields"
  | _ -> Error "development build record must be an object"
