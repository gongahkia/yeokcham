module Artifact = Yeokcham_development_artifact

let fail message =
  prerr_endline ("render-development-build-record: " ^ message);
  exit 2

let required name = function
  | Some value -> value
  | None -> fail ("missing --" ^ name)

let ( let* ) = Result.bind

let artifact_kind = function
  | "client-archive" -> Ok Artifact.Client_archive
  | "fedora-rpm" -> Ok Artifact.Fedora_rpm
  | "relay-oci" -> Ok Artifact.Relay_oci
  | _ -> Error "artifact kind must be client-archive, fedora-rpm, or relay-oci"

let parse_artifact value =
  match String.split_on_char ':' value with
  | [ kind; filename; sha256; size ] ->
      let* kind = artifact_kind kind in
      let* size =
        match Int64.of_string_opt size with
        | Some size -> Ok size
        | None -> Error "artifact size must be an integer"
      in
      Ok { Artifact.kind; filename; sha256; size }
  | _ -> Error "--artifact must be KIND:FILENAME:SHA256:SIZE"

let () =
  let source_commit = ref None in
  let source_timestamp = ref None in
  let architecture = ref None in
  let ocaml_version = ref None in
  let dune_version = ref None in
  let opam_lock_sha256 = ref None in
  let builder_image = ref None in
  let fedora_image = ref None in
  let sbom_sha256 = ref None in
  let workflow_identity = ref None in
  let oidc_issuer = ref None in
  let certificate_sha256 = ref None in
  let bundle_filename = ref None in
  let artifacts = ref [] in
  let set reference value = reference := Some value in
  let specification =
    [
      ("--source-commit", Arg.String (set source_commit), "source commit");
      ( "--source-timestamp",
        Arg.String (set source_timestamp),
        "source commit timestamp" );
      ("--architecture", Arg.String (set architecture), "artifact architecture");
      ("--ocaml-version", Arg.String (set ocaml_version), "OCaml version");
      ("--dune-version", Arg.String (set dune_version), "Dune version");
      ( "--opam-lock-sha256",
        Arg.String (set opam_lock_sha256),
        "opam lock SHA-256" );
      ("--builder-image", Arg.String (set builder_image), "pinned builder image");
      ("--fedora-image", Arg.String (set fedora_image), "pinned Fedora image");
      ("--sbom-sha256", Arg.String (set sbom_sha256), "SBOM SHA-256");
      ( "--workflow-identity",
        Arg.String (set workflow_identity),
        "keyless signing workflow identity" );
      ("--oidc-issuer", Arg.String (set oidc_issuer), "OIDC issuer");
      ( "--certificate-sha256",
        Arg.String (set certificate_sha256),
        "signing certificate SHA-256" );
      ( "--bundle-filename",
        Arg.String (set bundle_filename),
        "checksum signing-bundle filename" );
      ( "--artifact",
        Arg.String (fun value -> artifacts := value :: !artifacts),
        "KIND:FILENAME:SHA256:SIZE (repeatable)" );
    ]
  in
  Arg.parse specification
    (fun value -> fail ("unexpected argument: " ^ value))
    "usage: render_development_build_record OPTIONS";
  let source_timestamp =
    required "source-timestamp" !source_timestamp |> Int64.of_string_opt
    |> function
    | Some value -> value
    | None -> fail "source timestamp must be an integer"
  in
  let artifacts =
    List.rev !artifacts |> List.map parse_artifact
    |> List.fold_left
         (fun result artifact ->
           let* values = result in
           let* artifact = artifact in
           Ok (artifact :: values))
         (Ok [])
    |> function
    | Ok values -> List.rev values
    | Error message -> fail message
  in
  match
    Artifact.make
      ~source_commit:(required "source-commit" !source_commit)
      ~source_timestamp
      ~architecture:(required "architecture" !architecture)
      ~ocaml_version:(required "ocaml-version" !ocaml_version)
      ~dune_version:(required "dune-version" !dune_version)
      ~opam_lock_sha256:(required "opam-lock-sha256" !opam_lock_sha256)
      ~builder_image:(required "builder-image" !builder_image)
      ~fedora_image:(required "fedora-image" !fedora_image)
      ~sbom_sha256:(required "sbom-sha256" !sbom_sha256)
      ~signing:
        {
          Artifact.workflow_identity =
            required "workflow-identity" !workflow_identity;
          oidc_issuer = required "oidc-issuer" !oidc_issuer;
          certificate_sha256 = required "certificate-sha256" !certificate_sha256;
          bundle_filename = required "bundle-filename" !bundle_filename;
        }
      ~artifacts
  with
  | Ok record -> print_endline (Artifact.encode record)
  | Error message -> fail message
