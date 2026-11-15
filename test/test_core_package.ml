module Package = Yeokcham_v1_package
module P = Package.Core
module S = Yeokcham_v1_store
module L = S.Local
module C = Yeokcham_v1_model.Core
module M = Yeokcham_v1_model
module T = Yeokcham_v1_trust
module R = Yeokcham_v1_record.Core
module Raw = Yeokcham_store
module Snapshot = Yeokcham_snapshot
module Service = Yeokcham_v1_local_service
module Composition = Yeokcham_v1_composition
module Pages = Yeokcham_v1_pages
module E = Yeokcham_encoding
module Envelope = Yeokcham_envelope

[@@@warning "-42"]

let ok render = function Ok value -> value | Error error -> Alcotest.fail (render error)
let package result = ok Package.error_to_string result
let model result = ok C.error_to_string result
let service result = ok Service.error_to_string result
let reject = function Error _ -> () | Ok _ -> Alcotest.fail "accepted invalid public package"
let read path = In_channel.with_open_bin path In_channel.input_all
let write path bytes = Out_channel.with_open_bin path (fun out -> output_string out bytes)
let contains bytes part =
  let rec loop i = i+String.length part<=String.length bytes &&
    (String.sub bytes i (String.length part)=part || loop (i+1)) in loop 0

let rec remove path =
  if (Unix.lstat path).Unix.st_kind=Unix.S_DIR then (
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path)
  else Unix.unlink path

let temporary f =
  let parent=Filename.temp_file "yeokcham-core-package-" "" in
  Unix.unlink parent; Unix.mkdir parent 0o700;
  Fun.protect ~finally:(fun () -> remove parent) (fun () -> f parent)

let initialize root key =
  Unix.mkdir root 0o700;
  write (root ^ "/private.txt") "PRIVATE SENTINEL DO NOT EXPORT\000\255";
  write (root ^ "/note.txt") "initial private note\n";
  let capability=T.signing_capability_of_private_key (String.make 32 key) |> ok T.error_to_string in
  let device=T.device_of_public_key (T.signing_public_key capability) |> ok T.error_to_string in
  let repo=T.Repository_id.of_string (String.make 64 'a') |> ok Fun.id in
  let certificate=T.root_certificate ~repository:repo ~device capability |> ok T.error_to_string in
  let membership=T.verify_membership ~repository:repo [certificate] |> ok T.error_to_string in
  let recovery=T.signing_capability_of_private_key (String.make 32 'r') |> ok T.error_to_string in
  let recovery_device=T.device_of_public_key (T.signing_public_key recovery) |> ok T.error_to_string in
  let epoch=T.root_epoch ~membership ~root_certificate:(T.certificate_id certificate)
    ~recovery_device capability |> ok T.error_to_string in
  let authority=T.verify_authority ~membership [epoch] |> ok T.error_to_string in
  let collaboration=S.collaboration_with_authority ~authority ~revisions:[]
    ~local_certificate:(T.certificate_id certificate) ~authorizations:[] ~adoptions:[] |> ok S.error_to_string in
  let repository=S.init_local_collaborative_with ~root ~bootstrap:(fun store ->
    let local=L.initialize ~store ~authority ~certificate:(T.certificate_id certificate)
      ~signing_capability:capability ~cursor:0L |> ok Fun.id in
    let snapshot text=M.Snapshot_id.of_string text |> ok M.error_to_string in
    let captured,_=Snapshot.scan ~root ~store |> ok Snapshot.error_to_string in
    let captured=Snapshot.Snapshot.stored_object_id captured |> Raw.Stored_object_id.to_hex |> snapshot in
    let project=M.init ~creator:(T.device_id device)
      ~username:(M.Username.of_string "alice" |> ok M.error_to_string)
      ~initial_snapshot:(snapshot (C.Object_id.to_hex (L.empty_snapshot local)))
      ~initial_draft:(M.Draft_id.of_string "work" |> ok M.error_to_string) ~title:"private" in
    Ok (M.checkpoint project ~snapshot:captured,collaboration,local)) |> ok S.error_to_string in
  repository,capability,authority

let load repository=S.load repository |> ok S.error_to_string
let local loaded=Option.get loaded.S.local

