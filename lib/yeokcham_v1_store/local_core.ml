module Core = Yeokcham_v1_model.Core
module Record = Yeokcham_v1_record.Core
module Trust = Yeokcham_v1_trust
module Store = Yeokcham_store
module Snapshot = Yeokcham_snapshot
module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Composition = Yeokcham_v1_composition
module Operation = Integration_operation

[@@@warning "-42"]

let ( let* ) = Result.bind
let model r = Result.map_error Core.error_to_string r
let record r = Result.map_error Record.error_to_string r
let stored r = Result.map_error Store.error_to_string r
let snapshot r = Result.map_error Snapshot.error_to_string r
let trust r = Result.map_error Trust.Core.error_to_string r
let construction r = Result.map_error Encoding.construction_error_to_string r
let array fields = Encoding.array fields |> construction

type position = {
  branch : Core.Branch_id.t;
  cursor : int64;
  basis : Core.Record_id.t;
}

type publication = Publication_receipt.t = {
  operation : Core.Operation_id.t;
  intent : Core.Digest.t;
  revision : Core.Record_id.t;
  publication_branch : Core.Branch_id.t;
  source : Core.History_id.t;
  observed : Core.Object_id.t;
  contributed_scope : Core.Object_id.t;
  title : string;
  witness_root : Store.Stored_object_id.t;
  witnesses : Store.Stored_object_id.t list;
}

type t = {
  pool : Core.pool;
  records : (Core.Record_id.t * Store.Stored_object_id.t) list;
  empty : Core.Object_id.t;
  selected_branch : Core.Branch_id.t;
  positions : position list;
  publications : publication list;
  publication_root : Store.Stored_object_id.t option;
  operations : Operation.t list;
  operation_root : Store.Stored_object_id.t option;
}

let positions state = state.positions
let branches state = Core.branch_states state.pool
let empty_snapshot state = state.empty
let pool state = state.pool
let record_objects state = state.records
let publications state = state.publications
let operations state = state.operations
let pending_operation state = List.find_opt Operation.pending state.operations

let find_operation state ~plan =
  List.find_opt
    (fun operation -> Core.Plan_id.equal plan operation.Operation.plan)
    state.operations

let put_operation ~store operation state =
  let* () =
    match
      List.find_opt
        (fun previous ->
          Core.Operation_id.equal previous.Operation.token
            operation.Operation.token)
        state.operations
    with
    | Some previous -> Operation.validate_update ~previous operation
    | None ->
        if
          operation.Operation.phase <> Operation.Prepared
          || operation.Operation.serial <> 0L
          || operation.Operation.acknowledged
        then Error "a new integration operation must begin Prepared"
        else if Option.is_some (pending_operation state) then
          Error "another integration operation is incomplete"
        else if
          List.exists
            (fun p ->
              Core.Operation_id.equal p.operation operation.Operation.token)
            state.publications
        then Error "integration operation token collides with a publication"
        else if
          Option.is_some (find_operation state ~plan:operation.Operation.plan)
        then Error "this plan already has a durable integration operation"
        else Ok ()
  in
  let operations =
    operation
    :: List.filter
         (fun previous ->
           not
             (Core.Operation_id.equal previous.Operation.token
                operation.Operation.token))
         state.operations
    |> List.sort (fun a b ->
        Core.Operation_id.compare a.Operation.token b.Operation.token)
  in
  let* root =
    Operation.store store ~scope:(Core.pool_repository state.pool) operations
  in
  Ok { state with operations; operation_root = Some root }

let find_publication state ~intent =
  List.find_opt (fun p -> Core.Digest.equal p.intent intent) state.publications

