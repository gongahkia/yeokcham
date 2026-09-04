module Health = Yeokcham_v4_health
module Plan_store = Yeokcham_v4_health_store
module Golden = Yeokcham_testkit.Golden_fixture

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let identifier character = String.make 64 character

let golden_path name =
  let local = Filename.concat "golden" name in
  if Sys.file_exists local then local else Filename.concat "test/golden" name

let plan () =
  let source = Health.Backup "backup-20260904" in
  let candidate =
    Health.make_candidate ~source ~object_id:(identifier 'a')
      ~canonical_bytes_id:(identifier 'a')
    |> require_ok Health.refusal_to_string
  in
  let report =
    Health.verify
      [
        Health.Object_observation
          {
            object_id = identifier 'a';
            status = Health.Missing;
            references = [];
          };
      ]
    |> require_ok Health.refusal_to_string
  in
  Health.make_plan ~repository:(identifier 'd') ~state_head:(identifier 'e')
    ~source
    ~damages:(Health.report_damages report)
    ~candidates:[ candidate ] ~created_at:10L ~expires_at:20L
  |> require_ok Health.refusal_to_string

let rec remove_tree path =
  try
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun name -> remove_tree (Filename.concat path name));
        Unix.rmdir path
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
    | Unix.S_SOCK ->
        Unix.unlink path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_root run =
  let root = Filename.temp_file "v4-health-plan-store-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Unix.mkdir (Filename.concat root ".yeokcham") 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let create_only_plan_round_trip () =
  with_root (fun root ->
      let value = plan () in
      Plan_store.append ~root value |> require_ok Plan_store.error_to_string;
      Plan_store.append ~root value |> require_ok Plan_store.error_to_string;
      let recovered =
        Plan_store.find ~root ~id:(Health.plan_id value)
        |> require_ok Plan_store.error_to_string
      in
      Alcotest.(check string)
        "stored plan retains canonical ID" (Health.plan_id value)
        (Health.plan_id recovered);
      let plans =
        Plan_store.scan ~root |> require_ok Plan_store.error_to_string
      in
      Alcotest.(check int) "one create-only plan" 1 (List.length plans))

let plan_matches_the_canonical_golden_fixture () =
  let expected =
    Golden.read_lower_hex_file (golden_path "v4/repair-plan-v1.cbor.hex")
    |> require_ok Fun.id
  in
  let value = plan () in
  Alcotest.(check string)
    "canonical repair plan bytes" expected (Health.encode_plan value);
  let decoded =
    Health.decode_plan expected |> require_ok Health.refusal_to_string
  in
  Alcotest.(check string)
    "golden plan round trip" expected
    (Health.encode_plan decoded)

let corrupted_or_divergent_plan_never_overwrites () =
  with_root (fun root ->
      let value = plan () in
      let directory = Plan_store.directory ~root in
      Unix.mkdir directory 0o700;
      let target =
        Plan_store.path ~root ~id:(Health.plan_id value)
        |> require_ok Plan_store.error_to_string
      in
      Out_channel.with_open_bin target (fun output ->
          Out_channel.output_string output "corrupt plan");
      (match Plan_store.append ~root value with
      | Error error ->
          Alcotest.(check bool)
            "divergent plan refuses without overwrite" true
            (String.starts_with
               ~prefix:"V4 repair plan path contains different bytes: "
               (Plan_store.error_to_string error))
      | Ok () -> Alcotest.fail "divergent plan was overwritten");
      let retained = In_channel.with_open_bin target In_channel.input_all in
      Alcotest.(check string)
        "corrupt original remains evidence" "corrupt plan" retained;
      match Plan_store.find ~root ~id:(Health.plan_id value) with
      | Error error ->
          Alcotest.(check bool)
            "corrupt plan refuses to decode" true
            (String.starts_with ~prefix:"invalid V4 repair source locator: "
               (Plan_store.error_to_string error))
      | Ok _ -> Alcotest.fail "corrupt plan decoded")

let () =
  Alcotest.run "V4 health plan store"
    [
      ( "persistence",
        [
          Alcotest.test_case "create-only canonical plan" `Quick
            create_only_plan_round_trip;
          Alcotest.test_case "canonical repair plan golden" `Quick
            plan_matches_the_canonical_golden_fixture;
          Alcotest.test_case "corruption never overwrites" `Quick
            corrupted_or_divergent_plan_never_overwrites;
        ] );
    ]
