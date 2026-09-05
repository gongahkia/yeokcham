module Config = Yeokcham_v1_relay_config

let require_ok = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Config.error_to_string error)

let golden_path name =
  let local = Filename.concat "golden" name in
  if Sys.file_exists local then local else Filename.concat "test/golden" name

let read_golden name =
  In_channel.with_open_bin (golden_path name) In_channel.input_all

let canonical_fixture_round_trips () =
  let encoded = read_golden "v1/relay-config-v1.conf" in
  let config = Config.decode encoded |> require_ok in
  Alcotest.(check string)
    "config golden bytes are canonical" encoded (Config.encode config);
  Alcotest.(check string)
    "storage root is explicit" "/var/lib/yeokcham-relay"
    (Config.storage_root config);
  Alcotest.(check int)
    "V2 temporary-byte quota is explicit"
    (256 * 1024 * 1024)
    (Config.project_quota_bytes config);
  Alcotest.(check int)
    "V2 session expiry is explicit" 900
    (Config.session_expiry_seconds config)

let config_refuses_noncanonical_unknown_duplicate_and_invalid_values () =
  let encoded = read_golden "v1/relay-config-v1.conf" in
  let unknown = encoded ^ "unexpected=value\n" in
  Alcotest.(check bool)
    "unknown config key is refused" true
    (Result.is_error (Config.decode unknown));
  let duplicate = encoded ^ "log_level=debug\n" in
  Alcotest.(check bool)
    "duplicate config key is refused" true
    (Result.is_error (Config.decode duplicate));
  let reordered =
    String.concat ""
      [
        "version=1\n";
        "listen=127.0.0.1:8080\n";
        "storage_root=/var/lib/yeokcham-relay\n";
        "health_listen=127.0.0.1:8081\n";
        "metrics_listen=127.0.0.1:9090\n";
        "credential_registry_root=/var/lib/yeokcham-relay\n";
        "project_quota_bytes=268435456\n";
        "session_expiry_seconds=900\n";
        "log_level=info\n";
      ]
  in
  Alcotest.(check bool)
    "reordered config is refused" true
    (Result.is_error (Config.decode reordered));
  let invalid_listen =
    String.concat ""
      [
        "version=1\n";
        "storage_root=/var/lib/yeokcham-relay\n";
        "listen=0.0.0.0:0\n";
        "health_listen=127.0.0.1:8081\n";
        "metrics_listen=127.0.0.1:9090\n";
        "credential_registry_root=/var/lib/yeokcham-relay\n";
        "project_quota_bytes=268435456\n";
        "session_expiry_seconds=900\n";
        "log_level=info\n";
      ]
  in
  Alcotest.(check bool)
    "invalid listener is refused" true
    (Result.is_error (Config.decode invalid_listen));
  Alcotest.(check bool)
    "unsafe root is refused" true
    (Result.is_error
       (Config.create ~storage_root:"/var/lib/../source"
          ~listen:"127.0.0.1:8080" ~health_listen:"127.0.0.1:8081"
          ~metrics_listen:"127.0.0.1:9090"
          ~credential_registry_root:"/var/lib/relay" ~project_quota_bytes:1
          ~session_expiry_seconds:1 ~log_level:Config.Info))

let environment_overrides_are_whitelisted_and_revalidated () =
  let overridden =
    Config.override_environment Config.default
      [
        ("PATH", "/usr/bin");
        ("YEOKCHAM_RELAY_LISTEN", "127.0.0.1:8180");
        ("YEOKCHAM_RELAY_LOG_LEVEL", "debug");
      ]
    |> require_ok
  in
  Alcotest.(check string)
    "documented environment override changes listener" "127.0.0.1:8180"
    (Config.listen overridden);
  Alcotest.(check string)
    "environment override canonicalizes log level" "log_level=debug"
    (Config.encode overridden |> String.split_on_char '\n'
    |> List.find_opt (String.starts_with ~prefix:"log_level=")
    |> Option.value ~default:"");
  Alcotest.(check bool)
    "unknown relay-prefixed setting is refused" true
    (Result.is_error
       (Config.override_environment Config.default
          [ ("YEOKCHAM_RELAY_TOKEN", "must-not-exist") ]));
  Alcotest.(check bool)
    "duplicate override is refused" true
    (Result.is_error
       (Config.override_environment Config.default
          [
            ("YEOKCHAM_RELAY_LISTEN", "127.0.0.1:8180");
            ("YEOKCHAM_RELAY_LISTEN", "127.0.0.1:8280");
          ]))

let canonical_encode_decode_property =
  QCheck2.Test.make ~name:"relay config encoding preserves validated values"
    ~count:100
    QCheck2.Gen.(int_range 1 1000)
    (fun suffix ->
      let base = 10_000 + (suffix * 3) in
      match
        Config.create
          ~storage_root:("/var/lib/relay-" ^ string_of_int suffix)
          ~credential_registry_root:("/var/lib/registry-" ^ string_of_int suffix)
          ~listen:("127.0.0.1:" ^ string_of_int base)
          ~health_listen:("127.0.0.1:" ^ string_of_int (base + 1))
          ~metrics_listen:("127.0.0.1:" ^ string_of_int (base + 2))
          ~project_quota_bytes:(suffix * 1024) ~session_expiry_seconds:suffix
          ~log_level:Config.Warn
      with
      | Error _ -> false
      | Ok config -> (
          match Config.decode (Config.encode config) with
          | Error _ -> false
          | Ok decoded ->
              String.equal (Config.encode config) (Config.encode decoded)))

let () =
  Alcotest.run "V1 relay config"
    [
      ( "records",
        [
          Alcotest.test_case "canonical fixture" `Quick
            canonical_fixture_round_trips;
          Alcotest.test_case "strict decode and invalid values" `Quick
            config_refuses_noncanonical_unknown_duplicate_and_invalid_values;
          Alcotest.test_case "environment overrides" `Quick
            environment_overrides_are_whitelisted_and_revalidated;
        ] );
      ( "properties",
        [ QCheck_alcotest.to_alcotest canonical_encode_decode_property ] );
    ]
