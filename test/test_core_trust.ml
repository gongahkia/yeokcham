module M = Yeokcham_v1_model.Core
module R = Yeokcham_v1_record.Core
module T = Yeokcham_v1_trust

[@@@warning "-42"]

open M

let ok render = function Ok v -> v | Error e -> Alcotest.fail (render e)
let model result = ok M.error_to_string result
let record result = ok R.error_to_string result
let trust result = ok T.error_to_string result
let core_trust result = ok T.Core.error_to_string result
let rejects label = function Error _ -> () | Ok _ -> Alcotest.fail label
let d c = M.Digest.of_raw (String.make 32 c) |> model
let o c = M.Object_id.of_raw (String.make 32 c) |> model
let branch = M.Branch_id.of_raw (String.make 16 'm') |> model
let repository = M.Repository_id.of_raw (String.make 32 'q') |> model
let change = M.Change_id.of_raw (String.make 16 'c') |> model

let capability =
  T.signing_capability_of_private_key (String.make 32 'a') |> trust

let device = T.device_of_public_key (T.signing_public_key capability) |> trust

let authority_fixture () =
  let repo =
    T.Repository_id.of_string (M.Repository_id.to_hex repository)
    |> Result.get_ok
  in
  let root = T.root_certificate ~repository:repo ~device capability |> trust in
  let member_cap =
    T.signing_capability_of_private_key (String.make 32 'b') |> trust
  in
  let member =
    T.device_of_public_key (T.signing_public_key member_cap) |> trust
  in
  let membership = T.verify_membership ~repository:repo [ root ] |> trust in
  let member_cert =
    T.enroll membership ~issuer:(T.certificate_id root) capability
      ~subject:member ~role:T.Member
    |> trust
  in
  let membership =
    T.verify_membership ~repository:repo [ root; member_cert ] |> trust
  in
  let recovery =
    T.device_of_public_key
      (T.signing_public_key
         (T.signing_capability_of_private_key (String.make 32 'k') |> trust))
    |> trust
  in
  let epoch =
    T.root_epoch ~membership ~root_certificate:(T.certificate_id root)
      ~recovery_device:recovery capability
    |> trust
  in
  let authority = T.verify_authority ~membership [ epoch ] |> trust in
  (authority, root, member_cert, member_cap, recovery, epoch)

let context_for authority certificate heads =
  let _ = authority in
  M.make_context ~repository
    ~author_certificate:(M.Digest.of_hex (T.certificate_id certificate) |> model)
    ~authority_heads:(List.map (fun h -> M.Digest.of_hex h |> model) heads)
    ~display_time:None
  |> model

let initial_revision ?(previous = []) ?(dependencies = []) () =
  M.make_shared_revision ~change ~previous_revisions:previous
    ~base_snapshot:(o 'b') ~result_snapshot:(o 'r') ~edit_scope_root:(o 's')
    ~dependencies
  |> model
  |> fun v -> M.Shared_revision v

