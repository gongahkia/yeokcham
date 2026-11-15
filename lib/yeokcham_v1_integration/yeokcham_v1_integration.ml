module Preservation = Preservation
module Core = Yeokcham_v1_model.Core
module Model = Yeokcham_v1_model
module Store = Yeokcham_v1_store
module Local = Store.Local
module Raw = Yeokcham_store
module History = Yeokcham_v1_undo
module Snapshot = Yeokcham_snapshot
module Composition = Yeokcham_v1_composition
module Trust = Yeokcham_v1_trust
module Pages = Yeokcham_v1_pages
module E = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Hash = Yeokcham_hash.Sha256

[@@@warning "-42"]

type error =
  | Invalid of string
  | Choice of string
  | Policy of string
  | Content of Composition.error
  | Metadata of string
  | Integrity of string
  | Stale of string

let error_to_string = function
  | Invalid s | Choice s | Policy s | Metadata s | Integrity s | Stale s -> s
  | Content e -> Composition.error_to_string e

type readiness =
  | Ready of Core.composition_result
  | Conflicted of Core.conflict list
  | Decision of string

type t = {
  identity : Core.Plan_id.t;
  stored : Raw.Stored_object_id.t;
  bytes : string;
  request : Core.composition_request;
  event_heads : Core.Record_id.t list;
  readiness : readiness;
  accepted_snapshot : Core.Object_id.t option;
  known_present : Core.Object_id.t;
  contributions : Local.publication list;
  no_op : bool;
}

let id t = t.identity
let stored_id t = t.stored
let encode t = t.bytes
let request t = t.request
let event_heads t = t.event_heads
let readiness t = t.readiness
let accepted_snapshot t = t.accepted_snapshot
let known_present t = t.known_present
let contributions t = t.contributions
let no_op t = t.no_op
let ( let* ) = Result.bind
let metadata r = Result.map_error (fun s -> Metadata s) r
let model r = Result.map_error (fun e -> Invalid (Core.error_to_string e)) r
let content r = Result.map_error (fun e -> Content e) r

let graph r =
  Result.map_error (fun e -> Invalid (Composition.Graph.error_to_string e)) r

let[@warning "-4"] pages r =
  Result.map_error
    (function
      | Pages.Invalid_input detail -> Invalid detail
      | Pages.Integrity detail -> Integrity detail
      | Pages.Store_error
          (( Raw.Io_error _ | Raw.File_size_changed _
           | Raw.Repository_incomplete _ | Raw.Repository_not_initialized _
           | Raw.Root_not_directory _ ) as error) ->
          Content (Composition.Unavailable (Raw.error_to_string error))
      | Pages.Store_error error -> Integrity (Raw.error_to_string error))
    r

let array v =
  E.array v
  |> Result.map_error (fun e -> Invalid (E.construction_error_to_string e))

let text v =
  E.text v
  |> Result.map_error (fun e -> Invalid (E.construction_error_to_string e))

let raw_object = fun id -> E.bytes (Core.Object_id.to_raw id)
let raw_record = fun id -> E.bytes (Core.Record_id.to_raw id)
let raw_digest = fun id -> E.bytes (Core.Digest.to_raw id)
let raw_store = fun id -> E.bytes (Raw.Stored_object_id.to_raw_bytes id)
let object_option = Option.fold ~none:E.null ~some:raw_object
let records ids = array (List.map raw_record ids)
let digests ids = array (List.map raw_digest ids)
let path parts = array (List.map E.bytes parts)

let traverse f values =
  List.fold_left
    (fun acc value ->
      let* rows = acc in
      let* value = f value in
      Ok (value :: rows))
    (Ok []) values
  |> Result.map List.rev

let filesystem_digest observation =
  let* entries =
    traverse
      (fun (parts, stamp) ->
        let* parts = path parts in
        array [ parts; E.bytes stamp ])
      (Snapshot.Observation.entries observation)
  in
  let* rules =
    traverse
      (fun (parts, stamp) ->
        let* parts = path parts in
        array [ parts; Option.fold ~none:E.null ~some:E.bytes stamp ])
      (Snapshot.Observation.rules observation)
  in
  let* directories =
    traverse
      (fun (parts, stamp, names) ->
        let* parts = path parts in
        let* names = array (List.map E.bytes names) in
        array [ parts; E.bytes stamp; names ])
      (Snapshot.Observation.directories observation |> List.sort Stdlib.compare)
  in
  let* entries = array entries in
  let* rules = array rules in
  let* directories = array directories in
  let* value = array [ E.integer 1L; entries; rules; directories ] in
  Core.Digest.of_raw
    (Hash.to_raw_string
       (Hash.digest_string
          ("yeokcham/integration-observation/v1\000" ^ E.encode value)))
  |> model

let observation_digest = filesystem_digest

