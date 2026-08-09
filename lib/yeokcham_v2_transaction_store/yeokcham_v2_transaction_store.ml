module Address = Yeokcham_v2_address
module Envelope = Yeokcham_v2_envelope
module Ledger = Yeokcham_v2_ledger
module Ledger_store = Yeokcham_v2_ledger_store
module Model = Yeokcham_v2_model
module Transaction = Yeokcham_v2_transaction

type repository = { journal : string; ledger : Ledger_store.repository }

type prepare_outcome =
  | Prepared of Transaction.prepare
  | Already_prepared of Transaction.prepare

type commit_outcome = Committed | Already_committed

type recovery_outcome = {
  discarded_prepares : Transaction.Transaction_id.t list;
  completed_transactions : Transaction.Transaction_id.t list;
}

type verification_report = {
  prepared_transactions : Transaction.Transaction_id.t list;
  committed_transactions : Transaction.Transaction_id.t list;
}

type error =
  | Ledger_store_error of Ledger_store.error
  | Transaction_error of Transaction.error
  | Repository_mismatch of {
      expected : Model.Repository_id.t;
      actual : Model.Repository_id.t;
    }
  | Candidate_address_mismatch of {
      transaction_id : Transaction.Transaction_id.t;
      expected : Model.Opaque_object_ref.t;
      actual : Model.Opaque_object_ref.t;
    }
  | Journal_collision of string
  | Journal_entry_changed of string
  | Stray_commit of Transaction.Transaction_id.t
  | Io_error of { operation : string; path : string; message : string }
  | Invalid_journal_path of string

type prepare_entry = {
  prepare_id : Transaction.Transaction_id.t;
  prepared : Transaction.prepare;
  prepare_bytes : string;
}

type commit_entry = {
  commit_id : Transaction.Transaction_id.t;
  committed : Transaction.commit;
  commit_bytes : string;
}

type journal_state = {
  prepares : prepare_entry list;
  commits : commit_entry list;
}

type write_outcome = Written | Already_present

let max_temporary_attempts = 32
let ( let* ) = Result.bind

let error_to_string = function
  | Ledger_store_error error -> Ledger_store.error_to_string error
  | Transaction_error error -> Transaction.error_to_string error
  | Repository_mismatch { expected; actual } ->
      Printf.sprintf "V2 transaction repository %s does not match repository %s"
        (Model.Repository_id.to_hex actual)
        (Model.Repository_id.to_hex expected)
  | Candidate_address_mismatch { transaction_id; expected; actual } ->
      Printf.sprintf
        "V2 transaction %s candidate address %s does not match declared %s"
        (Transaction.Transaction_id.to_hex transaction_id)
        (Model.Opaque_object_ref.to_hex actual)
        (Model.Opaque_object_ref.to_hex expected)
  | Journal_collision path ->
      "V2 transaction journal path already contains different bytes: " ^ path
  | Journal_entry_changed path ->
      "V2 transaction journal entry changed before cleanup: " ^ path
  | Stray_commit transaction_id ->
      "V2 transaction commit has no matching prepare: "
      ^ Transaction.Transaction_id.to_hex transaction_id
  | Io_error { operation; path; message } ->
      Printf.sprintf "%s failed for %s: %s" operation path message
  | Invalid_journal_path path -> "invalid V2 transaction journal path: " ^ path

let io_error ~operation ~path error =
  Io_error { operation; path; message = Unix.error_message error }

let open_repository ~root ~repository_id ~address_key ~encryption_key
    ~public_keys =
  let* ledger =
    Ledger_store.open_repository ~root ~repository_id ~address_key
      ~encryption_key ~public_keys
    |> Result.map_error (fun error -> Ledger_store_error error)
  in
  Ok { journal = Filename.concat root ".yeokcham/journal"; ledger }

let prepare_path repository transaction_id =
  Filename.concat repository.journal
    (Transaction.prepare_filename transaction_id)

let commit_path repository transaction_id =
  Filename.concat repository.journal
    (Transaction.commit_filename transaction_id)

let fsync_directory path =
  try
    let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close descriptor)
      (fun () ->
        Unix.fsync descriptor;
        Ok ())
  with Unix.Unix_error (error, _, _) ->
    Error (io_error ~operation:"fsync" ~path error)