let record_publication_using ~random_bytes ~store ~intent ~revision ~source
    ~observed ~contributed_scope ~title state =
  let* publications, receipt =
    Publication_receipt.add ~random_bytes store state.pool
      ~branch:state.selected_branch ~intent ~revision ~source ~observed
      ~contributed_scope ~title state.publications
  in
  let* () =
    if
      List.exists
        (fun operation ->
          Core.Operation_id.equal operation.Operation.token receipt.operation)
        state.operations
    then Error "publication token collides with an integration operation"
    else Ok ()
  in
  let* root =
    Publication_receipt.store store
      ~scope:(Core.pool_repository state.pool)
      publications
  in
  Ok ({ state with publications; publication_root = Some root }, receipt)

let record_publication =
  record_publication_using ~random_bytes:Trust.random_bytes

let validate_history history state =
  let* () = Publication_receipt.validate_history history state.publications in
  let* () = Operation.validate_history history state.operations in
  match pending_operation state with
  | None -> Ok ()
  | Some operation
    when Core.Branch_id.equal operation.Operation.branch state.selected_branch
         && (Operation.committed operation
            || List.exists
                 (fun position ->
                   Core.Branch_id.equal position.branch
                     operation.Operation.branch
                   && Core.Record_id.equal position.basis
                        operation.Operation.working_basis)
                 state.positions) ->
      Ok ()
  | Some _ -> Error "pending integration owns the selected branch"

let selected state =
  List.find
    (fun p -> Core.Branch_id.equal p.branch state.selected_branch)
    state.positions

let canonical_empty () =
  let* tree = Snapshot.Tree.create [] |> snapshot in
  let* tree_id = Snapshot.Tree.id tree |> snapshot in
  let value = Snapshot.Snapshot.create ~root:tree_id in
  let* identity = Snapshot.Snapshot.id value |> snapshot in
  let* object_id =
    Core.Object_id.of_raw
      (Store.Stored_object_id.to_raw_bytes
         (Snapshot.Snapshot.stored_object_id identity))
    |> model
  in
  Ok (tree, value, object_id)

let repository authority =
  Core.Repository_id.of_hex
    (Trust.Repository_id.to_string
       (Trust.repository (Trust.authority_membership authority)))
  |> model

let current_context authority certificate =
  match Trust.authority_heads authority with
  | [ _ ] as heads ->
      let* repository = repository authority in
      let* author_certificate = Core.Digest.of_hex certificate |> model in
      let* authority_heads =
        List.fold_left
          (fun result head ->
            let* heads = result in
            let* head = Core.Digest.of_hex head |> model in
            Ok (head :: heads))
          (Ok []) heads
      in
      Core.make_context ~repository ~author_certificate ~authority_heads
        ~display_time:None
      |> model
  | [] -> Error "branch operation requires an active authority head"
  | _ ->
      Error "branch operation requires explicit authority-fork reconciliation"

let persist_record ~store ~authority ~certificate ~signing_capability state
    payload =
  let* context = current_context authority certificate in
  let* signed =
    Trust.Core.sign authority signing_capability
      (Core.make_body ~context ~payload)
    |> trust
  in
  let* bytes = Record.encode signed |> record in
  let* id = Record.id signed |> record in
  let* pool, _ = Trust.Core.receive authority state.pool bytes |> trust in
  let* envelope =
    Envelope.decode bytes |> Result.map_error Envelope.decode_error_to_string
  in
  let* stored_id = Store.put store envelope |> stored in
  match
    List.find_opt
      (fun (existing, _) -> Core.Record_id.equal existing id)
      state.records
  with
  | Some (_, previous)
    when not (Store.Stored_object_id.equal previous stored_id) ->
      Error "core record identity collision"
  | None | Some _ ->
      Ok
        ( {
            state with
            pool;
            records =
              List.sort_uniq
                (fun (a, _) (b, _) -> Core.Record_id.compare a b)
                ((id, stored_id) :: state.records);
          },
          id )

let fresh_branch ~random_bytes state =
  let rec attempt remaining =
    let* id = Core.Branch_id.generate ~random_bytes () |> model in
    if
      List.exists
        (fun state -> Core.Branch_id.equal state.Core.branch_id id)
        (branches state)
    then
      if remaining = 1 then
        Error "branch identity collision after three attempts"
      else attempt (remaining - 1)
    else Ok id
  in
  attempt 3

