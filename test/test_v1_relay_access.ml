module Access = Yeokcham_v1_relay_access
module Golden = Yeokcham_testkit.Golden_fixture

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let repository =
  "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

let other_repository =
  "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"

let golden_path name =
  let local = Filename.concat "golden" name in
  if Sys.file_exists local then local else Filename.concat "test/golden" name

let read_golden name =
  Golden.read_lower_hex_file (golden_path name) |> require_ok Fun.id

let contains haystack needle =
  let haystack_length = String.length haystack in
  let needle_length = String.length needle in
  let rec loop offset =
    offset + needle_length <= haystack_length
    && (String.sub haystack offset needle_length = needle || loop (offset + 1))
  in
  needle_length = 0 || loop 0

let expect_authorization_error expected result =
  match result with
  | Error actual when actual = expected -> ()
  | Ok () | Error _ ->
      Alcotest.fail "relay access authorization had the wrong result"

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

let with_directory prefix run =
  let root = Filename.temp_file prefix "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let canonical_registry_fixture () =
  let encoded = read_golden "v1/relay-access-registry-v1.cbor.hex" in
  let registry = Access.decode encoded |> require_ok Access.error_to_string in
  Alcotest.(check string)
    "registry fixture re-encodes canonically" encoded
    (Access.encode registry |> require_ok Access.error_to_string);
  let credential =
    match Access.credentials registry with
    | [ credential ] -> credential
    | _ -> Alcotest.fail "registry fixture has the wrong credential count"
  in
  Alcotest.(check string)
    "fixture retains the verifier credential ID"
    "0506adefacad8ad70b9b0f3f92217bba0636a372ff1c188bc4445c1020c660ac"
    (Access.credential_id credential);
  Access.authorize ~now:1_999L
    ~secret:("v1ra1_" ^ String.make 64 '0')
    ~repository ~scope:Access.Read registry
  |> require_ok Access.authorization_error_to_string

let issue_rotate_revoke_and_scope () =
  let now = 1_000L in
  let registry, grant =
    Access.issue ~now ~repository
      ~scopes:[ Access.Read; Access.Write ]
      ~expires_in:100L Access.empty
    |> require_ok Access.error_to_string
  in
  let encoded = Access.encode registry |> require_ok Access.error_to_string in
  Alcotest.(check bool)
    "the registry stores no access secret" false
    (contains encoded grant.Access.grant_secret);
  Access.authorize ~now ~secret:grant.Access.grant_secret ~repository
    ~scope:Access.Read registry
  |> require_ok Access.authorization_error_to_string;
  Access.authorize ~now ~secret:grant.Access.grant_secret
    ~repository:other_repository ~scope:Access.Read registry
  |> expect_authorization_error Access.Wrong_repository;
  let registry, replacement =
    Access.rotate ~now:(Int64.add now 1L)
      ~credential_id:grant.Access.grant_credential_id ~expires_in:100L registry
    |> require_ok Access.error_to_string
  in
  Access.authorize ~now:(Int64.add now 2L) ~secret:grant.Access.grant_secret
    ~repository ~scope:Access.Write registry
  |> expect_authorization_error Access.Revoked_secret;
  Access.authorize ~now:(Int64.add now 2L)
    ~secret:replacement.Access.grant_secret ~repository ~scope:Access.Write
    registry
  |> require_ok Access.authorization_error_to_string;
  let registry =
    Access.revoke ~now:(Int64.add now 3L)
      ~credential_id:replacement.Access.grant_credential_id registry
    |> require_ok Access.error_to_string
  in
  Access.authorize ~now:(Int64.add now 4L)
    ~secret:replacement.Access.grant_secret ~repository ~scope:Access.Read
    registry
  |> expect_authorization_error Access.Revoked_secret

let expiry_and_scope_rejection () =
  let registry, grant =
    Access.issue ~now:1_000L ~repository ~scopes:[ Access.Read ] ~expires_in:10L
      Access.empty
    |> require_ok Access.error_to_string
  in
  Access.authorize ~now:1_005L ~secret:grant.Access.grant_secret ~repository
    ~scope:Access.Write registry
  |> expect_authorization_error Access.Insufficient_scope;
  Access.authorize ~now:1_010L ~secret:grant.Access.grant_secret ~repository
    ~scope:Access.Read registry
  |> expect_authorization_error Access.Expired_secret

let corrupt_persistent_registry_fails_closed () =
  with_directory "yeokcham-v1-relay-access-" (fun root ->
      let path = Filename.concat root ".relay-access-v1.cbor" in
      Out_channel.with_open_bin path (fun output -> output_string output "bad");
      Alcotest.(check bool)
        "corrupt registry was rejected" true
        (Result.is_error (Access.load ~root)))

let issue_encode_rotate_preserves_access_invariant =
  QCheck2.Test.make
    ~name:"issued access survives canonical serialization and rotation"
    ~count:100
    QCheck2.Gen.(pair bool (int_range 1 86_400))
    (fun (read_only, lifetime) ->
      let scopes =
        if read_only then [ Access.Read ] else [ Access.Read; Access.Write ]
      in
      let now = 1_000L in
      let lifetime = Int64.of_int lifetime in
      match
        Access.issue ~now ~repository ~scopes ~expires_in:lifetime Access.empty
      with
      | Error _ -> false
      | Ok (registry, grant) -> (
          match Access.encode registry with
          | Error _ -> false
          | Ok bytes -> (
              match Access.decode bytes with
              | Error _ -> false
              | Ok decoded -> (
                  match
                    Access.authorize ~now ~secret:grant.Access.grant_secret
                      ~repository ~scope:Access.Read decoded
                  with
                  | Error _ -> false
                  | Ok () -> (
                      match
                        Access.rotate ~now:(Int64.add now 1L)
                          ~credential_id:grant.Access.grant_credential_id
                          ~expires_in:lifetime decoded
                      with
                      | Error _ -> false
                      | Ok (rotated, replacement) ->
                          Access.authorize ~now:(Int64.add now 2L)
                            ~secret:grant.Access.grant_secret ~repository
                            ~scope:Access.Read rotated
                          = Error Access.Revoked_secret
                          && Access.authorize ~now:(Int64.add now 2L)
                               ~secret:replacement.Access.grant_secret
                               ~repository ~scope:Access.Read rotated
                             = Ok ()
                          && (read_only
                             || Access.authorize ~now
                                  ~secret:replacement.Access.grant_secret
                                  ~repository ~scope:Access.Write rotated
                                = Ok ()))))))

let () =
  Alcotest.run "V1 relay access"
    [
      ( "access",
        [
          Alcotest.test_case "registry golden is canonical" `Quick
            canonical_registry_fixture;
          Alcotest.test_case "scope, rotation, and revocation" `Quick
            issue_rotate_revoke_and_scope;
          Alcotest.test_case "expiry and scope rejection" `Quick
            expiry_and_scope_rejection;
          Alcotest.test_case "corrupt persistent registry fails closed" `Quick
            corrupt_persistent_registry_fails_closed;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            issue_encode_rotate_preserves_access_invariant;
        ] );
    ]
