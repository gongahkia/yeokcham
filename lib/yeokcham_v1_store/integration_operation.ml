module Core = Yeokcham_v1_model.Core
module E = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Raw = Yeokcham_store
module Pages = Yeokcham_v1_pages
module Trust = Yeokcham_v1_trust
module Record = Yeokcham_v1_record.Core
module Composition = Yeokcham_v1_composition
module History = Yeokcham_v1_undo

[@@@warning "-42"]

let ( let* ) = Result.bind
let model r = Result.map_error Core.error_to_string r
let array xs = E.array xs |> Result.map_error E.construction_error_to_string

let traverse f xs =
  List.fold_left
    (fun acc x ->
      let* xs = acc in
      let* x = f x in
      Ok (x :: xs))
    (Ok []) xs
  |> Result.map List.rev

type stage = Before_apply | During_apply | Before_commit

type phase =
  | Prepared
  | Applying
  | Materialized
  | Committed
  | Completed
  | Paused of stage * string

type t = {
  token : Core.Operation_id.t;
  plan : Core.Plan_id.t;
  plan_object : Raw.Stored_object_id.t;
  branch : Core.Branch_id.t;
  source : Core.History_id.t;
  plan_cursor : Core.History_id.t;
  working_basis : Core.Record_id.t;
  protected : Core.Object_id.t list;
  target_sequence : int64;
  safety : Core.Object_id.t;
  target : Core.Object_id.t;
  accepted : Core.Record_id.t;
  staged : (Core.Record_id.t * Raw.Stored_object_id.t) list;
  physical_digest : Core.Digest.t;
  expected_generation : int64;
  expected_root : Raw.Stored_object_id.t;
  created_at : int64;
  phase : phase;
  serial : int64;
  acknowledged : bool;
}

let committed t =
  match t.phase with
  | Committed | Completed -> true
  | Prepared | Applying | Materialized | Paused _ -> false

let pending t = t.phase <> Completed
let retention_roots t = if pending t then t.protected else []

let stage = function
  | Prepared -> Some Before_apply
  | Applying -> Some During_apply
  | Materialized -> Some Before_commit
  | Paused (s, _) -> Some s
  | Committed | Completed -> None

let resume_phase = function
  | Before_apply -> Prepared
  | During_apply -> Applying
  | Before_commit -> Materialized

let[@warning "-4"] transition previous next =
  previous = next
  ||
  match (previous, next) with
  | Prepared, Applying
  | Applying, Materialized
  | Materialized, Committed
  | Committed, Completed ->
      true
  | (Prepared | Applying | Materialized | Paused _), Paused (s, detail) ->
      stage previous = Some s && detail <> "" && String.length detail <= 4096
  | Paused (s, _), next -> next = resume_phase s
  | _ -> false

let advance t phase =
  if phase = t.phase then Ok t
  else if not (transition t.phase phase) then
    Error "invalid integration operation phase transition"
  else if t.serial = Int64.max_int then
    Error "integration operation generation exhausted"
  else Ok { t with phase; serial = Int64.succ t.serial }

let acknowledge t =
  if not (committed t) then
    Error "uncommitted integration has no outbound acknowledgement"
  else if t.acknowledged then Ok t
  else if t.serial = Int64.max_int then
    Error "integration operation generation exhausted"
  else Ok { t with acknowledged = true; serial = Int64.succ t.serial }

let validate_update ~previous t =
  if
    {
      t with
      phase = previous.phase;
      serial = previous.serial;
      acknowledged = previous.acknowledged;
    }
    <> previous
  then Error "integration operation identity collision or rewritten intent"
  else if t = previous then Ok ()
  else if
    previous.serial = Int64.max_int || t.serial <> Int64.succ previous.serial
  then Error "integration operation generation is not consecutive"
  else if previous.acknowledged && not t.acknowledged then
    Error "cannot erase outbound acknowledgement"
  else if previous.phase = t.phase && previous.acknowledged = t.acknowledged
  then Error "operation generation changed without a new durable fact"
  else if not (transition previous.phase t.phase) then
    Error "invalid integration operation phase transition"
  else if
    t.acknowledged <> previous.acknowledged
    && (t.phase <> previous.phase || not (committed t))
  then
    Error
      "acknowledgement must follow an independent committed-state transition"
  else Ok ()

