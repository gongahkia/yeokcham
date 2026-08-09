module Cutover = Yeokcham_cutover
module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Golden = Yeokcham_testkit.Golden_fixture
module Store = Yeokcham_store

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

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
  let root = Filename.temp_file "yeokcham-cutover-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let read_file path = In_channel.with_open_bin path In_channel.input_all
let metadata_path root = Filename.concat root ".yeokcham"

let create_legacy_root root =
  let metadata = metadata_path root in
  Unix.mkdir metadata 0o700;
  List.iter
    (fun name -> Unix.mkdir (Filename.concat metadata name) 0o700)
    [ "objects"; "refs"; "locks" ];
  write_file (Filename.concat metadata "format") Store.repository_format;
  metadata

let content_envelope bytes =
  Envelope.create ~object_type:Envelope.Content
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features
    ~payload:(Encoding.bytes bytes) ()
  |> require_ok Envelope.creation_error_to_string

let create_hybrid_legacy root =
  let store = Store.init ~root |> require_ok Store.error_to_string in
  let object_id =
    Store.put store (content_envelope "legacy object bytes")
    |> require_ok Store.error_to_string
  in
  ignore
    (Store.compare_and_swap_ref store ~name:"scratch-head" ~expected:None
       ~target:(Some object_id)
    |> require_ok Store.error_to_string)

let classification_is expected actual =
  Alcotest.(check string)
    "classification"
    (Cutover.classification_to_string expected)
    (Cutover.classification_to_string actual)

let classifications_are_explicit () =
  with_root (fun root ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      Cutover.detect ~root
      |> require_ok Cutover.error_to_string
      |> classification_is Cutover.V2);
  with_root (fun root ->
      create_hybrid_legacy root;
      Cutover.detect ~root
      |> require_ok Cutover.error_to_string
      |> classification_is Cutover.Legacy);
  with_root (fun root ->
      let metadata = create_legacy_root root in
      Unix.symlink "outside" (Filename.concat metadata "unsafe-link");
      let classification =
        Cutover.detect ~root |> require_ok Cutover.error_to_string
      in
      Alcotest.(check bool)
        "symlink root is mixed or unknown" true
        (String.starts_with ~prefix:"mixed or unknown:"
           (Cutover.classification_to_string classification)));
  with_root (fun root ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      Unix.rmdir (Filename.concat (metadata_path root) "journal");
      let classification =
        Cutover.detect ~root |> require_ok Cutover.error_to_string
      in
      Alcotest.(check bool)
        "incomplete root is explicit" true
        (String.starts_with ~prefix:"incomplete:"
           (Cutover.classification_to_string classification)))

type tree_entry = Directory of string * int | File of string * int * string

let tree_entries root initial =
  let rec collect path relative =
    let stat = Unix.lstat path in
    match stat.Unix.st_kind with
    | Unix.S_DIR ->
        let own =
          if String.is_empty relative then []
          else [ Directory (relative, stat.Unix.st_perm land 0o7777) ]
        in
        let children =
          Sys.readdir path |> Array.to_list |> List.sort String.compare
          |> List.concat_map (fun name ->
              let child =
                if String.is_empty relative then name else relative ^ "/" ^ name
              in
              collect (Filename.concat path name) child)
        in
        own @ children
    | Unix.S_REG ->
        [ File (relative, stat.Unix.st_perm land 0o7777, read_file path) ]
    | Unix.S_LNK -> Alcotest.fail ("unexpected symlink in snapshot: " ^ path)
    | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
        Alcotest.fail ("unexpected special node in snapshot: " ^ path)
  in
  collect (Filename.concat root initial) ""