let proof_row p =
  let* value =
    array
      [
        E.integer 1L;
        raw_record p.Local.revision;
        E.bytes (Core.Branch_id.to_raw p.Local.publication_branch);
        E.bytes
          (Core.Workspace_id.to_raw (Core.History_id.workspace p.Local.source));
        E.integer (Core.History_id.sequence p.Local.source);
        raw_object p.Local.observed;
        raw_object p.Local.contributed_scope;
        raw_store p.Local.witness_root;
      ]
  in
  Ok (Core.Operation_id.to_raw p.Local.operation, E.encode value)

let proof_root store repository workspace contributions =
  let* rows = traverse proof_row contributions in
  Pages.store store
    ~namespace:
      ("integration-correspondence-v1\000"
      ^ Core.Repository_id.to_raw repository
      ^ Core.Workspace_id.to_raw workspace)
    rows
  |> pages

let selection_root store pool revisions =
  let* changes =
    traverse
      (fun id ->
        match Core.find pool id with
        | Some { Core.payload = Core.Shared_revision value; _ } ->
            Ok value.Core.change
        | None
        | Some
            { Core.payload = Core.Accepted_version _ | Core.Branch_event _; _ }
          ->
            Error
              (Invalid
                 "integration selections must name retained shared revisions"))
      revisions
  in
  let* rows =
    traverse
      (fun change ->
        let heads = Core.change_heads pool change in
        let* () =
          if List.length heads > 1 then
            Error
              (Choice
                 "selected change has concurrent revisions; resolve its exact \
                  variants first")
          else Ok ()
        in
        let* value = records heads in
        Ok (Core.Change_id.to_raw change, E.encode value))
      (List.sort_uniq Core.Change_id.compare changes)
  in
  Pages.store store
    ~namespace:
      ("integration-selection-v1\000"
      ^ Core.Repository_id.to_raw (Core.pool_repository pool))
    rows
  |> pages

let encode_request (request : Core.composition_request) event_heads proof_root =
  let* event_heads = records event_heads in
  let* heads = records request.Core.accepted_heads in
  let* revisions = records request.Core.selected_revisions in
  let* resolutions = records request.Core.resolution_ids in
  let* authority = digests request.Core.authority_heads in
  let* policies = digests request.Core.policy_heads in
  let* evidence = digests request.Core.review_evidence in
  let workspace = request.Core.workspace in
  let* workspace =
    array
      [
        E.bytes (Core.Workspace_id.to_raw workspace.Core.workspace);
        E.integer (Core.History_id.sequence workspace.Core.cursor);
        raw_record workspace.Core.working_basis;
        raw_object workspace.Core.basis_snapshot;
        raw_object workspace.Core.observed_snapshot;
        raw_store proof_root;
      ]
  in
  let* profile = text request.Core.composition_profile in
  array
    [
      E.bytes (Core.Repository_id.to_raw request.Core.repository);
      E.bytes (Core.Branch_id.to_raw request.Core.branch);
      event_heads;
      heads;
      revisions;
      resolutions;
      authority;
      policies;
      evidence;
      workspace;
      profile;
    ]

let encode_readiness = function
  | Ready outputs ->
      array
        [
          E.integer 0L;
          raw_object outputs.Core.accepted_snapshot;
          raw_object outputs.Core.workspace_snapshot;
        ]
  | Conflicted conflicts ->
      let* conflicts =
        traverse
          (fun conflict ->
            let* parts = path conflict.Core.path in
            let* versions = records conflict.Core.versions in
            array [ parts; versions; E.bool conflict.Core.private_workspace ])
          conflicts
      in
      let* conflicts = array conflicts in
      array [ E.integer 1L; conflicts ]
  | Decision detail ->
      let* detail = text detail in
      array [ E.integer 2L; detail ]