let accepted branch parents result =
  Core.make_accepted_version ~branch ~accepted_parents:parents
    ~chosen_revisions:[] ~resolutions:[] ~result_snapshot:result
    ~composition_profile:"line-hunks-v1" ~policy_heads:[] ~review_evidence:[]
  |> model
  |> Result.map (fun v -> Core.Accepted_version v)

let create_event branch name target =
  Core.make_branch_event ~branch ~previous_events:[] ~action:Core.Create
    ~targets:[ target ] ~display_name:(Some name)
  |> model
  |> Result.map (fun v -> Core.Branch_event v)

let unambiguous state branch =
  match
    List.find_opt
      (fun row -> Core.Branch_id.equal row.Core.branch_id branch)
      (branches state)
  with
  | Some
      {
        Core.event_heads = [ _ ];
        accepted_heads = [ basis ];
        display_names = [ _ ];
        _;
      } ->
      Ok basis
  | Some _ ->
      Error
        "branch has divergent accepted heads or names; an explicit \
         reconciliation is required"
  | None -> Error "unknown branch identity"

let lookup state name =
  let matching =
    branches state
    |> List.filter (fun row -> List.mem name row.Core.display_names)
  in
  match matching with
  | [ row ] -> (
      let* basis = unambiguous state row.Core.branch_id in
      match
        List.find_opt
          (fun p -> Core.Branch_id.equal p.branch row.Core.branch_id)
          state.positions
      with
      | Some position when Core.Record_id.equal position.basis basis ->
          Ok position
      | Some _ ->
          Error
            "private branch basis differs from the accepted head; integration \
             is required"
      | None -> Error "branch has no local working position")
  | [] -> Error (Printf.sprintf "unknown branch %S; inspect branch list" name)
  | _ ->
      Error
        (Printf.sprintf
           "branch name %S is ambiguous; select/reconcile its identities \
            explicitly"
           name)

let add_branch ~random_bytes ~store ~authority ~certificate ~signing_capability
    ~name ~cursor ~parents state =
  let* () = Core.validate_branch_name name |> model in
  if Int64.compare cursor 0L < 0 then Error "branch cursor must be nonnegative"
  else if
    List.exists
      (fun row -> List.mem name row.Core.display_names)
      (branches state)
  then
    Error
      (Printf.sprintf "branch name %S already exists; it was not retargeted"
         name)
  else
    let* branch = fresh_branch ~random_bytes state in
    let* result =
      match parents with
      | [] -> Ok state.empty
      | [ id ] ->
          Composition.Graph.accepted state.pool id
          |> Result.map (fun (value : Core.accepted_version) ->
              value.Core.result_snapshot)
          |> Result.map_error Composition.Graph.error_to_string
      | _ -> Error "new branch needs one explicitly selected accepted basis"
    in
    let* payload = accepted branch parents result in
    let* state, basis =
      persist_record ~store ~authority ~certificate ~signing_capability state
        payload
    in
    let* payload = create_event branch name basis in
    let* state, _ =
      persist_record ~store ~authority ~certificate ~signing_capability state
        payload
    in
    Ok
      ( {
          state with
          positions =
            List.sort
              (fun a b -> Core.Branch_id.compare a.branch b.branch)
              ({ branch; cursor; basis } :: state.positions);
        },
        branch )

let initialize ~store ~authority ~certificate ~signing_capability ~cursor =
  let* tree, value, empty = canonical_empty () in
  let* _ = Snapshot.Tree.store store tree |> snapshot in
  let* _ = Snapshot.Snapshot.store store value |> snapshot in
  let* repository = repository authority in
  (* this temporary selector is replaced before the state escapes *)
  let* temporary = Core.Branch_id.of_raw (String.make 16 '\000') |> model in
  let state =
    {
      pool = Core.empty_pool ~repository;
      records = [];
      empty;
      selected_branch = temporary;
      positions = [];
      publications = [];
      publication_root = None;
      operations = [];
      operation_root = None;
    }
  in
  let* state, branch =
    add_branch ~random_bytes:Trust.random_bytes ~store ~authority ~certificate
      ~signing_capability ~name:"main" ~cursor ~parents:[] state
  in
  Ok { state with selected_branch = branch }

