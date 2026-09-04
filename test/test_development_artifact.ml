module Artifact = Yeokcham_development_artifact

let require_ok = function
  | Ok value -> value
  | Error error -> Alcotest.fail error

let fixture_path name =
  let local = Filename.concat "golden" name in
  if Sys.file_exists local then local else Filename.concat "test/golden" name

let source_commit = String.make 40 'a'
let digest character = String.make 64 character

let record () =
  Artifact.make ~source_commit ~source_timestamp:10L
    ~architecture:"linux-x86_64" ~ocaml_version:"5.5.0" ~dune_version:"3.24.2"
    ~opam_lock_sha256:(digest 'b')
    ~builder_image:("docker.io/example/builder@sha256:" ^ digest 'c')
    ~fedora_image:("registry.fedoraproject.org/fedora@sha256:" ^ digest 'd')
    ~sbom_sha256:(digest 'e')
    ~signing:
      {
        Artifact.workflow_identity =
          "https://github.com/example/yeokcham/.github/workflows/development-artifact.yml@refs/heads/main";
        oidc_issuer = "https://token.actions.githubusercontent.com";
        certificate_sha256 = digest 'f';
        bundle_filename = "yeokcham.sigstore.json";
      }
    ~artifacts:
      [
        {
          Artifact.kind = Artifact.Fedora_rpm;
          filename = "yeokcham.rpm";
          sha256 = digest '2';
          size = 20L;
        };
        {
          Artifact.kind = Artifact.Client_archive;
          filename = "yeokcham.tar.zst";
          sha256 = digest '1';
          size = 10L;
        };
      ]
  |> require_ok

let canonical_fixture_round_trips () =
  let expected =
    In_channel.with_open_bin
      (fixture_path "v4/development-build-record-v1.json")
      In_channel.input_all
    |> String.trim
  in
  let value = record () in
  Alcotest.(check string)
    "canonical development build record" expected (Artifact.encode value);
  let decoded = Artifact.decode expected |> require_ok in
  Alcotest.(check string)
    "fixture re-encodes exactly" expected (Artifact.encode decoded)

let malformed_unknown_and_noncanonical_records_refuse () =
  let canonical = Artifact.encode (record ()) in
  let unknown =
    String.sub canonical 0 (String.length canonical - 1) ^ ",\"future\":true}"
  in
  let noncanonical =
    String.sub canonical 0 1 ^ " \n"
    ^ String.sub canonical 1 (String.length canonical - 1)
  in
  List.iter
    (fun bytes ->
      Alcotest.(check bool)
        "invalid development record refuses" true
        (Result.is_error (Artifact.decode bytes)))
    [ unknown; noncanonical; "{}" ]

let smoke_receipts_require_every_delivery_boundary () =
  let make ?(archive_installed = true) ?(rpm_lifecycle_checked = true)
      ?(relay_journey_checked = true) ?(ordinary_source_unchanged = true) () =
    Artifact.make_smoke_receipt ~source_commit ~artifact_filename:"yeokcham.rpm"
      ~archive_installed ~rpm_lifecycle_checked ~relay_journey_checked
      ~ordinary_source_unchanged
  in
  Alcotest.(check bool)
    "complete smoke journey records" true
    (Result.is_ok (make ()));
  List.iter
    (fun receipt ->
      Alcotest.(check bool)
        "partial smoke journey refuses" true (Result.is_error receipt))
    [
      make ~archive_installed:false ();
      make ~rpm_lifecycle_checked:false ();
      make ~relay_journey_checked:false ();
      make ~ordinary_source_unchanged:false ();
    ]

let () =
  Alcotest.run "development artifacts"
    [
      ( "record",
        [
          Alcotest.test_case "canonical fixture" `Quick
            canonical_fixture_round_trips;
          Alcotest.test_case "strict decoder" `Quick
            malformed_unknown_and_noncanonical_records_refuse;
          Alcotest.test_case "smoke receipt boundaries" `Quick
            smoke_receipts_require_every_delivery_boundary;
        ] );
    ]