let prepare ~store ~loaded ~observed ~observation ~selected_revisions
    ~reconcile_heads =
  let* local =
    loaded.Store.local
    |> Option.to_result
         ~none:(Invalid "integration requires authenticated local branch state")
  in
  let pool = Local.pool local in
  let selected = Local.selected local in
  let* branch =
    Local.branches local
    |> List.find_opt (fun b ->
        Core.Branch_id.equal b.Core.branch_id selected.Local.branch)
    |> Option.to_result ~none:(Invalid "selected branch is not retained")
  in
  let expected_heads =
    List.sort_uniq Core.Record_id.compare
      (branch.Core.accepted_heads @ branch.Core.event_heads)
  in
  let divergent =
    List.length branch.Core.accepted_heads > 1
    || List.length branch.Core.event_heads > 1
  in
  let* () =
    match reconcile_heads with
    | None when (not divergent) && branch.Core.accepted_heads <> [] -> Ok ()
    | Some heads
      when heads <> []
           && List.sort Core.Record_id.compare heads = expected_heads ->
        Ok ()
    | None ->
        Error
          (Choice
             "divergent branch event/accepted heads must all be named \
              explicitly for reconciliation")
    | Some _ ->
        Error
          (Choice
             "explicit reconciliation does not match every causal event and \
              accepted head")
  in
  let* collaboration =
    loaded.Store.collaboration
    |> Option.to_result ~none:(Policy "integration requires verified authority")
  in
  let* authority =
    Store.authority collaboration
    |> Option.to_result ~none:(Policy "integration requires verified authority")
  in
  let* certificate =
    Trust.certificates (Store.membership collaboration)
    |> List.find_opt (fun certificate ->
        Trust.certificate_id certificate = Store.local_certificate collaboration)
    |> Option.to_result
         ~none:(Policy "the local enrolled certificate is unavailable")
  in
  let* () =
    if
      List.for_all
        (fun epoch ->
          Trust.authority_device_active authority ~epoch
            (Trust.certificate_subject certificate))
        (Trust.authority_heads authority)
    then Ok ()
    else
      Error
        (Policy "the enrolled local device is not active in current authority")
  in
  let* authority_heads =
    match Trust.authority_heads authority with
    | [ _ ] as heads ->
        traverse (fun id -> Core.Digest.of_hex id |> model) heads
    | [] | _ :: _ ->
        Error
          (Choice
             "authority heads require explicit reconciliation before \
              integration")
  in
  let* basis = Composition.Graph.accepted pool selected.Local.basis |> graph in
  let* inherited =
    Composition.Graph.represented pool branch.Core.accepted_heads |> graph
  in
  let* selected_ancestry =
    Composition.Graph.represented_revisions pool selected_revisions |> graph
  in
  let represented =
    List.sort_uniq Core.Record_id.compare (inherited @ selected_ancestry)
  in
  let* known =
    Preservation.basis ~store ~loaded ~represented
    |> Result.map_error (function
      | Preservation.Content e -> Content e
      | Preservation.Invalid s -> Invalid s)
  in
  let* cursor =
    History.identity loaded.Store.history (History.current loaded.Store.history)
    |> metadata
  in
  let workspace = Core.History_id.workspace cursor in
  let* observed_snapshot =
    Core.Object_id.of_hex (Model.Snapshot_id.to_string observed) |> model
  in
  let* workspace_observation =
    Core.make_workspace_observation ~workspace ~cursor
      ~working_basis:selected.Local.basis
      ~basis_snapshot:basis.Core.result_snapshot ~observed_snapshot
      ~correspondence:
        (List.map
           (fun p -> (p.Local.revision, p.Local.source))
           known.Preservation.contributions)
    |> model
  in
  let* request =
    Core.make_composition_request
      ~repository:(Core.pool_repository pool)
      ~branch:selected.Local.branch ~accepted_heads:branch.Core.accepted_heads
      ~selected_revisions ~resolution_ids:[] ~authority_heads ~policy_heads:[]
      ~review_evidence:[] ~workspace:workspace_observation
      ~composition_profile:"line-hunks-v1"
    |> model
  in
  let* () = Core.validate_request_references pool request |> model in
  let versions =
    List.sort_uniq Core.Record_id.compare
      (request.Core.selected_revisions @ request.Core.accepted_heads)
  in
  let conflicts ~private_workspace paths =
    Conflicted
      (List.map (fun path -> Core.{ path; versions; private_workspace }) paths)
  in
  let* accepted_snapshot, readiness =
    match
      Composition.Graph.compose store pool ~parents:request.Core.accepted_heads
        ~revisions:request.Core.selected_revisions
    with
    | Error (Composition.Graph.Content_error (Composition.Conflicts paths)) ->
        Ok (None, conflicts ~private_workspace:false paths)
    | Error
        (Composition.Graph.Content_error
           (( Composition.Invalid_input _ | Composition.Unavailable _
            | Composition.Integrity _ ) as error)) ->
        Error (Content error)
    | Error (Composition.Graph.Invalid_graph detail) -> Error (Invalid detail)
    | Error (Composition.Graph.Decision detail) -> Ok (None, Decision detail)
    | Ok accepted -> (
        let* accepted_snapshot = Composition.store store accepted |> content in
        let* known_tree =
          Composition.load store known.Preservation.known_present |> content
        in
        let* observed = Composition.load store observed_snapshot |> content in
        match
          Composition.merge store ~base:known_tree
            ~variants:[ accepted; observed ]
        with
        | Error (Composition.Conflicts paths) ->
            Ok (Some accepted_snapshot, conflicts ~private_workspace:true paths)
        | Error
            (( Composition.Invalid_input _ | Composition.Unavailable _
             | Composition.Integrity _ ) as error) ->
            Error (Content error)
        | Ok result ->
            let* workspace_snapshot =
              Composition.store store result |> content
            in
            Ok
              ( Some accepted_snapshot,
                Ready { Core.accepted_snapshot; workspace_snapshot } ))
  in
  let* proof_root =
    proof_root store request.Core.repository workspace
      known.Preservation.contributions
  in
  let* selection_root =
    selection_root store pool request.Core.selected_revisions
  in
  let* observation_digest = filesystem_digest observation in
  let* request_value =
    encode_request request branch.Core.event_heads proof_root
  in
  let* readiness_value = encode_readiness readiness in
  let* already =
    Composition.Graph.represented pool [ selected.Local.basis ] |> graph
  in
  let no_op =
    branch.Core.accepted_heads = [ selected.Local.basis ]
    && List.length branch.Core.event_heads = 1
    && List.for_all
         (fun id -> List.exists (Core.Record_id.equal id) already)
         request.Core.selected_revisions
  in
  let* payload =
    array
      [
        E.integer 1L;
        request_value;
        raw_store selection_root;
        raw_digest observation_digest;
        raw_object known.Preservation.known_present;
        object_option accepted_snapshot;
        readiness_value;
        E.bool no_op;
      ]
  in
  let* envelope =
    Envelope.create ~object_type:Envelope.Core_integration_plan
      ~object_format_version:1 ~mandatory_features:0L ~payload ()
    |> Result.map_error (fun e -> Invalid (Envelope.creation_error_to_string e))
  in
  let bytes = Envelope.encode envelope in
  if String.length bytes > 8 * 1024 * 1024 then
    Error (Invalid "integration plan exceeds the 8 MiB control-record bound")
  else
    let* identity =
      Core.Plan_id.of_raw (Hash.to_raw_string (Hash.digest_string bytes))
      |> model
    in
    let* stored =
      Raw.put store envelope
      |> Result.map_error (fun e -> Metadata (Raw.error_to_string e))
    in
    Ok
      {
        identity;
        stored;
        bytes;
        request;
        event_heads = branch.Core.event_heads;
        readiness;
        accepted_snapshot;
        known_present = known.Preservation.known_present;
        contributions = known.Preservation.contributions;
        no_op;
      }