let create_branch_using ~random_bytes ~store ~authority ~certificate
    ~signing_capability ~name ~cursor state =
  let* basis = unambiguous state state.selected_branch in
  add_branch ~random_bytes ~store ~authority ~certificate ~signing_capability
    ~name ~cursor ~parents:[ basis ] state
  |> Result.map fst

let create_branch ~store ~authority ~certificate ~signing_capability ~name
    ~cursor state =
  create_branch_using ~random_bytes:Trust.random_bytes ~store ~authority
    ~certificate ~signing_capability ~name ~cursor state

let remember state ~cursor =
  if Int64.compare cursor 0L < 0 then Error "branch cursor must be nonnegative"
  else
    Ok
      {
        state with
        positions =
          List.map
            (fun position ->
              if Core.Branch_id.equal position.branch state.selected_branch then
                { position with cursor }
              else position)
            state.positions;
      }

let select state branch =
  let* _ = unambiguous state branch in
  if List.exists (fun p -> Core.Branch_id.equal p.branch branch) state.positions
  then Ok { state with selected_branch = branch }
  else Error "branch has no private position"

let encode state =
  let* record_values =
    List.fold_left
      (fun result (id, stored_id) ->
        let* values = result in
        let* value =
          array
            [
              Encoding.bytes (Core.Record_id.to_raw id);
              Encoding.bytes (Store.Stored_object_id.to_raw_bytes stored_id);
            ]
        in
        Ok (value :: values))
      (Ok []) state.records
  in
  let* records = array (List.rev record_values) in
  let* positions =
    List.fold_left
      (fun result position ->
        let* values = result in
        let* value =
          array
            [
              Encoding.bytes (Core.Branch_id.to_raw position.branch);
              Encoding.integer position.cursor;
              Encoding.bytes (Core.Record_id.to_raw position.basis);
            ]
        in
        Ok (value :: values))
      (Ok []) state.positions
  in
  let* positions = array (List.rev positions) in
  let fields =
    [
      Encoding.bytes (Core.Object_id.to_raw state.empty);
      Encoding.bytes (Core.Branch_id.to_raw state.selected_branch);
      records;
      positions;
    ]
  in
  let* publication_fields =
    match (state.publication_root, state.publications) with
    | None, [] -> Ok Encoding.null
    | Some root, _ :: _ ->
        Ok (Encoding.bytes (Store.Stored_object_id.to_raw_bytes root))
    | _ -> Error "publication root and receipts disagree"
  in
  let* value =
    match
      ( state.operation_root,
        state.operations,
        state.publication_root,
        state.publications )
    with
    | Some root, _ :: _, _, _ ->
        array
          ((Encoding.integer 3L :: fields)
          @ [
              publication_fields;
              Encoding.bytes (Store.Stored_object_id.to_raw_bytes root);
            ])
    | None, [], None, [] -> array (Encoding.integer 1L :: fields)
    | None, [], Some root, _ :: _ ->
        array
          ((Encoding.integer 2L :: fields)
          @ [ Encoding.bytes (Store.Stored_object_id.to_raw_bytes root) ])
    | _ -> Error "operation root and operations disagree"
  in
  Ok (Encoding.encode value)