let share root capability paths =
  Service.share_selected ~root ~paths ~update:None ~title:(Some "Public selected D")
    ~dry_run:false ~signing_capability:(Some capability) |> service

let create repository authority destination =
  let loaded=load repository in
  let local=local loaded in
  P.create ~source:(S.underlying_store repository) ~destination ~authority
    ~records:(L.record_objects local) ~selected_branch:(L.selected local).L.branch
    ~titles:(List.map (fun receipt -> receipt.L.revision,receipt.L.title) (L.publications local))
  |> package

let copy_object source destination id =
  let bytes=Raw.get source id |> ok Raw.error_to_string |> Envelope.encode in
  write (destination ^ "/objects/" ^ Raw.Stored_object_id.to_hex id) bytes

let[@warning "-4"] public_closure_preserves_d_e_and_mixed_fidelity () =
  temporary (fun parent ->
    let root=parent ^ "/alice" in
    let repository,capability,authority=initialize root 'k' in
    write (root ^ "/note.txt") "shared D\r\n";
    write (root ^ "/opaque.bin") (String.init (2*1024*1024+731) (fun i -> Char.chr (i mod 256)));
    write (root ^ "/run") "#!/bin/sh\nexit 0\n"; Unix.chmod (root ^ "/run") 0o755;
    Unix.mkdir (root ^ "/empty") 0o700;
    Unix.symlink "note.txt" (root ^ "/link");
    let shared=share root capability [["note.txt"];["opaque.bin"];["run"];["empty"];["link"]] in
    write (root ^ "/note.txt") "shared D\r\nprivate later E\n";
    let plan=Service.Integrate.prepare ~root
      ~selected_revisions:[Option.get shared.Service.Share.revision] ~reconcile_heads:None
      |> ok Service.Integrate.error_to_string in
    let applied=Service.Integrate.apply ~root ~plan:(Yeokcham_v1_integration.id plan)
      ~signing_capability:(Some capability) |> ok Service.Integrate.error_to_string in
    let operation=Option.get applied.Service.Integrate.operation in
    let before=load repository in
    let destination=parent ^ "/public-package" in
    let artifact=create repository authority destination in
    Alcotest.(check bool) "export does not move any state/history root" true
      (Raw.Mutable_ref.equal before.S.head (load repository).S.head);
    Alcotest.(check string) "later private E remains live" "shared D\r\nprivate later E\n" (read (root ^ "/note.txt"));
    let ids=ref [] in
    Package.iter_artifact_objects artifact ~f:(fun id bytes ->
      ids:=id::!ids;
      Alcotest.(check bool) "private sentinel absent from every exported object" false
        (contains bytes "PRIVATE SENTINEL DO NOT EXPORT");
      Alcotest.(check bool) "private E absent from every exported object" false
        (contains bytes "private later E"); Ok ()) |> package;
    let private_ids=operation.L.Operation.plan_object ::
      List.map (fun receipt -> receipt.L.witness_root) (L.publications (local before)) in
    List.iter (fun id -> Alcotest.(check bool) "private plans/correspondence pages excluded" false
      (List.exists (Raw.Stored_object_id.equal id) !ids)) private_ids;
    let scope=C.pool_repository (L.pool (local before)) in
    let prepared=P.prepare ~package:destination ~repository:scope ~known_authority:(Some authority) |> package in
    Alcotest.(check int) "all public records included, not private operation rows"
      (List.length (L.record_objects (local before))) (List.length (P.prepared_records prepared));
    Alcotest.(check (list string)) "public courier title survives"
      ["Public selected D"] (List.map snd (P.prepared_titles prepared));
    let target=parent ^ "/bob-objects" in Unix.mkdir target 0o700;
    write (target ^ "/unsaved.txt") "BOB PRIVATE WORK";
    let store=Raw.init ~root:target |> ok Raw.error_to_string in
    P.import_prepared ~destination:store prepared |> package;
    Alcotest.(check string) "immutable receipt never edits ordinary files" "BOB PRIVATE WORK" (read (target ^ "/unsaved.txt"));
    Alcotest.(check bool) "immutable receipt does not create a project head" false
      (Sys.file_exists (target ^ "/.yeokcham/refs/v1-project-state"));
    let accepted=Composition.Graph.accepted (P.prepared_pool prepared) operation.L.Operation.accepted
      |> ok Composition.Graph.error_to_string in
    let tree=Composition.load store accepted.C.result_snapshot |> ok Composition.error_to_string in
    let entries=Composition.entries tree in
    let content name=match List.assoc [name] entries with
      | Composition.File {content;_} -> Snapshot.Content.load store content |> ok Snapshot.error_to_string
      | Composition.Directory -> Alcotest.fail "expected file" in
    Alcotest.(check string) "accepted public result is exact D" "shared D\r\n" (content "note.txt");
    Alcotest.(check string) "opaque bytes retained" (read (root ^ "/opaque.bin")) (content "opaque.bin");
    Alcotest.(check bool) "empty directory retained" true (List.assoc ["empty"] entries=Composition.Directory);
    Alcotest.(check bool) "executable distinction retained" true
      (match List.assoc ["run"] entries with Composition.File {mode=Snapshot.Executable;_}->true|_->false);
    Alcotest.(check bool) "symlink target/mode retained" true
      (match List.assoc ["link"] entries with Composition.File {mode=Snapshot.Symlink;_}->content "link"="note.txt"|_->false))