let[@warning "-4"] plan_outputs store scope plan plan_object =
  let* envelope =
    Raw.get ~max_bytes:(8 * 1024 * 1024) store plan_object
    |> Result.map_error Raw.error_to_string
  in
  let bytes = Envelope.encode envelope in
  let* identity =
    Core.Plan_id.of_raw
      (Yeokcham_hash.Sha256.to_raw_string
         (Yeokcham_hash.Sha256.digest_string bytes))
    |> model
  in
  if
    String.length bytes > 8 * 1024 * 1024
    || Envelope.object_type envelope <> Envelope.Core_integration_plan
    || not (Core.Plan_id.equal identity plan)
  then Error "integration operation references the wrong plan control"
  else
    match Envelope.payload envelope with
    | E.Array
        [
          E.Integer 1L;
          E.Array
            [
              E.Bytes repository;
              E.Bytes branch;
              _events;
              _heads;
              _revisions;
              E.Array [];
              _authority;
              E.Array [];
              E.Array [];
              E.Array
                [
                  E.Bytes workspace;
                  E.Integer cursor;
                  E.Bytes basis;
                  E.Bytes basis_snapshot;
                  E.Bytes observed;
                  _proof;
                ];
              E.Text "line-hunks-v1";
            ];
          _selection;
          _filesystem;
          E.Bytes known;
          E.Bytes declared;
          E.Array [ E.Integer 0L; E.Bytes accepted; E.Bytes target ];
          E.Bool false;
        ] ->
        let* repository = Core.Repository_id.of_raw repository |> model in
        let* branch = Core.Branch_id.of_raw branch |> model in
        let* workspace = Core.Workspace_id.of_raw workspace |> model in
        let* cursor =
          Core.History_id.make ~workspace ~sequence:cursor |> model
        in
        let* working_basis = Core.Record_id.of_raw basis |> model in
        let* basis_snapshot = Core.Object_id.of_raw basis_snapshot |> model in
        let* known = Core.Object_id.of_raw known |> model in
        let* safety = Core.Object_id.of_raw observed |> model in
        let* accepted = Core.Object_id.of_raw accepted |> model in
        let* target = Core.Object_id.of_raw target |> model in
        if
          (not (Core.Repository_id.equal repository scope))
          || declared <> Core.Object_id.to_raw accepted
        then Error "integration operation plan scope/output mismatch"
        else
          Ok
            ( branch,
              cursor,
              working_basis,
              safety,
              accepted,
              target,
              List.sort_uniq Core.Object_id.compare
                [ safety; accepted; target; basis_snapshot; known ] )
    | _ ->
        Error "integration operation requires a supported non-no-op Ready plan"

let make ~store ~repository ~token ~plan ~plan_object ~source ~target_sequence
    ~accepted ~staged ~physical_digest ~expected ~created_at =
  let* branch, cursor, working_basis, safety, _, target, protected =
    plan_outputs store repository plan plan_object
  in
  let* expected_root =
    Raw.Mutable_ref.target expected
    |> Option.to_result ~none:"integration requires an existing metadata root"
  in
  if
    created_at < 0L
    || target_sequence <= Core.History_id.sequence source
    || (not
          (Core.Workspace_id.equal
             (Core.History_id.workspace cursor)
             (Core.History_id.workspace source)))
    || Core.History_id.sequence source < Core.History_id.sequence cursor
  then Error "invalid integration source/reserved history position"
  else if
    List.length staged > 2
    || staged
       <> List.sort_uniq
            (fun (a, _) (b, _) -> Core.Record_id.compare a b)
            staged
  then
    Error
      "integration signed staging must be a canonical acceptance/event pair or \
       an existing accepted head"
  else
    Ok
      {
        token;
        plan;
        plan_object;
        branch;
        source;
        plan_cursor = cursor;
        working_basis;
        protected;
        target_sequence;
        safety;
        target;
        accepted;
        staged;
        physical_digest;
        expected_generation = Raw.Mutable_ref.generation expected;
        expected_root;
        created_at;
        phase = Prepared;
        serial = 0L;
        acknowledged = false;
      }

let phase_value = function
  | Prepared -> array [ E.integer 0L ]
  | Applying -> array [ E.integer 1L ]
  | Materialized -> array [ E.integer 2L ]
  | Committed -> array [ E.integer 3L ]
  | Completed -> array [ E.integer 4L ]
  | Paused (stage, detail) ->
      let* detail =
        E.text detail |> Result.map_error E.construction_error_to_string
      in
      let code =
        match stage with
        | Before_apply -> 0L
        | During_apply -> 1L
        | Before_commit -> 2L
      in
      array [ E.integer 5L; E.integer code; detail ]