let[@warning "-4"] decoded_model value =
  Result.map_error
    (function
      | Core.Unsupported_policy detail -> Policy detail
      | error -> Integrity (Core.error_to_string error))
    value

let[@warning "-4"] decoded_id parse = function
  | E.Bytes raw -> parse raw |> decoded_model
  | _ -> Error (Integrity "plan identity must be raw bytes")

let[@warning "-4"] decoded_store = function
  | E.Bytes raw ->
      Raw.Stored_object_id.of_raw_bytes raw
      |> Option.to_result ~none:(Integrity "malformed plan store reference")
  | _ -> Error (Integrity "plan store reference must be bytes")

let[@warning "-4"] decoded_set parse compare = function
  | E.Array values when List.length values <= Core.max_references ->
      let* values = traverse (decoded_id parse) values in
      if values = List.sort_uniq compare values then Ok values
      else Error (Integrity "duplicate or unsorted plan identity set")
  | _ -> Error (Integrity "invalid or oversized plan identity set")

let decoded_records = decoded_set Core.Record_id.of_raw Core.Record_id.compare
let decoded_digests = decoded_set Core.Digest.of_raw Core.Digest.compare

let[@warning "-4"] decoded_path = function
  | E.Array parts ->
      let* parts =
        traverse
          (function
            | E.Bytes part -> Ok part
            | _ -> Error (Integrity "plan paths must contain bytes"))
          parts
      in
      let* () =
        Composition.validate_path parts
        |> Result.map_error (fun e -> Integrity (Composition.error_to_string e))
      in
      Ok parts
  | _ -> Error (Integrity "invalid plan conflict path")