let trust_and_model () =
  let authority, root, _, _, _, epoch = authority_fixture () in
  let context = context_for authority root [ T.epoch_id epoch ] in
  let body = M.make_body ~context ~payload:(initial_revision ()) in
  let signed = T.Core.sign authority capability body |> core_trust in
  let bytes = R.encode signed |> record in
  let empty = M.empty_pool ~repository in
  let pool, insertion = T.Core.receive authority empty bytes |> core_trust in
  Alcotest.(check bool) "verified bytes reach model" true (insertion = M.Added);
  let id = R.id signed |> record in
  Alcotest.(check bool)
    "model contains exact immutable body" true
    (M.find pool id = Some body);
  let repeated, insertion = T.Core.receive authority pool bytes |> core_trust in
  Alcotest.(check bool)
    "same signed bytes are a no-op" true
    (insertion = M.Unchanged && repeated = pool);
  let next_body =
    M.make_body ~context ~payload:(initial_revision ~previous:[ id ] ())
  in
  let next =
    T.Core.sign authority capability next_body
    |> core_trust |> R.encode |> record
  in
  rejects "missing model ancestry despite valid signature"
    (T.Core.receive authority empty next);
  let pool, _ = T.Core.receive authority pool next |> core_trust in
  Alcotest.(check int)
    "causal successor retained" 2
    (List.length (M.records pool));
  let wrong_context =
    M.make_context ~repository ~author_certificate:(d '?')
      ~authority_heads:[ M.Digest.of_hex (T.epoch_id epoch) |> model ]
      ~display_time:None
    |> model
  in
  rejects "unknown author certificate"
    (T.Core.sign authority capability
       (M.make_body ~context:wrong_context ~payload:(initial_revision ())));
  let unknown_head =
    M.make_context ~repository ~author_certificate:context.author_certificate
      ~authority_heads:[ d '?' ]
      ~display_time:None
    |> model
  in
  rejects "unknown authority epoch"
    (T.Core.sign authority capability
       (M.make_body ~context:unknown_head ~payload:(initial_revision ())));
  let other_cap =
    T.signing_capability_of_private_key (String.make 32 'z') |> trust
  in
  rejects "wrong signing key" (T.Core.sign authority other_cap body);
  let denied =
    T.signing_capability_of_external_signer
      ~public_key:(T.signing_public_key capability) ~sign:(fun ~domain:_ _ ->
        Error "test refusal")
    |> trust
  in
  rejects "provider refusal cannot produce a core record"
    (T.Core.sign authority denied body);
  let invalid_signer =
    T.signing_capability_of_external_signer
      ~public_key:(T.signing_public_key capability) ~sign:(fun ~domain:_ _ ->
        Ok (String.make 64 '\000'))
    |> trust
  in
  rejects "provider signature is checked before returning a core record"
    (T.Core.sign authority invalid_signer body);
  let tampered =
    R.attach_signature next_body ~signature:(R.signature signed) |> record
  in
  rejects "changed body invalidates signature"
    (T.Core.receive authority empty (R.encode tampered |> record));
  let other_repo = M.Repository_id.of_raw (String.make 32 'x') |> model in
  rejects "cross-repository receipt"
    (T.Core.receive authority (M.empty_pool ~repository:other_repo) bytes);
  let version =
    M.make_accepted_version ~branch ~accepted_parents:[] ~chosen_revisions:[]
      ~resolutions:[] ~result_snapshot:(o 'z')
      ~composition_profile:"line-hunks-v1"
      ~policy_heads:[ d 'p' ]
      ~review_evidence:[]
    |> model
  in
  let policy_body =
    M.make_body ~context ~payload:(M.Accepted_version version)
  in
  let signed_policy =
    T.Core.sign authority capability policy_body
    |> core_trust |> R.encode |> record
  in
  rejects "signed unsupported policy cannot pass model boundary"
    (T.Core.receive authority empty signed_policy)

let all_families_and_arrival_order () =
  let authority, root, _, _, _, epoch = authority_fixture () in
  let context = context_for authority root [ T.epoch_id epoch ] in
  let signed payload =
    M.make_body ~context ~payload
    |> T.Core.sign authority capability
    |> core_trust
  in
  let receive pool signed_record =
    T.Core.receive authority pool (R.encode signed_record |> record)
    |> core_trust |> fst
  in
  let version ?(parents = []) ?(chosen = []) snapshot =
    M.make_accepted_version ~branch ~accepted_parents:parents
      ~chosen_revisions:chosen ~resolutions:[] ~result_snapshot:(o snapshot)
      ~composition_profile:"line-hunks-v1" ~policy_heads:[] ~review_evidence:[]
    |> model
    |> fun v -> signed (M.Accepted_version v)
  in
  let event ?(previous = []) action targets name =
    M.make_branch_event ~branch ~previous_events:previous ~action ~targets
      ~display_name:name
    |> model
    |> fun e -> signed (M.Branch_event e)
  in
  let genesis = version 'g' in
  let genesis_id = R.id genesis |> record in
  let created = event M.Create [ genesis_id ] (Some "main") in
  let created_id = R.id created |> record in
  let revision = signed (initial_revision ()) in
  let revision_id = R.id revision |> record in
  let pool =
    M.empty_pool ~repository |> fun p ->
    receive p genesis |> fun p ->
    receive p created |> fun p -> receive p revision
  in
  (* Same contents, distinct parent sets: history identities must survive. *)
  let left = version ~parents:[ genesis_id ] ~chosen:[ revision_id ] 'z' in
  let right = version ~parents:[ genesis_id ] 'z' in
  let left_id = R.id left |> record and right_id = R.id right |> record in
  Alcotest.(check bool)
    "equal snapshots do not collapse acceptances" false
    (M.Record_id.equal left_id right_id);
  let left_event = event ~previous:[ created_id ] M.Advance [ left_id ] None in
  let right_event =
    event ~previous:[ created_id ] M.Advance [ right_id ] None
  in
  let first =
    receive (receive (receive (receive pool left) left_event) right) right_event
  in
  let second =
    receive (receive (receive (receive pool right) right_event) left) left_event
  in
  Alcotest.(check bool)
    "receipt order preserves both immutable histories" true
    (M.records first = M.records second);
  let renamed =
    event ~previous:[ R.id left_event |> record ] M.Rename [] (Some "renamed")
  in
  let reconciled =
    event
      ~previous:[ R.id renamed |> record; R.id right_event |> record ]
      M.Reconcile [ left_id; right_id ] None
  in
  let final = receive (receive first renamed) reconciled in
  Alcotest.(check int)
    "all record families and branch actions consumed" 9
    (List.length (M.records final));
  let bad = version ~parents:[ revision_id ] 'z' in
  rejects "revision cannot be an accepted parent"
    (T.Core.receive authority pool (R.encode bad |> record))