let[@warning "-4"] reject_extra_private_object_even_in_canonical_inventory () =
  temporary (fun parent ->
    let root=parent ^ "/alice" in
    let repository,capability,authority=initialize root 'k' in
    write (root ^ "/note.txt") "shared D\n"; share root capability [["note.txt"]] |> ignore;
    let directory=parent ^ "/package" in
    let artifact=create repository authority directory in
    let loaded=load repository in let state=local loaded in let store=S.underlying_store repository in
    let repository_id=C.pool_repository (L.pool state) in
    let manifest=P.decode_manifest ~repository:repository_id (Package.artifact_manifest artifact) |> package in
    let namespace,old_inventory=List.hd (List.rev (P.metadata_roots manifest)) in
    let snapshot=(Yeokcham_v1_undo.current loaded.S.history).Yeokcham_v1_undo.snapshot in
    let tree=Composition.load store (C.Object_id.of_hex (M.Snapshot_id.to_string snapshot) |> model) |> ok Composition.error_to_string in
    let private_id=match List.assoc ["private.txt"] (Composition.entries tree) with
      | Composition.File {content;_}->Snapshot.Content.stored_object_id content
      | Composition.Directory -> assert false in
    let private_bytes=Raw.get store private_id |> ok Raw.error_to_string |> Envelope.encode in
    let inventory=P.inventory store manifest |> package in
    let rows=List.map (fun (id,size) -> Raw.Stored_object_id.to_raw_bytes id,E.encode (E.integer (Int64.of_int size)))
      ((private_id,String.length private_bytes)::inventory) in
    let new_inventory=Pages.store store ~namespace rows |> ok Pages.error_to_string in
    Pages.closure store ~namespace old_inventory |> ok Pages.error_to_string
      |> List.iter (fun id -> Unix.unlink (directory ^ "/objects/" ^ Raw.Stored_object_id.to_hex id));
    Pages.closure store ~namespace new_inventory |> ok Pages.error_to_string |> List.iter (copy_object store directory);
    copy_object store directory private_id;
    let fields=E.decode (Package.artifact_manifest artifact) |> ok E.decode_error_to_string |> function E.Array fields->fields|_->assert false in
    let altered=E.array (List.mapi (fun index value -> if index=6 then E.bytes (Raw.Stored_object_id.to_raw_bytes new_inventory) else value) fields)
      |> ok E.construction_error_to_string |> E.encode in
    write (directory ^ "/manifest.cbor") altered;
    (match P.prepare ~package:directory ~repository:repository_id ~known_authority:(Some authority) with
    | Error (Package.Invalid_package detail) -> Alcotest.(check bool) "rejects semantic extra closure after structural verification" true
        (contains detail "exact public dependency closure")
    | Error error -> Alcotest.fail (Package.error_to_string error)
    | Ok _ -> Alcotest.fail "private blob accepted as public inventory"))