let read_regular_file ~limit path =
  try
    let initial = Unix.lstat path in
    if initial.Unix.st_kind <> Unix.S_REG then Error (Invalid_journal_path path)
    else if initial.Unix.st_size > limit then
      Error
        (Io_error
           {
             operation = "read";
             path;
             message = "journal entry exceeds its bounded size";
           })
    else
      let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
      Fun.protect
        ~finally:(fun () -> Unix.close descriptor)
        (fun () ->
          let opened = Unix.fstat descriptor in
          if
            opened.Unix.st_kind <> Unix.S_REG
            || opened.Unix.st_size <> initial.Unix.st_size
          then Error (Journal_entry_changed path)
          else
            let bytes = Bytes.create opened.Unix.st_size in
            let rec read offset =
              if offset = Bytes.length bytes then
                Ok (Bytes.unsafe_to_string bytes)
              else
                try
                  let count =
                    Unix.read descriptor bytes offset
                      (Bytes.length bytes - offset)
                  in
                  if count = 0 then Error (Journal_entry_changed path)
                  else read (offset + count)
                with Unix.Unix_error (error, _, _) ->
                  Error (io_error ~operation:"read" ~path error)
            in
            read 0)
  with Unix.Unix_error (error, _, _) ->
    Error (io_error ~operation:"lstat" ~path error)

let write_all descriptor bytes =
  let rec write offset =
    if offset = Bytes.length bytes then Ok ()
    else
      try
        let count =
          Unix.write descriptor bytes offset (Bytes.length bytes - offset)
        in
        if count = 0 then Error "write returned zero bytes"
        else write (offset + count)
      with Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
  in
  write 0

let temporary_path final attempt =
  let directory = Filename.dirname final in
  Filename.concat directory
    (Printf.sprintf ".%s.tmp-%d-%d" (Filename.basename final) (Unix.getpid ())
       attempt)

let create_temporary final bytes =
  let rec create attempt =
    if attempt = max_temporary_attempts then
      Error
        (Io_error
           {
             operation = "create temporary journal entry";
             path = Filename.dirname final;
             message = "temporary name space exhausted";
           })
    else
      let path = temporary_path final attempt in
      try
        let descriptor =
          Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
        in
        let result =
          Fun.protect
            ~finally:(fun () -> Unix.close descriptor)
            (fun () ->
              let* () =
                write_all descriptor (Bytes.unsafe_of_string bytes)
                |> Result.map_error (fun message ->
                    Io_error { operation = "write"; path; message })
              in
              try
                Unix.fsync descriptor;
                Ok path
              with Unix.Unix_error (error, _, _) ->
                Error (io_error ~operation:"fsync" ~path error))
        in
        match result with
        | Ok _ -> result
        | Error _ ->
            (try Unix.unlink path with Unix.Unix_error _ -> ());
            result
      with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> create (attempt + 1)
      | Unix.Unix_error (error, _, _) ->
          Error (io_error ~operation:"create" ~path error)
  in
  create 0

let write_create_only ~final ~bytes ~limit =
  let* temporary = create_temporary final bytes in
  let directory = Filename.dirname final in
  let linked =
    try
      Unix.link temporary final;
      Ok true
    with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> Ok false
    | Unix.Unix_error (error, _, _) ->
        Error (io_error ~operation:"link" ~path:final error)
  in
  let cleanup () = try Unix.unlink temporary with Unix.Unix_error _ -> () in
  match linked with
  | Error error ->
      cleanup ();
      Error error
  | Ok true ->
      let* () = fsync_directory directory in
      cleanup ();
      let* () = fsync_directory directory in
      Ok Written
  | Ok false ->
      cleanup ();
      let* existing = read_regular_file ~limit final in
      if String.equal existing bytes then Ok Already_present
      else Error (Journal_collision final)

let validate_prepare_candidates repository prepare =
  let expected_repository = Ledger_store.repository_id repository.ledger in
  let actual_repository = Transaction.prepare_repository_id prepare in
  if not (Model.Repository_id.equal expected_repository actual_repository) then
    Error
      (Repository_mismatch
         { expected = expected_repository; actual = actual_repository })
  else
    let transaction_id = Transaction.prepare_transaction_id prepare in
    let rec validate = function
      | [] -> Ok ()
      | staged :: rest ->
          let* actual, _ =
            Ledger_store.validate_envelope repository.ledger
              ~envelope:(Transaction.staged_envelope staged)
            |> Result.map_error (fun error -> Ledger_store_error error)
          in
          let expected = Transaction.staged_object_ref staged in
          if Model.Opaque_object_ref.equal expected actual then validate rest
          else
            Error
              (Candidate_address_mismatch { transaction_id; expected; actual })
    in
    validate (Transaction.prepare_staged prepare)