let encode t =
  let* phase = phase_value t.phase in
  let* staged =
    traverse
      (fun (id, obj) ->
        array
          [
            E.bytes (Core.Record_id.to_raw id);
            E.bytes (Raw.Stored_object_id.to_raw_bytes obj);
          ])
      t.staged
  in
  let* staged = array staged in
  let* value =
    array
      [
        E.integer 1L;
        E.bytes (Core.Plan_id.to_raw t.plan);
        E.bytes (Raw.Stored_object_id.to_raw_bytes t.plan_object);
        E.bytes (Core.Branch_id.to_raw t.branch);
        E.bytes (Core.Workspace_id.to_raw (Core.History_id.workspace t.source));
        E.integer (Core.History_id.sequence t.source);
        E.integer t.target_sequence;
        E.bytes (Core.Object_id.to_raw t.safety);
        E.bytes (Core.Object_id.to_raw t.target);
        E.bytes (Core.Record_id.to_raw t.accepted);
        staged;
        E.bytes (Core.Digest.to_raw t.physical_digest);
        E.integer t.expected_generation;
        E.bytes (Raw.Stored_object_id.to_raw_bytes t.expected_root);
        E.integer t.created_at;
        phase;
        E.integer t.serial;
        E.bool t.acknowledged;
      ]
  in
  Ok (E.encode value)

let object_id bytes =
  Raw.Stored_object_id.of_raw_bytes bytes
  |> Option.to_result ~none:"malformed integration object reference"

let minimum_serial = function
  | Prepared -> 0L
  | Applying -> 1L
  | Materialized -> 2L
  | Committed -> 3L
  | Completed -> 4L
  | Paused (Before_apply, _) -> 1L
  | Paused (During_apply, _) -> 2L
  | Paused (Before_commit, _) -> 3L

let[@warning "-4"] decode store scope token bytes =
  let* value = E.decode bytes |> Result.map_error E.decode_error_to_string in
  match value with
  | E.Array
      [
        E.Integer 1L;
        E.Bytes plan;
        E.Bytes plan_object;
        E.Bytes branch;
        E.Bytes workspace;
        E.Integer source;
        E.Integer target_sequence;
        E.Bytes safety;
        E.Bytes target;
        E.Bytes accepted;
        E.Array staged;
        E.Bytes physical_digest;
        E.Integer expected_generation;
        E.Bytes expected_root;
        E.Integer created_at;
        phase;
        E.Integer serial;
        E.Bool acknowledged;
      ] ->
      let* plan = Core.Plan_id.of_raw plan |> model in
      let* plan_object = object_id plan_object in
      let* branch = Core.Branch_id.of_raw branch |> model in
      let* workspace = Core.Workspace_id.of_raw workspace |> model in
      let* source = Core.History_id.make ~workspace ~sequence:source |> model in
      let* safety = Core.Object_id.of_raw safety |> model in
      let* target = Core.Object_id.of_raw target |> model in
      let* accepted = Core.Record_id.of_raw accepted |> model in
      let* physical_digest = Core.Digest.of_raw physical_digest |> model in
      let* expected_root = object_id expected_root in
      let* staged =
        traverse
          (function
            | E.Array [ E.Bytes id; E.Bytes obj ] ->
                let* id = Core.Record_id.of_raw id |> model in
                let* obj = object_id obj in
                Ok (id, obj)
            | _ -> Error "malformed staged integration records")
          staged
      in
      let* phase =
        match phase with
        | E.Array [ E.Integer 0L ] -> Ok Prepared
        | E.Array [ E.Integer 1L ] -> Ok Applying
        | E.Array [ E.Integer 2L ] -> Ok Materialized
        | E.Array [ E.Integer 3L ] -> Ok Committed
        | E.Array [ E.Integer 4L ] -> Ok Completed
        | E.Array [ E.Integer 5L; E.Integer code; E.Text detail ]
          when detail <> "" && String.length detail <= 4096 ->
            let* stage =
              match code with
              | 0L -> Ok Before_apply
              | 1L -> Ok During_apply
              | 2L -> Ok Before_commit
              | _ -> Error "invalid paused integration stage"
            in
            Ok (Paused (stage, detail))
        | _ -> Error "unsupported integration operation phase"
      in
      let* ( expected_branch,
             cursor,
             working_basis,
             expected_safety,
             _,
             expected_target,
             protected ) =
        plan_outputs store scope plan plan_object
      in
      let t =
        {
          token;
          plan;
          plan_object;
          branch;
          source;
          plan_cursor = cursor;
          working_basis;
          protected;
          target_sequence;
          safety;
          target;
          accepted;
          staged;
          physical_digest;
          expected_generation;
          expected_root;
          created_at;
          phase;
          serial;
          acknowledged;
        }
      in
      let* canonical = encode t in
      if
        canonical <> bytes || created_at < 0L || expected_generation < 0L
        || serial < minimum_serial phase
        || target_sequence <= Core.History_id.sequence source
        || (not
              (Core.Workspace_id.equal workspace
                 (Core.History_id.workspace cursor)))
        || Core.History_id.sequence source < Core.History_id.sequence cursor
        || (not (Core.Branch_id.equal branch expected_branch))
        || (not (Core.Object_id.equal safety expected_safety))
        || (not (Core.Object_id.equal target expected_target))
        || List.length staged > 2
        || staged
           <> List.sort_uniq
                (fun (a, _) (b, _) -> Core.Record_id.compare a b)
                staged
        || (acknowledged && not (committed t))
      then Error "noncanonical or inconsistent integration operation"
      else Ok t
  | _ -> Error "unsupported integration operation schema"