let[@warning "-4"] decode ~store ~loaded bytes =
  if String.length bytes > 8 * 1024 * 1024 then
    Error (Integrity "integration plan exceeds 8 MiB")
  else
    let* envelope =
      Envelope.decode bytes
      |> Result.map_error (fun e ->
          Integrity (Envelope.decode_error_to_string e))
    in
    if Envelope.object_type envelope <> Envelope.Core_integration_plan then
      Error (Integrity "wrong integration plan envelope type")
    else
      let* local =
        loaded.Store.local
        |> Option.to_result
             ~none:(Integrity "plan workspace has no authenticated local state")
      in
      let pool = Local.pool local in
      let* ( request_value,
             selection,
             observation_digest,
             known_present,
             accepted_value,
             readiness_value,
             no_op ) =
        match Envelope.payload envelope with
        | E.Array
            [
              E.Integer 1L;
              request;
              selection;
              observation;
              known;
              accepted;
              readiness;
              E.Bool no_op;
            ] ->
            let* selection = decoded_store selection in
            let* observation = decoded_id Core.Digest.of_raw observation in
            let* known = decoded_id Core.Object_id.of_raw known in
            Ok
              ( request,
                selection,
                observation,
                known,
                accepted,
                readiness,
                no_op )
        | _ ->
            Error (Integrity "unsupported or malformed integration plan schema")
      in
      let* ( repository,
             branch,
             event_heads,
             accepted_heads,
             selected_revisions,
             resolution_ids,
             authority_heads,
             policy_heads,
             review_evidence,
             workspace,
             cursor,
             working_basis,
             basis_snapshot,
             observed_snapshot,
             proof,
             profile ) =
        match request_value with
        | E.Array
            [
              repo;
              branch;
              events;
              heads;
              revisions;
              resolutions;
              authority;
              policies;
              evidence;
              E.Array
                [
                  workspace;
                  E.Integer cursor;
                  basis;
                  basis_snapshot;
                  observed;
                  proof;
                ];
              E.Text profile;
            ] ->
            let* repository = decoded_id Core.Repository_id.of_raw repo in
            let* branch = decoded_id Core.Branch_id.of_raw branch in
            let* events = decoded_records events in
            let* heads = decoded_records heads in
            let* revisions = decoded_records revisions in
            let* resolutions = decoded_records resolutions in
            let* authority = decoded_digests authority in
            let* policies = decoded_digests policies in
            let* evidence = decoded_digests evidence in
            let* workspace = decoded_id Core.Workspace_id.of_raw workspace in
            let* cursor =
              Core.History_id.make ~workspace ~sequence:cursor |> decoded_model
            in
            let* basis = decoded_id Core.Record_id.of_raw basis in
            let* basis_snapshot =
              decoded_id Core.Object_id.of_raw basis_snapshot
            in
            let* observed = decoded_id Core.Object_id.of_raw observed in
            let* proof = decoded_store proof in
            Ok
              ( repository,
                branch,
                events,
                heads,
                revisions,
                resolutions,
                authority,
                policies,
                evidence,
                workspace,
                cursor,
                basis,
                basis_snapshot,
                observed,
                proof,
                profile )
        | _ -> Error (Integrity "malformed integration request fields")
      in
      let* () =
        if
          Core.Repository_id.equal repository (Core.pool_repository pool)
          && Option.equal Core.Workspace_id.equal (Some workspace)
               (History.workspace loaded.Store.history)
        then Ok ()
        else
          Error
            (Integrity
               "integration plan belongs to a different repository or workspace")
      in
      let* _ =
        History.find loaded.Store.history (Core.History_id.sequence cursor)
        |> Result.map_error (fun e -> Integrity e)
      in
      let* rows =
        Pages.load_bounded store
          ~namespace:
            ("integration-correspondence-v1\000"
            ^ Core.Repository_id.to_raw repository
            ^ Core.Workspace_id.to_raw workspace)
          ~max_rows:Core.max_references ~max_value_bytes:512
          ~max_total_value_bytes:(8 * 1024 * 1024)
          proof
        |> pages
      in
      let* contributions =
        traverse
          (fun (operation, value) ->
            let* operation =
              Core.Operation_id.of_raw operation |> decoded_model
            in
            let* receipt =
              Local.publications local
              |> List.find_opt (fun p ->
                  Core.Operation_id.equal operation p.Local.operation)
              |> Option.to_result
                   ~none:
                     (Integrity "plan references an unknown publication witness")
            in
            let* _, expected = proof_row receipt in
            if value <> expected then
              Error
                (Integrity
                   "plan correspondence disagrees with its durable source \
                    receipt")
            else Ok receipt)
          rows
      in
      let* workspace_observation =
        Core.make_workspace_observation ~workspace ~cursor ~working_basis
          ~basis_snapshot ~observed_snapshot
          ~correspondence:
            (List.map
               (fun p -> (p.Local.revision, p.Local.source))
               contributions)
        |> decoded_model
      in
      let* request =
        Core.make_composition_request ~repository ~branch ~accepted_heads
          ~selected_revisions ~resolution_ids ~authority_heads ~policy_heads
          ~review_evidence ~workspace:workspace_observation
          ~composition_profile:profile
        |> decoded_model
      in
      let* () =
        Core.validate_request_references pool request |> decoded_model
      in
      let* authority =
        Option.bind loaded.Store.collaboration Store.authority
        |> Option.to_result ~none:(Policy "plan authority is unavailable")
      in
      let* _ =
        traverse
          (fun head ->
            Trust.authority_epoch authority (Core.Digest.to_hex head)
            |> Result.map_error (fun error ->
                Policy (Trust.error_to_string error)))
          authority_heads
      in
      let* () =
        if event_heads = [] then
          Error (Integrity "integration plan requires branch event heads")
        else Ok ()
      in
      let* () =
        traverse
          (fun id ->
            match Core.find pool id with
            | Some { Core.payload = Core.Branch_event value; _ }
              when Core.Branch_id.equal value.Core.branch branch ->
                Ok ()
            | None | Some _ ->
                Error
                  (Integrity "plan event is absent or belongs to another branch"))
          event_heads
        |> Result.map (fun _ -> ())
      in
      let* () =
        traverse
          (fun id ->
            match Core.find pool id with
            | Some { Core.payload = Core.Accepted_version value; _ }
              when Core.Branch_id.equal value.Core.branch branch ->
                Ok ()
            | None | Some _ ->
                Error
                  (Integrity
                     "plan accepted head is absent or belongs to another branch"))
          accepted_heads
        |> Result.map (fun _ -> ())
      in
      let* basis =
        Composition.Graph.accepted pool working_basis
        |> Result.map_error (fun e ->
            Integrity (Composition.Graph.error_to_string e))
      in
      let* () =
        if Core.Object_id.equal basis.Core.result_snapshot basis_snapshot then
          Ok ()
        else Error (Integrity "plan working basis snapshot is false")
      in
      let* selection_rows =
        Pages.load_bounded store
          ~namespace:
            ("integration-selection-v1\000"
            ^ Core.Repository_id.to_raw repository)
          ~max_rows:(List.length selected_revisions)
          ~max_value_bytes:((Core.max_references * 34) + 16)
          ~max_total_value_bytes:(8 * 1024 * 1024)
          selection
        |> pages
      in
      let* selected_changes =
        traverse
          (fun id ->
            match Core.find pool id with
            | Some { Core.payload = Core.Shared_revision value; _ } ->
                Ok value.Core.change
            | None | Some _ ->
                Error
                  (Integrity "plan selection is not a retained shared revision"))
          selected_revisions
      in
      let* floating_changes =
        traverse
          (fun (change, value) ->
            let* change = Core.Change_id.of_raw change |> decoded_model in
            let* value =
              E.decode value
              |> Result.map_error (fun e ->
                  Integrity (E.decode_error_to_string e))
            in
            let* heads = decoded_records value in
            let* () =
              if heads = [] then
                Error (Integrity "floating change has no recorded head")
              else Ok ()
            in
            let* _ =
              traverse
                (fun id ->
                  match Core.find pool id with
                  | Some { Core.payload = Core.Shared_revision version; _ }
                    when Core.Change_id.equal version.Core.change change ->
                      Ok ()
                  | None | Some _ ->
                      Error
                        (Integrity
                           "floating change head belongs to a different change"))
                heads
            in
            Ok change)
          selection_rows
      in
      let* () =
        if
          List.sort_uniq Core.Change_id.compare selected_changes
          = floating_changes
        then Ok ()
        else
          Error
            (Integrity
               "plan floating selection does not cover its exact chosen changes")
      in
      let* accepted_snapshot =
        match accepted_value with
        | E.Null -> Ok None
        | value ->
            decoded_id Core.Object_id.of_raw value |> Result.map Option.some
      in
      let* readiness =
        match readiness_value with
        | E.Array [ E.Integer 0L; accepted; working ] ->
            let* accepted = decoded_id Core.Object_id.of_raw accepted in
            let* working = decoded_id Core.Object_id.of_raw working in
            if
              not
                (Option.equal Core.Object_id.equal accepted_snapshot
                   (Some accepted))
            then Error (Integrity "plan accepted output fields disagree")
            else
              Ok
                (Ready
                   {
                     Core.accepted_snapshot = accepted;
                     workspace_snapshot = working;
                   })
        | E.Array [ E.Integer 1L; E.Array values ] when values <> [] ->
            let versions =
              List.sort_uniq Core.Record_id.compare
                (selected_revisions @ accepted_heads)
            in
            let* conflicts =
              traverse
                (function
                  | E.Array [ parts; ids; E.Bool private_workspace ] ->
                      let* path = decoded_path parts in
                      let* ids = decoded_records ids in
                      if
                        ids <> versions
                        || private_workspace <> Option.is_some accepted_snapshot
                      then
                        Error
                          (Integrity
                             "conflict variants or output scope disagree")
                      else Ok Core.{ path; versions; private_workspace }
                  | _ -> Error (Integrity "malformed plan conflict"))
                values
            in
            if conflicts <> List.sort_uniq Stdlib.compare conflicts || no_op
            then Error (Integrity "noncanonical or no-op conflict plan")
            else Ok (Conflicted conflicts)
        | E.Array [ E.Integer 2L; E.Text detail ]
          when detail <> ""
               && String.length detail <= 4096
               && accepted_snapshot = None && not no_op ->
            Ok (Decision detail)
        | _ -> Error (Integrity "invalid integration readiness fields")
      in
      let* expected_request = encode_request request event_heads proof in
      let* expected_readiness = encode_readiness readiness in
      let* expected =
        array
          [
            E.integer 1L;
            expected_request;
            raw_store selection;
            raw_digest observation_digest;
            raw_object known_present;
            object_option accepted_snapshot;
            expected_readiness;
            E.bool no_op;
          ]
      in
      if not (E.equal expected (Envelope.payload envelope)) then
        Error (Integrity "noncanonical integration plan control")
      else
        let* identity =
          Core.Plan_id.of_raw (Hash.to_raw_string (Hash.digest_string bytes))
          |> decoded_model
        in
        Ok
          {
            identity;
            stored = Raw.id_of_envelope envelope;
            bytes;
            request;
            event_heads;
            readiness;
            accepted_snapshot;
            known_present;
            contributions;
            no_op;
          }