let[@warning "-4"] decode ~store ~authority bytes =
  let* value =
    Encoding.decode bytes |> Result.map_error Encoding.decode_error_to_string
  in
  let* value, publication_root, operation_root =
    match value with
    | Encoding.Array
        [
          Encoding.Integer 3L;
          empty;
          selected;
          ids;
          positions;
          publication;
          Encoding.Bytes root;
        ] ->
        let* operation_root =
          Store.Stored_object_id.of_raw_bytes root
          |> Option.to_result ~none:"invalid integration operation root"
        in
        let* publication_root =
          match publication with
          | Encoding.Null -> Ok None
          | Encoding.Bytes bytes ->
              Store.Stored_object_id.of_raw_bytes bytes
              |> Option.to_result ~none:"invalid publication root"
              |> Result.map Option.some
          | _ -> Error "invalid publication root"
        in
        let* value =
          array [ Encoding.integer 1L; empty; selected; ids; positions ]
        in
        Ok (value, publication_root, Some operation_root)
    | Encoding.Array
        [
          Encoding.Integer 2L;
          empty;
          selected;
          ids;
          positions;
          Encoding.Bytes root;
        ] ->
        let* root =
          Store.Stored_object_id.of_raw_bytes root
          |> Option.to_result ~none:"invalid publication collection root"
        in
        let* value =
          array [ Encoding.integer 1L; empty; selected; ids; positions ]
        in
        Ok (value, Some root, None)
    | value -> Ok (value, None, None)
  in
  let* empty, selected_branch, ids, positions =
    match value with
    | Encoding.Array
        [
          Encoding.Integer 1L;
          Encoding.Bytes empty;
          Encoding.Bytes selected;
          Encoding.Array ids;
          Encoding.Array positions;
        ] ->
        let* empty = Core.Object_id.of_raw empty |> model in
        let* selected = Core.Branch_id.of_raw selected |> model in
        let* ids =
          List.fold_left
            (fun result -> function
              | Encoding.Array [ Encoding.Bytes id; Encoding.Bytes stored_id ]
                ->
                  let* ids = result in
                  let* id = Core.Record_id.of_raw id |> model in
                  let* stored_id =
                    Store.Stored_object_id.of_raw_bytes stored_id
                    |> Option.to_result
                         ~none:"invalid stored core object identity"
                  in
                  Ok ((id, stored_id) :: ids)
              | _ ->
                  Error
                    "core record reference must contain logical and stored \
                     identities")
            (Ok []) ids
          |> Result.map List.rev
        in
        let* positions =
          List.fold_left
            (fun result -> function
              | Encoding.Array
                  [
                    Encoding.Bytes branch;
                    Encoding.Integer cursor;
                    Encoding.Bytes basis;
                  ]
                when Int64.compare cursor 0L >= 0 ->
                  let* positions = result in
                  let* branch = Core.Branch_id.of_raw branch |> model in
                  let* basis = Core.Record_id.of_raw basis |> model in
                  Ok ({ branch; cursor; basis } :: positions)
              | _ -> Error "invalid local branch position")
            (Ok []) positions
          |> Result.map List.rev
        in
        Ok (empty, selected, ids, positions)
    | _ -> Error "unsupported local core state"
  in
  let* _, _, expected_empty = canonical_empty () in
  if not (Core.Object_id.equal empty expected_empty) then
    Error "local branch genesis must be the canonical empty snapshot"
  else
    let* repository = repository authority in
    let* pending =
      List.fold_left
        (fun result (id, stored_id) ->
          let* values = result in
          let* envelope = Store.get store stored_id |> stored in
          let* signed =
            Record.decode ~repository (Envelope.encode envelope) |> record
          in
          let* actual_id = Record.id signed |> record in
          let* () =
            if Core.Record_id.equal id actual_id then Ok ()
            else
              Error
                "stored core object does not match its logical record identity"
          in
          let* () = Trust.Core.verify authority signed |> trust in
          let body = Record.body signed in
          Ok ((id, body) :: values))
        (Ok []) ids
    in
    let rec retain pool pending =
      match pending with
      | [] -> Ok pool
      | _ ->
          let* pool, remaining, progress =
            List.fold_left
              (fun result (id, body) ->
                let* pool, remaining, progress = result in
                match Core.retain pool ~id body with
                | Ok (pool, _) -> Ok (pool, remaining, true)
                | Error (Core.Missing_reference _) ->
                    Ok (pool, (id, body) :: remaining, progress)
                | Error e -> Error (Core.error_to_string e))
              (Ok (pool, [], false))
              pending
          in
          if progress then retain pool remaining
          else Error "local core records have missing causal references"
    in
    let* pool = retain (Core.empty_pool ~repository) pending in
    let* () =
      Composition.Graph.validate store pool
      |> Result.map_error Composition.Graph.error_to_string
    in
    let* publications =
      match publication_root with
      | None -> Ok []
      | Some root -> Publication_receipt.load store ~scope:repository root
    in
    let* () = Publication_receipt.validate store pool publications in
    let* operations =
      match operation_root with
      | None -> Ok []
      | Some root -> Operation.load store ~scope:repository root
    in
    let* () = Operation.validate ~store ~authority pool operations in
    let* () =
      if
        List.exists
          (fun operation ->
            List.exists
              (fun publication ->
                Core.Operation_id.equal operation.Operation.token
                  publication.operation)
              publications)
          operations
      then Error "duplicate operation token across publication/integration"
      else Ok ()
    in
    let state =
      {
        pool;
        records = ids;
        empty;
        selected_branch;
        positions;
        publications;
        publication_root;
        operations;
        operation_root;
      }
    in
    let branch_ids =
      branches state |> List.map (fun row -> row.Core.branch_id)
    in
    let position_ids = List.map (fun position -> position.branch) positions in
    if
      branch_ids <> position_ids
      || not (List.exists (Core.Branch_id.equal selected_branch) branch_ids)
    then
      Error "local branch positions do not cover the retained branches exactly"
    else
      let* () =
        List.fold_left
          (fun result position ->
            let* () = result in
            match Core.find pool position.basis with
            | Some { Core.payload = Core.Accepted_version _; _ } ->
                let row =
                  List.find
                    (fun row ->
                      Core.Branch_id.equal row.Core.branch_id position.branch)
                    (branches state)
                in
                let rec reachable seen = function
                  | [] -> false
                  | id :: _ when Core.Record_id.equal id position.basis -> true
                  | id :: rest when List.exists (Core.Record_id.equal id) seen
                    ->
                      reachable seen rest
                  | id :: rest -> (
                      match Core.find pool id with
                      | Some { Core.payload = Core.Accepted_version version; _ }
                        ->
                          reachable (id :: seen)
                            (version.Core.accepted_parents @ rest)
                      | _ -> reachable (id :: seen) rest)
                in
                if reachable [] row.Core.accepted_heads then Ok ()
                else
                  Error
                    "private basis is outside the branch's accepted ancestry"
            | _ ->
                Error "private branch basis is not a retained accepted version")
          (Ok ()) positions
      in
      let* canonical = encode state in
      if
        canonical = bytes
        && ids
           = List.sort_uniq
               (fun (a, _) (b, _) -> Core.Record_id.compare a b)
               ids
      then Ok state
      else Error "noncanonical local core state"