let prepare repository ~transaction_id ~envelopes =
  let rec stage result = function
    | [] -> Ok result
    | envelope :: rest ->
        let* object_ref, _ =
          Ledger_store.validate_envelope repository.ledger ~envelope
          |> Result.map_error (fun error -> Ledger_store_error error)
        in
        stage (Transaction.stage ~object_ref ~envelope :: result) rest
  in
  let* staged = stage [] envelopes in
  let staged =
    List.sort
      (fun left right ->
        Model.Opaque_object_ref.compare
          (Transaction.staged_object_ref left)
          (Transaction.staged_object_ref right))
      staged
  in
  let* prepare =
    Transaction.make_prepare
      ~repository_id:(Ledger_store.repository_id repository.ledger)
      ~transaction_id ~mandatory_features:0L staged
    |> Result.map_error (fun error -> Transaction_error error)
  in
  let bytes = Transaction.encode_prepare prepare in
  let* outcome =
    write_create_only
      ~final:(prepare_path repository transaction_id)
      ~bytes ~limit:Transaction.max_prepare_bytes
  in
  match outcome with
  | Written -> Ok (Prepared prepare)
  | Already_present -> Ok (Already_prepared prepare)

let read_prepare repository transaction_id =
  let path = prepare_path repository transaction_id in
  let* bytes = read_regular_file ~limit:Transaction.max_prepare_bytes path in
  let* prepare =
    Transaction.decode_prepare bytes
    |> Result.map_error (fun error -> Transaction_error error)
  in
  if
    Transaction.Transaction_id.equal transaction_id
      (Transaction.prepare_transaction_id prepare)
  then
    Ok
      { prepare_id = transaction_id; prepared = prepare; prepare_bytes = bytes }
  else Error (Invalid_journal_path path)

let read_commit repository transaction_id =
  let path = commit_path repository transaction_id in
  let* bytes = read_regular_file ~limit:Transaction.max_commit_bytes path in
  let* commit =
    Transaction.decode_commit bytes
    |> Result.map_error (fun error -> Transaction_error error)
  in
  if
    Transaction.Transaction_id.equal transaction_id
      (Transaction.commit_transaction_id commit)
  then
    Ok { commit_id = transaction_id; committed = commit; commit_bytes = bytes }
  else Error (Invalid_journal_path path)

let commit repository ~transaction_id =
  let* prepared = read_prepare repository transaction_id in
  let* () = validate_prepare_candidates repository prepared.prepared in
  let commit = Transaction.make_commit prepared.prepared in
  let bytes = Transaction.encode_commit commit in
  let* outcome =
    write_create_only
      ~final:(commit_path repository transaction_id)
      ~bytes ~limit:Transaction.max_commit_bytes
  in
  match outcome with
  | Written -> Ok Committed
  | Already_present -> Ok Already_committed

let read_journal_directory repository =
  try
    Ok
      (Sys.readdir repository.journal
      |> Array.to_list |> List.sort String.compare)
  with Sys_error message ->
    Error
      (Io_error
         {
           operation = "read journal directory";
           path = repository.journal;
           message;
         })