let[@warning "-4"] input_bytes plan =
  let* envelope =
    Envelope.decode plan.bytes
    |> Result.map_error (fun e -> Integrity (Envelope.decode_error_to_string e))
  in
  match Envelope.payload envelope with
  | E.Array [ E.Integer 1L; request; selection; observation; _; _; _; _ ] ->
      let* inputs = array [ request; selection; observation ] in
      Ok (E.encode inputs)
  | _ -> Error (Integrity "invalid prepared plan payload")

let[@warning "-4"] revalidate ~store ~loaded ~observed ~observation plan =
  let reconcile_heads =
    if
      List.length plan.request.Core.accepted_heads > 1
      || List.length plan.event_heads > 1
    then
      Some
        (List.sort_uniq Core.Record_id.compare
           (plan.request.Core.accepted_heads @ plan.event_heads))
    else None
  in
  let* current =
    prepare ~store ~loaded ~observed ~observation
      ~selected_revisions:plan.request.Core.selected_revisions ~reconcile_heads
    |> Result.map_error (function
      | Choice detail -> Stale detail
      | error -> error)
  in
  let* previous_inputs = input_bytes plan in
  let* current_inputs = input_bytes current in
  if previous_inputs <> current_inputs then
    Error (Stale "integration inputs changed; prepare and confirm a new plan")
  else if not (Core.Plan_id.equal plan.identity current.identity) then
    Error
      (Integrity
         "declared plan outputs do not match exact deterministic preparation")
  else Ok current

