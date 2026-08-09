module Address = Yeokcham_v2_address
module Envelope = Yeokcham_v2_envelope
module Ledger = Yeokcham_v2_ledger
module Ledger_store = Yeokcham_v2_ledger_store
module Model = Yeokcham_v2_model
module Object = Yeokcham_v2_object
module Transaction_store = Yeokcham_v2_transaction_store

type repository = {
  repository_id : Model.Repository_id.t;
  ledger : Ledger_store.repository;
  transactions : Transaction_store.repository;
}

type report = {
  verified_objects : int;
  verified_events : int;
  verified_refs : int;
  causal_heads : int;
  unresolved_divergences : int;
  prepared_transactions : int;
  committed_transactions : int;
}

type error =
  | Ledger_store_error of Ledger_store.error
  | Transaction_store_error of Transaction_store.error
  | Object_error of {
      object_ref : Model.Opaque_object_ref.t;
      path : string;
      error : Ledger_store.error;
    }
  | Causal_error of { ref_name : Ledger.Ref_name.t; error : Ledger.error }

type loaded_event = { verified : Ledger.verified; ref_name : Ledger.Ref_name.t }

type ref_events = {
  scope_name : Ledger.Ref_name.t;
  events : Ledger.verified list;
}

let ( let* ) = Result.bind

let error_to_string = function
  | Ledger_store_error error -> Ledger_store.error_to_string error
  | Transaction_store_error error -> Transaction_store.error_to_string error
  | Object_error { object_ref; path; error } ->
      Printf.sprintf "V2 object %s at %s failed verification: %s"
        (Model.Opaque_object_ref.to_hex object_ref)
        path
        (Ledger_store.error_to_string error)
  | Causal_error { ref_name; error } ->
      Printf.sprintf "V2 causal ledger for ref %s failed verification: %s"
        (Ledger.Ref_name.to_string ref_name)
        (Ledger.error_to_string error)

let open_repository ~root ~repository_id ~address_key ~encryption_key
    ~public_keys =
  let* ledger =
    Ledger_store.open_repository ~root ~repository_id ~address_key
      ~encryption_key ~public_keys
    |> Result.map_error (fun error -> Ledger_store_error error)
  in
  let* transactions =
    Transaction_store.open_repository ~root ~repository_id ~address_key
      ~encryption_key ~public_keys
    |> Result.map_error (fun error -> Transaction_store_error error)
  in
  Ok { repository_id; ledger; transactions }

let load_events repository =
  let* object_refs =
    Ledger_store.list_object_refs repository.ledger
    |> Result.map_error (fun error -> Ledger_store_error error)
  in
  let rec load result = function
    | [] -> Ok (List.rev result)
    | object_ref :: rest -> (
        let path = Ledger_store.object_path repository.ledger object_ref in
        let* object_ =
          Ledger_store.load_object repository.ledger ~object_ref
          |> Result.map_error (fun error ->
              Object_error { object_ref; path; error })
        in
        match Object.ledger object_ with
        | None -> load result rest
        | Some _ ->
            let* verified =
              Ledger_store.load repository.ledger ~object_ref
              |> Result.map_error (fun error ->
                  Object_error { object_ref; path; error })
            in
            let event = Ledger.verified_event verified in
            let ref_name =
              Ledger.event_unsigned event |> Ledger.unsigned_ref_name
            in
            load ({ verified; ref_name } :: result) rest)
  in
  let* events = load [] object_refs in
  Ok (object_refs, events)

let group_by_ref events =
  let ordered =
    List.sort
      (fun left right -> Ledger.Ref_name.compare left.ref_name right.ref_name)
      events
  in
  let rec collect result = function
    | [] -> List.rev result
    | first :: rest ->
        let rec same_scope scoped = function
          | candidate :: tail
            when Ledger.Ref_name.equal first.ref_name candidate.ref_name ->
              same_scope (candidate.verified :: scoped) tail
          | remaining -> (List.rev scoped, remaining)
        in
        let scoped, remaining = same_scope [ first.verified ] rest in
        collect
          ({ scope_name = first.ref_name; events = scoped } :: result)
          remaining
  in
  collect [] ordered

let evaluate_scopes repository scopes =
  let rec evaluate heads divergences = function
    | [] -> Ok (heads, divergences)
    | scope :: rest ->
        let* result =
          Ledger.evaluate ~repository_id:repository.repository_id
            ~ref_name:scope.scope_name scope.events
          |> Result.map_error (fun error ->
              Causal_error { ref_name = scope.scope_name; error })
        in
        evaluate
          (heads + List.length (Ledger.heads result))
          (divergences + List.length (Ledger.divergences result))
          rest
  in
  evaluate 0 0 scopes

let verify repository =
  let* journal =
    Transaction_store.verify repository.transactions
    |> Result.map_error (fun error -> Transaction_store_error error)
  in
  let* object_refs, events = load_events repository in
  let scopes = group_by_ref events in
  let* causal_heads, unresolved_divergences =
    evaluate_scopes repository scopes
  in
  let { Transaction_store.prepared_transactions; committed_transactions } =
    journal
  in
  Ok
    {
      verified_objects = List.length object_refs;
      verified_events = List.length events;
      verified_refs = List.length scopes;
      causal_heads;
      unresolved_divergences;
      prepared_transactions = List.length prepared_transactions;
      committed_transactions = List.length committed_transactions;
    }