let scan_journal repository =
  let* names = read_journal_directory repository in
  let rec scan prepares commits = function
    | [] -> Ok { prepares = List.rev prepares; commits = List.rev commits }
    | name :: rest when Transaction.is_temporary_journal_filename name ->
        let path = Filename.concat repository.journal name in
        let* stat =
          try Ok (Unix.lstat path)
          with Unix.Unix_error (error, _, _) ->
            Error (io_error ~operation:"lstat" ~path error)
        in
        if stat.Unix.st_kind = Unix.S_REG then scan prepares commits rest
        else Error (Invalid_journal_path path)
    | name :: rest -> (
        let* journal_file =
          Transaction.parse_journal_filename name
          |> Result.map_error (fun error -> Transaction_error error)
        in
        match journal_file with
        | Transaction.Prepare_file transaction_id ->
            let* entry = read_prepare repository transaction_id in
            scan (entry :: prepares) commits rest
        | Transaction.Commit_file transaction_id ->
            let* entry = read_commit repository transaction_id in
            scan prepares (entry :: commits) rest)
  in
  let* state = scan [] [] names in
  let rec validate_commits = function
    | [] -> Ok state
    | commit :: rest ->
        let prepare =
          List.find_opt
            (fun candidate ->
              Transaction.Transaction_id.equal candidate.prepare_id
                commit.commit_id)
            state.prepares
        in
        let* prepare =
          match prepare with
          | Some prepare -> Ok prepare
          | None -> Error (Stray_commit commit.commit_id)
        in
        let* () =
          Transaction.validate_commit ~prepare:prepare.prepared commit.committed
          |> Result.map_error (fun error -> Transaction_error error)
        in
        validate_commits rest
  in
  validate_commits state.commits

let unlink_exact repository ~path ~expected =
  let limit = max Transaction.max_prepare_bytes (String.length expected) in
  let* actual = read_regular_file ~limit path in
  if not (String.equal actual expected) then Error (Journal_entry_changed path)
  else
    try
      Unix.unlink path;
      fsync_directory repository.journal
    with Unix.Unix_error (error, _, _) ->
      Error (io_error ~operation:"unlink" ~path error)

let is_committed state transaction_id =
  List.exists
    (fun commit ->
      Transaction.Transaction_id.equal commit.commit_id transaction_id)
    state.commits

let commit_for state transaction_id =
  List.find_opt
    (fun commit ->
      Transaction.Transaction_id.equal commit.commit_id transaction_id)
    state.commits

let verify repository =
  let* state = scan_journal repository in
  let rec validate_prepares = function
    | [] -> Ok ()
    | prepare :: rest ->
        let* () = validate_prepare_candidates repository prepare.prepared in
        validate_prepares rest
  in
  let* () = validate_prepares state.prepares in
  let committed_transactions =
    List.map (fun commit -> commit.commit_id) state.commits
  in
  let prepared_transactions =
    state.prepares
    |> List.filter (fun prepare -> not (is_committed state prepare.prepare_id))
    |> List.map (fun prepare -> prepare.prepare_id)
  in
  Ok { prepared_transactions; committed_transactions }

let recover repository =
  let* state = scan_journal repository in
  let rec validate_prepares = function
    | [] -> Ok ()
    | prepare :: rest ->
        let* () = validate_prepare_candidates repository prepare.prepared in
        validate_prepares rest
  in
  let* () = validate_prepares state.prepares in
  let uncommitted =
    List.filter
      (fun prepare -> not (is_committed state prepare.prepare_id))
      state.prepares
  in
  let rec discard discarded = function
    | [] -> Ok (List.rev discarded)
    | prepare :: rest ->
        let* () =
          unlink_exact repository
            ~path:(prepare_path repository prepare.prepare_id)
            ~expected:prepare.prepare_bytes
        in
        discard (prepare.prepare_id :: discarded) rest
  in
  let rec complete completed = function
    | [] -> Ok (List.rev completed)
    | prepare :: rest ->
        let* commit =
          match commit_for state prepare.prepare_id with
          | Some commit -> Ok commit
          | None -> assert false
        in
        let rec publish = function
          | [] -> Ok ()
          | staged :: staged_rest ->
              let* _ =
                Ledger_store.publish repository.ledger
                  ~envelope:(Transaction.staged_envelope staged)
                |> Result.map_error (fun error -> Ledger_store_error error)
              in
              publish staged_rest
        in
        let* () = publish (Transaction.prepare_staged prepare.prepared) in
        let* () =
          unlink_exact repository
            ~path:(commit_path repository prepare.prepare_id)
            ~expected:commit.commit_bytes
        in
        let* () =
          unlink_exact repository
            ~path:(prepare_path repository prepare.prepare_id)
            ~expected:prepare.prepare_bytes
        in
        complete (prepare.prepare_id :: completed) rest
  in
  let committed_prepares =
    List.filter
      (fun prepare -> is_committed state prepare.prepare_id)
      state.prepares
  in
  let* completed_transactions = complete [] committed_prepares in
  let* discarded_prepares = discard [] uncommitted in
  Ok { discarded_prepares; completed_transactions }