let retention_roots plan =
  let workspace = plan.request.Core.workspace in
  let outputs =
    match plan.readiness with
    | Ready result -> [ result.Core.workspace_snapshot ]
    | Conflicted _ | Decision _ -> []
  in
  List.sort_uniq Core.Object_id.compare
    (workspace.Core.observed_snapshot :: workspace.Core.basis_snapshot
   :: plan.known_present
    :: (Option.to_list plan.accepted_snapshot @ outputs))

let[@warning "-4"] revalidate_shared ~store ~loaded ~cursor plan =
  let* local =
    loaded.Store.local
    |> Option.to_result ~none:(Stale "integration local state is unavailable")
  in
  let selected = Local.selected local in
  let* current_cursor =
    History.identity loaded.Store.history (History.current loaded.Store.history)
    |> metadata
  in
  let* branch =
    Local.branches local
    |> List.find_opt (fun b ->
        Core.Branch_id.equal b.Core.branch_id plan.request.Core.branch)
    |> Option.to_result ~none:(Stale "integration branch is unavailable")
  in
  let* () =
    if
      Core.History_id.equal cursor current_cursor
      && Core.Branch_id.equal selected.Local.branch plan.request.Core.branch
      && Core.Record_id.equal selected.Local.basis
           plan.request.Core.workspace.Core.working_basis
      && branch.Core.event_heads = plan.event_heads
      && branch.Core.accepted_heads = plan.request.Core.accepted_heads
    then Ok ()
    else Error (Stale "integration branch, heads or safety cursor changed")
  in
  let* collaboration =
    loaded.Store.collaboration
    |> Option.to_result ~none:(Policy "integration authority is unavailable")
  in
  let* authority =
    Store.authority collaboration
    |> Option.to_result ~none:(Policy "integration authority is unavailable")
  in
  let* heads =
    traverse
      (fun head -> Core.Digest.of_hex head |> model)
      (Trust.authority_heads authority)
  in
  let* certificate =
    Trust.certificates (Store.membership collaboration)
    |> List.find_opt (fun c ->
        Trust.certificate_id c = Store.local_certificate collaboration)
    |> Option.to_result ~none:(Policy "integration local author is unavailable")
  in
  let* () =
    if
      heads = plan.request.Core.authority_heads
      && List.for_all
           (fun epoch ->
             Trust.authority_device_active authority ~epoch
               (Trust.certificate_subject certificate))
           (Trust.authority_heads authority)
    then Ok ()
    else
      Error
        (Policy "integration authority changed or the local device is inactive")
  in
  let* current_selection =
    selection_root store (Local.pool local) plan.request.Core.selected_revisions
    |> Result.map_error (function Choice detail -> Stale detail | e -> e)
  in
  let* envelope =
    Envelope.decode plan.bytes
    |> Result.map_error (fun e -> Integrity (Envelope.decode_error_to_string e))
  in
  match Envelope.payload envelope with
  | E.Array
      [
        _schema;
        _request;
        selection;
        _observation;
        _known;
        _accepted;
        _readiness;
        _no_op;
      ] ->
      let* selection = decoded_store selection in
      if Raw.Stored_object_id.equal current_selection selection then Ok ()
      else Error (Stale "integration selected change heads changed")
  | _ -> Error (Integrity "malformed prepared integration control")

let plan_directory store =
  Filename.concat
    (Filename.concat (Raw.root store) ".yeokcham")
    "integration-plans"

let plan_path store identity =
  Filename.concat (plan_directory store) (Core.Plan_id.to_hex identity ^ ".plan")

let directory_error operation path error =
  Metadata
    (Printf.sprintf "%s failed for %s: %s" operation path
       (Unix.error_message error))

let sync_directory path =
  try
    let descriptor = Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close descriptor)
      (fun () -> Unix.fsync descriptor);
    Ok ()
  with Unix.Unix_error (error, _, _) ->
    Error (directory_error "fsync integration plan directory" path error)

let inspect_plan_directory store =
  let path = plan_directory store in
  try
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR -> Ok true
    | Unix.S_REG | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK | Unix.S_CHR
    | Unix.S_BLK ->
        Error (Integrity "integration plan directory is not a native directory")
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
  | Unix.Unix_error (error, _, _) ->
      Error (directory_error "inspect integration plan directory" path error)