let authority_concurrency () =
  let authority, root, member, member_cap, recovery, epoch =
    authority_fixture ()
  in
  (* Root genesis contains only the administrator. Enroll the member in an epoch. *)
  let active =
    T.successor_epoch authority
      ~parents:[ T.epoch_id epoch ]
      ~certificates:(T.certificates (T.authority_membership authority))
      ~revoked:[] ~frontier:[] ~recovery_device:recovery
      ~issuer:(T.certificate_id root) capability
    |> trust
  in
  let authority = T.extend_authority authority [ active ] |> trust in
  let member_context = context_for authority member [ T.epoch_id active ] in
  let member_body =
    M.make_body ~context:member_context ~payload:(initial_revision ())
  in
  let signed = T.Core.sign authority member_cap member_body |> core_trust in
  let bytes = R.encode signed |> record in
  let retained, _ =
    T.Core.receive authority (M.empty_pool ~repository) bytes |> core_trust
  in
  let revoke =
    T.successor_epoch authority
      ~parents:[ T.epoch_id active ]
      ~certificates:(T.certificates (T.authority_membership authority))
      ~revoked:[ T.device_id (T.certificate_subject member) ]
      ~frontier:[] ~recovery_device:recovery ~issuer:(T.certificate_id root)
      capability
    |> trust
  in
  let advanced = T.extend_authority authority [ revoke ] |> trust in
  T.Core.verify advanced signed |> core_trust;
  (match T.Core.receive advanced (M.empty_pool ~repository) bytes with
  | Error T.Core.Late_record_requires_adoption -> ()
  | Ok _
  | Error (T.Core.Trust_error _ | T.Core.Record_error _ | T.Core.Model_error _)
    ->
      Alcotest.fail "late revoked record admitted");
  let _, insertion = T.Core.receive advanced retained bytes |> core_trust in
  Alcotest.(check bool)
    "existing history remains identifiable" true (insertion = M.Unchanged);
  rejects "cannot newly sign an obsolete head"
    (T.Core.sign advanced member_cap member_body);
  let sibling =
    T.successor_epoch authority
      ~parents:[ T.epoch_id active ]
      ~certificates:(T.certificates (T.authority_membership authority))
      ~revoked:[] ~frontier:[] ~recovery_device:recovery
      ~issuer:(T.certificate_id root) capability
    |> trust
  in
  let forked = T.extend_authority authority [ revoke; sibling ] |> trust in
  Alcotest.(check int)
    "concurrent authority is retained" 2
    (List.length (T.authority_heads forked));
  let context = context_for forked root (T.authority_heads forked) in
  let body = M.make_body ~context ~payload:(initial_revision ()) in
  T.Core.sign forked capability body
  |> core_trust |> T.Core.verify forked |> core_trust;
  let invalid =
    context_for advanced root [ T.epoch_id active; T.epoch_id revoke ]
  in
  rejects "authority context is an antichain"
    (T.Core.sign advanced capability
       (M.make_body ~context:invalid ~payload:(initial_revision ())))

let () =
  Alcotest.run "Core trust"
    [
      ( "verified model boundary",
        [
          Alcotest.test_case "verified bytes and model consumption" `Quick
            trust_and_model;
          Alcotest.test_case "all record families and receipt permutations"
            `Quick all_families_and_arrival_order;
          Alcotest.test_case "historical/late/concurrent authority" `Quick
            authority_concurrency;
        ] );
    ]