module Ids = Map.Make (Core.Record_id)

let validate_update ~previous state =
  let retained =
    List.fold_left
      (fun ids (id, stored) -> Ids.add id stored ids)
      Ids.empty state.records
  in
  if not (Core.Object_id.equal previous.empty state.empty) then
    Error "cannot replace accepted genesis"
  else if
    List.for_all
      (fun (id, stored) ->
        Option.fold ~none:false
          ~some:(Store.Stored_object_id.equal stored)
          (Ids.find_opt id retained))
      previous.records
  then
    if
      List.for_all
        (fun receipt -> List.exists (( = ) receipt) state.publications)
        previous.publications
    then
      let* () =
        List.fold_left
          (fun result operation ->
            let* () = result in
            if
              List.exists
                (fun previous ->
                  Core.Operation_id.equal previous.Operation.token
                    operation.Operation.token)
                previous.operations
            then Ok ()
            else if
              operation.Operation.phase = Operation.Prepared
              && operation.Operation.serial = 0L
              && not operation.Operation.acknowledged
            then Ok ()
            else
              Error
                "new integration operation must begin with its durable \
                 Prepared fact")
          (Ok ()) state.operations
      in
      List.fold_left
        (fun result operation ->
          let* () = result in
          let* current =
            List.find_opt
              (fun current ->
                Core.Operation_id.equal current.Operation.token
                  operation.Operation.token)
              state.operations
            |> Option.to_result
                 ~none:"cannot erase a durable integration operation"
          in
          Operation.validate_update ~previous:operation current)
        (Ok ()) previous.operations
    else Error "cannot erase or alter durable publication receipts"
  else Error "cannot erase authenticated branch records"