let namespace scope =
  "local-integration-operations-v1\000" ^ Core.Repository_id.to_raw scope

let store store ~scope operations =
  let* rows =
    traverse
      (fun t ->
        let* value = encode t in
        Ok (Core.Operation_id.to_raw t.token, value))
      operations
  in
  Pages.store store ~namespace:(namespace scope) rows
  |> Result.map_error Pages.error_to_string

let load store ~scope root =
  let* rows =
    Pages.load_bounded store ~namespace:(namespace scope) ~max_rows:100000
      ~max_value_bytes:8192
      ~max_total_value_bytes:(64 * 1024 * 1024)
      root
    |> Result.map_error Pages.error_to_string
  in
  traverse
    (fun (key, value) ->
      let* token = Core.Operation_id.of_raw key |> model in
      decode store scope token value)
    rows

let validate_history history operations =
  let* _ =
    traverse
      (fun t ->
        let* source =
          History.find history (Core.History_id.sequence t.source)
        in
        let* identity = History.identity history source in
        if
          (not (Core.History_id.equal identity t.source))
          || Yeokcham_v1_model.Snapshot_id.to_string source.History.snapshot
             <> Core.Object_id.to_hex t.safety
          || source.History.id <> Core.History_id.sequence t.plan_cursor
             && source.History.parent
                <> Some (Core.History_id.sequence t.plan_cursor)
        then
          Error "integration safety history payload/namespace/ancestry mismatch"
        else if not (committed t) then
          if
            (History.current history).History.id = source.History.id
            && History.next_sequence history = Some t.target_sequence
          then Ok ()
          else
            Error
              "pending integration owns its exact safety cursor and next \
               history sequence"
        else
          let* target = History.find history t.target_sequence in
          if
            target.History.parent <> Some source.History.id
            || Yeokcham_v1_model.Snapshot_id.to_string target.History.snapshot
               <> Core.Object_id.to_hex t.target
            || target.History.created_at <> t.created_at
          then
            Error
              "committed integration history does not match its exact operation"
          else Ok ())
      operations
  in
  if List.length (List.filter pending operations) > 1 then
    Error "more than one integration owns this workspace"
  else Ok ()

let[@warning "-4"] control_inputs store t =
  let* envelope =
    Raw.get ~max_bytes:(8 * 1024 * 1024) store t.plan_object
    |> Result.map_error Raw.error_to_string
  in
  let ids = function
    | E.Array xs when List.length xs <= Core.max_references ->
        let* xs =
          traverse
            (function
              | E.Bytes raw -> Core.Record_id.of_raw raw |> model
              | _ -> Error "malformed integration control reference")
            xs
        in
        if xs = List.sort_uniq Core.Record_id.compare xs then Ok xs
        else Error "noncanonical integration control references"
    | _ -> Error "invalid integration control references"
  in
  match Envelope.payload envelope with
  | E.Array
      [
        E.Integer 1L;
        E.Array
          [
            _repo;
            _branch;
            events;
            heads;
            revisions;
            _resolutions;
            _authority;
            _policies;
            _evidence;
            _workspace;
            _profile;
          ];
        _selection;
        _filesystem;
        _known;
        _accepted;
        _ready;
        _no_op;
      ] ->
      let* events = ids events in
      let* heads = ids heads in
      let* revisions = ids revisions in
      Ok (events, heads, revisions)
  | _ -> Error "malformed integration control inputs"

