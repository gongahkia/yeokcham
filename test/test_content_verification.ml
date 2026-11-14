module S = Yeokcham_snapshot
module Store = Yeokcham_store

let ok render = function Ok v -> v | Error e -> Alcotest.fail (render e)
let snapshot r = ok S.error_to_string r

let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter (fun n -> remove (Filename.concat path n)) (Sys.readdir path);
      Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK | Unix.S_CHR
  | Unix.S_BLK ->
      Unix.unlink path

let with_store f =
  let root = Filename.temp_file "yeokcham-content-check-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove root)
    (fun () -> f (Store.init ~root |> ok Store.error_to_string))

let bytes length =
  String.init length (fun i -> Char.chr (((i * 17) + (i / 256)) mod 256))

let content_identity value =
  S.Content.identity_of_bytes value |> S.Content.identity_to_raw_bytes

let as_content id =
  S.Content.of_stored_object_id (S.Manifest.stored_object_id id)

let as_manifest id =
  S.Manifest.of_stored_object_id (S.Content.stored_object_id id)

let display_bounds_are_exact_and_read_only () =
  with_store (fun store ->
      List.iter
        (fun length ->
          let value = bytes length in
          let id = S.Content.store store value |> snapshot in
          let before =
            Store.list_objects store |> ok Store.error_to_string |> List.length
          in
          S.Content.verify store id |> snapshot;
          Alcotest.(check (option string))
            "within limit returns exact bytes" (Some value)
            (S.Content.load_bounded store ~max_bytes:length id |> snapshot);
          if length > 0 then
            Alcotest.(check (option string))
              "beyond limit is explicit" None
              (S.Content.load_bounded store ~max_bytes:(length - 1) id
              |> snapshot);
          let after =
            Store.list_objects store |> ok Store.error_to_string |> List.length
          in
          Alcotest.(check int) "verification adds no objects" before after)
        [ 0; 1; 65536; 65537; (1024 * 1024) + 13 ])

let[@warning "-4"] noncanonical_boundaries_refuse () =
  with_store (fun store ->
      let value = bytes 200000 in
      let first = String.sub value 0 1
      and rest = String.sub value 1 (String.length value - 1) in
      let refs =
        List.map
          (fun value ->
            (S.Chunk.store store value |> snapshot, String.length value))
          [ first; rest ]
      in
      let manifest =
        S.Manifest.store_chunks store ~total_length:(String.length value)
          ~full_content_id:(content_identity value) refs
        |> snapshot
      in
      match S.Content.load_bounded store ~max_bytes:0 (as_content manifest) with
      | Error S.Noncanonical_chunk_boundaries -> ()
      | Error e -> Alcotest.fail (S.error_to_string e)
      | Ok _ -> Alcotest.fail "display limit hid noncanonical chunk boundaries")

let[@warning "-4"] incorrect_full_identity_refuses () =
  with_store (fun store ->
      let value = bytes 200000 in
      let content = S.Content.store store value |> snapshot in
      let manifest = S.Manifest.load store (as_manifest content) |> snapshot in
      let forged =
        S.Manifest.store_chunks store ~total_length:(String.length value)
          ~full_content_id:(String.make 32 'z')
          (S.Manifest.chunks manifest)
        |> snapshot
      in
      match S.Content.load_bounded store ~max_bytes:0 (as_content forged) with
      | Error S.Manifest_content_identity_mismatch -> ()
      | Error e -> Alcotest.fail (S.error_to_string e)
      | Ok _ ->
          Alcotest.fail "opaque result hid incorrect full-content identity")

let[@warning "-4"] declared_lengths_refuse () =
  with_store (fun store ->
      let content = S.Content.store store (bytes 200000) |> snapshot in
      let manifest = S.Manifest.load store (as_manifest content) |> snapshot in
      let first, length = List.hd (S.Manifest.chunks manifest) in
      let references =
        (first, length + 1) :: List.tl (S.Manifest.chunks manifest)
      in
      let forged =
        S.Manifest.store_chunks store
          ~total_length:(S.Manifest.total_length manifest + 1)
          ~full_content_id:(content_identity (bytes 200000))
          references
        |> snapshot
      in
      match S.Content.verify store (as_content forged) with
      | Error (S.Manifest_length_mismatch _) -> ()
      | Error e -> Alcotest.fail (S.error_to_string e)
      | Ok () -> Alcotest.fail "incorrect chunk length verified")

let missing_chunk_is_unavailable () =
  with_store (fun store ->
      let id = S.Content.store store (bytes 200000) |> snapshot in
      let manifest = S.Manifest.load store (as_manifest id) |> snapshot in
      let chunk, _ = List.hd (S.Manifest.chunks manifest) in
      Unix.unlink (Store.object_path store (S.Chunk.stored_object_id chunk));
      List.iter
        (fun result ->
          match result with
          | Error _ -> ()
          | Ok _ -> Alcotest.fail "missing bytes labelled available")
        [
          S.Content.verify store id;
          S.Content.load_bounded store ~max_bytes:0 id
          |> Result.map (fun _ -> ());
        ])

let () =
  Alcotest.run "Streaming content verification"
    [
      ( "closure",
        [
          Alcotest.test_case "bounded exact reads and no writes" `Quick
            display_bounds_are_exact_and_read_only;
          Alcotest.test_case "noncanonical chunk boundaries refuse" `Quick
            noncanonical_boundaries_refuse;
          Alcotest.test_case
            "full-content identity checked beyond display bound" `Quick
            incorrect_full_identity_refuses;
          Alcotest.test_case "declared chunk length checked" `Quick
            declared_lengths_refuse;
          Alcotest.test_case "missing chunk is unavailable" `Quick
            missing_chunk_is_unavailable;
        ] );
    ]