let archived_tree_is_byte_and_mode_preserving () =
  with_root (fun root ->
      create_hybrid_legacy root;
      let legacy_before = tree_entries root ".yeokcham" in
      let outcome =
        Cutover.archive ~root ~archive_name:"legacy-before-v2"
        |> require_ok Cutover.error_to_string
      in
      let manifest_path =
        match outcome with
        | Cutover.Archived result -> result.Cutover.manifest_path
        | Cutover.Already_archived _ ->
            Alcotest.fail "new archive was reported as already archived"
      in
      let golden =
        Golden.read_lower_hex_file "golden/legacy-archive-manifest-v1.cbor.hex"
        |> require_ok Fun.id
      in
      Alcotest.(check string)
        "canonical archive manifest golden" golden (read_file manifest_path);
      Alcotest.(check bool)
        "archive preserves bytes and modes" true
        (legacy_before = tree_entries root "legacy-before-v2");
      Alcotest.(check bool)
        "legacy metadata is relocated" false
        (Sys.file_exists (metadata_path root));
      let unconfirmed =
        Cutover.reset ~root ~archive_name:"legacy-before-v2" ~confirm:false
      in
      Alcotest.(check string)
        "reset requires confirmation"
        (Cutover.error_to_string Cutover.Confirmation_required)
        (match unconfirmed with
        | Ok _ -> "unexpected reset success"
        | Error error -> Cutover.error_to_string error);
      Alcotest.(check bool)
        "unconfirmed reset leaves no V2 root" false
        (Sys.file_exists (metadata_path root));
      let reset =
        Cutover.reset ~root ~archive_name:"legacy-before-v2" ~confirm:true
        |> require_ok Cutover.error_to_string
      in
      Alcotest.(check bool)
        "reset result" true
        (match reset with
        | Cutover.Reset -> true
        | Cutover.Already_reset -> false);
      Cutover.detect ~root
      |> require_ok Cutover.error_to_string
      |> classification_is Cutover.V2;
      Alcotest.(check bool)
        "reset keeps archive untouched" true
        (legacy_before = tree_entries root "legacy-before-v2");
      let repeated =
        Cutover.reset ~root ~archive_name:"legacy-before-v2" ~confirm:true
        |> require_ok Cutover.error_to_string
      in
      Alcotest.(check bool)
        "repeated reset is idempotent" true
        (match repeated with
        | Cutover.Reset -> false
        | Cutover.Already_reset -> true))

let tampered_archive_cannot_reset () =
  with_root (fun root ->
      create_hybrid_legacy root;
      ignore
        (Cutover.archive ~root ~archive_name:"legacy-tampered"
        |> require_ok Cutover.error_to_string);
      write_file (Filename.concat root "legacy-tampered/format") "tampered";
      match
        Cutover.reset ~root ~archive_name:"legacy-tampered" ~confirm:true
      with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "tampered archive was accepted for reset");
  with_root (fun root ->
      create_legacy_root root |> ignore;
      Unix.mkdir (Filename.concat root "v1-archive") 0o700;
      let outcome = Cutover.archive ~root ~archive_name:"v1-archive" in
      Alcotest.(check bool)
        "archive does not overwrite existing sibling" true
        (match outcome with
        | Ok _ -> false
        | Error error ->
            String.starts_with ~prefix:"archive already exists:"
              (Cutover.error_to_string error)))

let default_seed = 20_260_809

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | None -> default_seed
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed

let stable_seed name =
  let value = ref base_seed in
  String.iter
    (fun character ->
      value := !value * 65599 lxor Char.code character land max_int)
    name;
  !value

let state_for name = Random.State.make [| stable_seed name |]

let safe_legacy_trees_are_preserved =
  QCheck2.Test.make ~count:80
    ~name:"generated legacy trees archive with exact bytes and modes"
    QCheck2.Gen.(list_size (0 -- 8) (string_size (0 -- 2048)))
    (fun contents ->
      with_root (fun root ->
          let metadata = create_legacy_root root in
          List.iteri
            (fun index content ->
              let path =
                Filename.concat
                  (Filename.concat metadata "locks")
                  (Printf.sprintf "entry-%d" index)
              in
              write_file path content;
              Unix.chmod path (if index mod 2 = 0 then 0o600 else 0o755))
            contents;
          let before = tree_entries root ".yeokcham" in
          match Cutover.archive ~root ~archive_name:"generated-archive" with
          | Error _ -> false
          | Ok _ -> before = tree_entries root "generated-archive"))

let () =
  Alcotest.run "V1 archive and V2 cutover"
    [
      ( "unit",
        [
          Alcotest.test_case "classification is explicit and fail-closed" `Quick
            classifications_are_explicit;
          Alcotest.test_case "archive preserves bytes and modes before reset"
            `Quick archived_tree_is_byte_and_mode_preserving;
          Alcotest.test_case "tampering and overwrite attempts reject" `Quick
            tampered_archive_cannot_reset;
        ] );
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "safe-legacy-trees")
            safe_legacy_trees_are_preserved;
        ] );
    ]