let admit_update ~store ~authority ~previous state =
  let pool =
    match previous with
    | Some previous -> previous.pool
    | None -> Core.empty_pool ~repository:(Core.pool_repository state.pool)
  in
  let* pending =
    List.fold_left
      (fun result (id, object_id) ->
        let* pending = result in
        if Option.is_some (Core.find pool id) then Ok pending
        else
          let* envelope = Store.get store object_id |> stored in
          Ok (Envelope.encode envelope :: pending))
      (Ok []) state.records
  in
  let[@warning "-4"] rec receive pool pending =
    match pending with
    | [] -> Ok ()
    | _ ->
        let* pool, remaining, progress =
          List.fold_left
            (fun result bytes ->
              let* pool, remaining, progress = result in
              match Trust.Core.receive authority pool bytes with
              | Ok (pool, _) -> Ok (pool, remaining, true)
              | Error (Trust.Core.Model_error (Core.Missing_reference _)) ->
                  Ok (pool, bytes :: remaining, progress)
              | Error e -> Error (Trust.Core.error_to_string e))
            (Ok (pool, [], false))
            pending
        in
        if progress then receive pool remaining
        else Error "new branch records have missing causal references"
  in
  let* () = receive pool pending in
  Composition.Graph.validate store state.pool
  |> Result.map_error Composition.Graph.error_to_string

let fresh_change_using ~random_bytes state =
  let rec attempt count =
    let* change = Core.Change_id.generate ~random_bytes () |> model in
    if
      List.exists
        (fun (_, body) ->
          match body.Core.payload with
          | Core.Shared_revision value ->
              Core.Change_id.equal change value.Core.change
          | Core.Accepted_version _ | Core.Branch_event _ -> false)
        (Core.records state.pool)
    then
      if count = 1 then Error "change identity collision after three attempts"
      else attempt (count - 1)
    else Ok change
  in
  attempt 3

let prepare_revision ~store ~authority ~certificate ~signing_capability ~change
    ~previous_revisions ~base_snapshot ~result_snapshot ~edit_scope_root
    ~dependencies state =
  let* change =
    match change with
    | Some change -> Ok change
    | None -> fresh_change_using ~random_bytes:Trust.random_bytes state
  in
  let* value =
    Core.make_shared_revision ~change ~previous_revisions ~base_snapshot
      ~result_snapshot ~edit_scope_root ~dependencies
    |> model
  in
  let* () =
    Composition.validate_revision store value
    |> Result.map_error Composition.error_to_string
  in
  let* next, id =
    persist_record ~store ~authority ~certificate ~signing_capability state
      (Core.Shared_revision value)
  in
  let* () =
    Composition.Graph.validate store next.pool
    |> Result.map_error Composition.Graph.error_to_string
  in
  Ok (next, id)

