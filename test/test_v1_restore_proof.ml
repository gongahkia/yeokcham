module Golden = Yeokcham_testkit.Golden_fixture
module Model = Yeokcham_v1_model
module Proof = Yeokcham_v1_restore_proof

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let snapshot value = Model.Snapshot_id.of_string value |> Result.get_ok

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
  let root = Filename.temp_file "v1-restore-proof-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Unix.mkdir (Filename.concat root ".yeokcham") 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let proof () =
  Proof.make ~operation_id:(String.make 64 'a')
    ~safety:(snapshot "snapshot-safety")
    ~target:(snapshot "snapshot-target")
  |> require_ok Proof.error_to_string

let golden_path name =
  let local = Filename.concat "golden" name in
  if Sys.file_exists local then local else Filename.concat "test/golden" name

let proof_has_stable_canonical_bytes () =
  let expected =
    Golden.read_lower_hex_file (golden_path "v1/restore-proof-v1.cbor.hex")
    |> require_ok Fun.id
  in
  let actual = Proof.encode (proof ()) |> require_ok Proof.error_to_string in
  Alcotest.(check string) "proof bytes" expected actual;
  let decoded = Proof.decode expected |> require_ok Proof.error_to_string in
  Alcotest.(check string)
    "proof round trips canonically" expected
    (Proof.encode decoded |> require_ok Proof.error_to_string)

let proof_rejects_noncanonical_and_unknown_schema () =
  let bytes = Proof.encode (proof ()) |> require_ok Proof.error_to_string in
  let noncanonical = "\x9f" ^ String.sub bytes 1 (String.length bytes - 1) in
  (match Proof.decode noncanonical with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "accepted an indefinite noncanonical record");
  if Result.is_ok (Proof.decode "\x84\x02\x60\x60\x60") then
    Alcotest.fail "accepted an unknown proof schema"

let append_is_idempotent_and_forget_is_explicit () =
  with_root (fun root ->
      Proof.append ~root (proof ()) |> require_ok Proof.error_to_string;
      Proof.append ~root (proof ()) |> require_ok Proof.error_to_string;
      Alcotest.(check int)
        "one proof" 1
        (Proof.scan ~root |> require_ok Proof.error_to_string |> List.length);
      Proof.forget ~root ~operation_id:(String.make 64 'a')
      |> require_ok Proof.error_to_string;
      Alcotest.(check int)
        "explicit forget removes the root" 0
        (Proof.scan ~root |> require_ok Proof.error_to_string |> List.length))

let () =
  Alcotest.run "V1 restore proof"
    [
      ( "record",
        [
          Alcotest.test_case "canonical golden bytes" `Quick
            proof_has_stable_canonical_bytes;
          Alcotest.test_case "rejects malformed record" `Quick
            proof_rejects_noncanonical_and_unknown_schema;
          Alcotest.test_case "append and explicit forget" `Quick
            append_is_idempotent_and_forget_is_explicit;
        ] );
    ]