let ensure_plan_directory store =
  let* exists = inspect_plan_directory store in
  if exists then Ok ()
  else
    let path = plan_directory store in
    try
      Unix.mkdir path 0o700;
      sync_directory (Filename.dirname path)
    with Unix.Unix_error (error, _, _) ->
      Error (directory_error "create integration plan directory" path error)

let with_retention store action =
  Raw.with_lock store ~name:"restore-retention"
    ~on_error:(fun e -> Metadata (Raw.error_to_string e))
    action

let retain ~store plan =
  with_retention store (fun () ->
      let* _ =
        traverse
          (fun snapshot -> Composition.load store snapshot |> content)
          (retention_roots plan)
      in
      let* envelope =
        Envelope.decode plan.bytes
        |> Result.map_error (fun e ->
            Integrity (Envelope.decode_error_to_string e))
      in
      let* _ =
        Raw.put store envelope
        |> Result.map_error (fun e -> Metadata (Raw.error_to_string e))
      in
      let* () = ensure_plan_directory store in
      let path = plan_path store plan.identity in
      let* created =
        Raw.publish_file_create_only ~path ~bytes:plan.bytes
        |> Result.map_error (fun e -> Metadata (Raw.error_to_string e))
      in
      if created then Ok ()
      else
        let* existing =
          Raw.read_file_bounded ~path ~max_bytes:(8 * 1024 * 1024)
          |> Result.map_error (fun e -> Metadata (Raw.error_to_string e))
        in
        if existing = plan.bytes then Ok ()
        else
          Error
            (Integrity
               "integration plan identity collision or corrupt retained plan"))

let load ~store ~loaded identity =
  let* exists = inspect_plan_directory store in
  let* () =
    if exists then Ok ()
    else Error (Metadata "retained integration plan is unavailable")
  in
  let* bytes =
    Raw.read_file_bounded ~path:(plan_path store identity)
      ~max_bytes:(8 * 1024 * 1024)
    |> Result.map_error (fun e -> Metadata (Raw.error_to_string e))
  in
  let* plan = decode ~store ~loaded bytes in
  if Core.Plan_id.equal identity plan.identity then Ok plan
  else Error (Integrity "retained integration plan has the wrong identity")

let scan ~store ~loaded =
  let directory = plan_directory store in
  let* exists =
    try Ok (Some (Unix.lstat directory)) with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
    | Unix.Unix_error (error, _, _) ->
        Error
          (directory_error "inspect integration plan directory" directory error)
  in
  match exists with
  | None -> Ok []
  | Some stat when stat.Unix.st_kind = Unix.S_DIR ->
      let* names =
        try
          Ok (Sys.readdir directory |> Array.to_list |> List.sort String.compare)
        with Sys_error detail -> Error (Metadata detail)
      in
      let names =
        List.filter
          (fun name -> not (String.starts_with ~prefix:"." name))
          names
      in
      traverse
        (fun name ->
          if not (String.ends_with ~suffix:".plan" name) then
            Error (Integrity "unknown file in integration plan directory")
          else
            let* identity =
              Core.Plan_id.of_hex (String.sub name 0 (String.length name - 5))
              |> decoded_model
            in
            load ~store ~loaded identity)
        names
  | Some _ ->
      Error (Integrity "integration plan directory is not a native directory")

let forget ~store identity =
  with_retention store (fun () ->
      let* repository =
        Store.open_repository ~root:(Raw.root store)
        |> Result.map_error (fun e -> Metadata (Store.error_to_string e))
      in
      let* loaded =
        Store.load repository
        |> Result.map_error (fun e -> Metadata (Store.error_to_string e))
      in
      let* () =
        let module Clone = Yeokcham_v1_transport.Core_clone in
        match
          Option.bind loaded.Store.collaboration (fun collaboration ->
              Clone.find (Store.transport collaboration))
        with
        | Some clone
          when (not (Clone.complete clone)) && Clone.plan clone = Some identity
          ->
            let closed =
              Option.exists
                (fun local ->
                  Option.exists Local.Operation.recovered
                    (Local.find_operation local ~plan:identity))
                loaded.Store.local
            in
            if closed then Ok ()
            else Error (Invalid "an incomplete clone still owns this plan")
        | None | Some _ -> Ok ()
      in
      let* () =
        match loaded.Store.local with
        | Some local
          when List.exists
                 (fun operation ->
                   Local.Operation.pending operation
                   && Core.Plan_id.equal identity operation.Local.Operation.plan)
                 (Local.operations local) ->
            Error
              (Invalid
                 "an incomplete integration operation still owns this plan")
        | None | Some _ -> Ok ()
      in
      let* exists = inspect_plan_directory store in
      if not exists then Ok ()
      else
        let path = plan_path store identity in
        try
          let stat = Unix.lstat path in
          if stat.Unix.st_kind <> Unix.S_REG then
            Error (Integrity "retained integration plan is not a regular file")
          else (
            Unix.unlink path;
            sync_directory (plan_directory store))
        with
        | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
        | Unix.Unix_error (error, _, _) ->
            Error (directory_error "forget integration plan" path error))