let prepare_acceptance ~store ~authority ~certificate ~signing_capability
    ~parents ~chosen_revisions ~result_snapshot ~cursor state =
  let* row =
    List.find_opt
      (fun row -> Core.Branch_id.equal row.Core.branch_id state.selected_branch)
      (branches state)
    |> Option.to_result ~none:"selected branch is unavailable"
  in
  let parents = List.sort Core.Record_id.compare parents in
  if row.Core.accepted_heads <> parents then
    Error "accepted heads changed; prepare a new integration plan"
  else
    let* expected =
      Composition.Graph.compose store state.pool ~parents
        ~revisions:chosen_revisions
      |> Result.map_error Composition.Graph.error_to_string
    in
    let* actual =
      Composition.load store result_snapshot
      |> Result.map_error Composition.error_to_string
    in
    if Composition.differences expected actual <> [] then
      Error "accepted result does not match exact composition"
    else
      let* value =
        Core.make_accepted_version ~branch:state.selected_branch
          ~accepted_parents:parents ~chosen_revisions ~resolutions:[]
          ~result_snapshot ~composition_profile:"line-hunks-v1" ~policy_heads:[]
          ~review_evidence:[]
        |> model
      in
      let* state, id =
        persist_record ~store ~authority ~certificate ~signing_capability state
          (Core.Accepted_version value)
      in
      let action =
        if List.length row.Core.event_heads > 1 then Core.Reconcile
        else Core.Advance
      in
      let* event =
        Core.make_branch_event ~branch:state.selected_branch
          ~previous_events:row.Core.event_heads ~action ~targets:[ id ]
          ~display_name:None
        |> model
      in
      let* state, _ =
        persist_record ~store ~authority ~certificate ~signing_capability state
          (Core.Branch_event event)
      in
      let* state = remember state ~cursor in
      let state =
        {
          state with
          positions =
            List.map
              (fun position ->
                if Core.Branch_id.equal position.branch state.selected_branch
                then { position with basis = id }
                else position)
              state.positions;
        }
      in
      let* () =
        Composition.Graph.validate store state.pool
        |> Result.map_error Composition.Graph.error_to_string
      in
      Ok (state, id)

let[@warning "-4"] commit_operation ~store ~authority operation state =
  let* current =
    find_operation state ~plan:operation.Operation.plan
    |> Option.to_result ~none:"integration operation is not durable"
  in
  if current <> operation || operation.Operation.phase <> Operation.Materialized
  then Error "only the exact durable Materialized operation can commit"
  else
    let* pending =
      List.fold_left
        (fun acc (id, obj) ->
          let* pending = acc in
          let* envelope = Store.get store obj |> stored in
          Ok ((id, Envelope.encode envelope) :: pending))
        (Ok []) operation.Operation.staged
    in
    let rec receive pool pending =
      match pending with
      | [] -> Ok pool
      | _ ->
          let* pool, remaining =
            List.fold_left
              (fun acc (id, bytes) ->
                let* pool, remaining = acc in
                match Trust.Core.receive authority pool bytes with
                | Ok (pool, _) -> Ok (pool, remaining)
                | Error (Trust.Core.Model_error (Core.Missing_reference _)) ->
                    Ok (pool, (id, bytes) :: remaining)
                | Error e -> Error (Trust.Core.error_to_string e))
              (Ok (pool, []))
              pending
          in
          if List.length remaining = List.length pending then
            Error "missing integration signed dependency"
          else receive pool remaining
    in
    let* pool = receive state.pool pending in
    let records =
      List.sort_uniq
        (fun (a, _) (b, _) -> Core.Record_id.compare a b)
        (operation.Operation.staged @ state.records)
    in
    let state =
      {
        state with
        pool;
        records;
        positions =
          List.map
            (fun p ->
              if Core.Branch_id.equal p.branch operation.Operation.branch then
                {
                  p with
                  cursor = operation.Operation.target_sequence;
                  basis = operation.Operation.accepted;
                }
              else p)
            state.positions;
      }
    in
    let* committed = Operation.advance operation Operation.Committed in
    put_operation ~store committed state

module For_test = struct
  let create_branch = create_branch_using
  let fresh_change = fresh_change_using
  let record_publication = record_publication_using
end