let signed_false_result_and_foreign_authority_refuse () =
  temporary (fun parent ->
    let root=parent ^ "/alice" in
    let repository,capability,authority=initialize root 'k' in
    let shared=share root capability [["note.txt"]] in
    let loaded=load repository in let local=local loaded in let store=S.underlying_store repository in
    let certificate=T.certificate_id (List.hd (T.certificates (T.authority_membership authority))) in
    let digest text=C.Digest.of_hex text |> model in
    let context=C.make_context ~repository:(C.pool_repository (L.pool local))
      ~author_certificate:(digest certificate) ~authority_heads:(List.map digest (T.authority_heads authority)) ~display_time:None |> model in
    let result=(Yeokcham_v1_undo.current loaded.S.history).Yeokcham_v1_undo.snapshot |> M.Snapshot_id.to_string |> C.Object_id.of_hex |> model in
    let version=C.make_accepted_version ~branch:(L.selected local).L.branch
      ~accepted_parents:[(L.selected local).L.basis] ~chosen_revisions:[Option.get shared.Service.Share.revision]
      ~resolutions:[] ~result_snapshot:result ~composition_profile:"line-hunks-v1" ~policy_heads:[] ~review_evidence:[] |> model in
    let signed=T.Core.sign authority capability (C.make_body ~context ~payload:(C.Accepted_version version)) |> ok T.Core.error_to_string in
    let id=R.id signed |> ok R.error_to_string in
    let object_id=R.encode signed |> ok R.error_to_string |> Envelope.decode |> ok Envelope.decode_error_to_string |> Raw.put store |> ok Raw.error_to_string in
    let destination=parent ^ "/invalid" in
    reject (P.create ~source:store ~destination ~authority
      ~records:((id,object_id)::L.record_objects local) ~selected_branch:(L.selected local).L.branch ~titles:[]);
    Alcotest.(check bool) "false accepted result never creates artifact" false (Sys.file_exists destination);
    let other_repository,_,other_authority=initialize (parent ^ "/other-root") 'b' in
    let other_dir=parent ^ "/other-package" in create other_repository other_authority other_dir |> ignore;
    reject (P.prepare ~package:other_dir ~repository:(C.pool_repository (L.pool local)) ~known_authority:(Some authority)))

let[@warning "-4"] malformed_controls_and_missing_objects_refuse () =
  temporary (fun parent ->
    let root=parent ^ "/alice" in
    let repository,_,authority=initialize root 'k' in
    let directory=parent ^ "/package" in let artifact=create repository authority directory in
    let scope=C.pool_repository (L.pool (local (load repository))) in
    reject (P.decode_manifest ~repository:(C.Repository_id.of_raw (String.make 32 'b') |> model) (Package.artifact_manifest artifact));
    let fields=E.decode (Package.artifact_manifest artifact) |> ok E.decode_error_to_string |> function E.Array fields->fields|_->assert false in
    List.iter (fun (index,value) ->
      let bytes=E.array (List.mapi (fun at old -> if at=index then value else old) fields) |> ok E.construction_error_to_string |> E.encode in
      reject (P.decode_manifest ~repository:scope bytes)) [0,E.integer 99L;2,E.bytes "short";3,E.bytes "short"];
    reject (P.decode_manifest ~repository:scope (String.make (P.max_manifest_bytes+1) 'x'));
    let object_file=Array.get (Sys.readdir (directory ^ "/objects")) 0 in
    Unix.unlink (directory ^ "/objects/" ^ object_file);
    reject (P.prepare ~package:directory ~repository:scope ~known_authority:(Some authority)))

let () =
  Alcotest.run "Core public package" ["public",[
    Alcotest.test_case "public closure preserves D/E privacy and mixed fidelity" `Quick public_closure_preserves_d_e_and_mixed_fidelity;
    Alcotest.test_case "canonical inventory cannot smuggle a private blob" `Quick reject_extra_private_object_even_in_canonical_inventory;
    Alcotest.test_case "signed false results and foreign roots refuse" `Quick signed_false_result_and_foreign_authority_refuse;
    Alcotest.test_case "malformed controls and missing closure refuse" `Quick malformed_controls_and_missing_objects_refuse]]