let[@warning "-4"] validate ~store ~authority pool operations =
  let* _ =
    traverse
      (fun t ->
        let* _, _, _, _, accepted_snapshot, _, _ =
          plan_outputs store (Core.pool_repository pool) t.plan t.plan_object
        in
        let* staged =
          traverse
            (fun (id, obj) ->
              let* envelope =
                Raw.get ~max_bytes:Record.max_record_bytes store obj
                |> Result.map_error Raw.error_to_string
              in
              let* signed =
                Record.decode
                  ~repository:(Core.pool_repository pool)
                  (Envelope.encode envelope)
                |> Result.map_error Record.error_to_string
              in
              let* actual =
                Record.id signed |> Result.map_error Record.error_to_string
              in
              let* () =
                Trust.Core.verify authority signed
                |> Result.map_error Trust.Core.error_to_string
              in
              if not (Core.Record_id.equal id actual) then
                Error "staged integration record identity mismatch"
              else Ok (id, Record.body signed))
            t.staged
        in
        let rec retain current pending =
          match pending with
          | [] -> Ok current
          | _ ->
              let* current, remaining =
                List.fold_left
                  (fun acc (id, body) ->
                    let* current, rest = acc in
                    match Core.retain current ~id body with
                    | Ok (current, _) -> Ok (current, rest)
                    | Error (Core.Missing_reference _) ->
                        Ok (current, (id, body) :: rest)
                    | Error e -> Error (Core.error_to_string e))
                  (Ok (current, []))
                  pending
              in
              if List.length remaining = List.length pending then
                Error "missing staged integration reference"
              else retain current remaining
        in
        let* candidate = retain pool staged in
        let* version =
          Composition.Graph.accepted candidate t.accepted
          |> Result.map_error Composition.Graph.error_to_string
        in
        let* () =
          Composition.Graph.validate store candidate
          |> Result.map_error Composition.Graph.error_to_string
        in
        let* events, heads, revisions = control_inputs store t in
        let* () =
          match staged with
          | [] ->
              let* represented =
                Composition.Graph.represented pool [ t.accepted ]
                |> Result.map_error Composition.Graph.error_to_string
              in
              if
                heads = [ t.accepted ]
                && List.for_all
                     (fun id ->
                       List.exists (Core.Record_id.equal id) represented)
                     revisions
              then Ok ()
              else
                Error
                  "existing acceptance does not represent this integration \
                   selection"
          | [ _; _ ] ->
              let accepted =
                List.filter
                  (fun (id, body) ->
                    Core.Record_id.equal id t.accepted
                    && body.Core.payload = Core.Accepted_version version)
                  staged
              in
              let expected_action =
                if List.length events > 1 then Core.Reconcile else Core.Advance
              in
              let event =
                List.filter
                  (fun (_, body) ->
                    match body.Core.payload with
                    | Core.Branch_event event ->
                        Core.Branch_id.equal event.Core.branch t.branch
                        && event.Core.previous_events = events
                        && event.Core.targets = [ t.accepted ]
                        && event.Core.action = expected_action
                        && event.Core.display_name = None
                    | _ -> false)
                  staged
              in
              if
                List.length accepted = 1
                && List.length event = 1
                && version.Core.accepted_parents = heads
                && version.Core.chosen_revisions = revisions
                && version.Core.resolutions = []
                && version.Core.policy_heads = []
                && version.Core.review_evidence = []
              then Ok ()
              else
                Error
                  "staged acceptance/event does not bind the exact integration \
                   inputs"
          | _ -> Error "integration must stage its exact acceptance/event pair"
        in
        if
          (not (Core.Branch_id.equal version.Core.branch t.branch))
          || not
               (Core.Object_id.equal version.Core.result_snapshot
                  accepted_snapshot)
        then Error "staged acceptance does not match integration plan"
        else if
          committed t
          && (Core.find pool t.accepted = None
             || List.exists (fun (id, _) -> Core.find pool id = None) t.staged)
        then
          Error
            "committed integration records are missing from the authoritative \
             pool"
        else Ok ())
      operations
  in
  let plans = List.map (fun t -> t.plan) operations in
  if
    List.length plans <> List.length (List.sort_uniq Core.Plan_id.compare plans)
  then Error "integration plan is associated with more than one operation"
  else Ok ()
