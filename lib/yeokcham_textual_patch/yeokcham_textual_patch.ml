type span = { start_byte : int; end_byte : int }

type stage =
  | Exact_original_span
  | Unique_exact_preimage
  | Unique_full_context
  | Relaxed_context of int

type operation = {
  original_span : span;
  expected_preimage : string;
  replacement : string;
  before_context : string;
  after_context : string;
  relaxed_context_bytes : int list;
}

let default_relaxed_context_bytes = [ 32; 16; 8 ]
let valid_span span = span.start_byte >= 0 && span.end_byte >= span.start_byte

let make ~original_span ~expected_preimage ~replacement ~before_context
    ~after_context ~relaxed_context_bytes =
  if not (valid_span original_span) then Error "original span is invalid"
  else if String.length expected_preimage = 0 then
    Error "expected preimage must be nonempty"
  else if
    original_span.end_byte - original_span.start_byte
    <> String.length expected_preimage
  then Error "original span length does not equal expected preimage length"
  else if
    List.exists (fun value -> value <= 0 || value > 64) relaxed_context_bytes
  then Error "relaxed context bounds must be 1 through 64 bytes"
  else if
    relaxed_context_bytes
    <> List.sort_uniq
         (fun left right -> compare right left)
         relaxed_context_bytes
  then Error "relaxed context bounds must be unique and descending"
  else
    Ok
      {
        original_span;
        expected_preimage;
        replacement;
        before_context;
        after_context;
        relaxed_context_bytes;
      }

type conflict_kind = Missing_match | Ambiguous_match | Rejected

type conflict = {
  conflict_kind : conflict_kind;
  conflict_stage : stage option;
  conflict_candidates : span list;
  conflict_reason : string;
}

type outcome =
  | Applied of { contents : string; selected_span : span; stage : stage }
  | Already_satisfied of { selected_span : span; stage : stage }
  | Conflict of conflict

let stage_to_string = function
  | Exact_original_span -> "exact-original-span"
  | Unique_exact_preimage -> "unique-exact-preimage"
  | Unique_full_context -> "unique-full-context"
  | Relaxed_context bytes -> Printf.sprintf "relaxed-context-%d" bytes

let conflict_kind_to_string = function
  | Missing_match -> "missing-match"
  | Ambiguous_match -> "ambiguous-match"
  | Rejected -> "rejected"

let in_bounds source span =
  valid_span span && span.end_byte <= String.length source

let selected source span =
  String.sub source span.start_byte (span.end_byte - span.start_byte)

let splice source span replacement =
  String.sub source 0 span.start_byte
  ^ replacement
  ^ String.sub source span.end_byte (String.length source - span.end_byte)

let validates_splice ~source ~selected_span ~expected_preimage ~replacement
    ~output =
  in_bounds source selected_span
  && String.equal (selected source selected_span) expected_preimage
  && String.equal output (splice source selected_span replacement)

let occurrences source expected =
  let expected_length = String.length expected in
  let source_length = String.length source in
  let rec collect index reversed =
    if index + expected_length > source_length then List.rev reversed
    else if String.equal (String.sub source index expected_length) expected then
      collect (index + 1)
        ({ start_byte = index; end_byte = index + expected_length } :: reversed)
    else collect (index + 1) reversed
  in
  collect 0 []

let prefix value length = String.sub value 0 length
let suffix value length = String.sub value (String.length value - length) length

let context_matches source span ~before_context ~after_context ~bound =
  let before_length = min bound (String.length before_context) in
  let after_length = min bound (String.length after_context) in
  before_length + after_length > 0
  && span.start_byte >= before_length
  && span.end_byte + after_length <= String.length source
  && String.equal
       (String.sub source (span.start_byte - before_length) before_length)
       (suffix before_context before_length)
  && String.equal
       (String.sub source span.end_byte after_length)
       (prefix after_context after_length)

let full_context_matches source span operation =
  context_matches source span ~before_context:operation.before_context
    ~after_context:operation.after_context
    ~bound:
      (max
         (String.length operation.before_context)
         (String.length operation.after_context))

let conflict ?stage ?(candidates = []) kind reason =
  Conflict
    {
      conflict_kind = kind;
      conflict_stage = stage;
      conflict_candidates = candidates;
      conflict_reason = reason;
    }

let apply_at source operation span stage =
  let contents = splice source span operation.replacement in
  if
    validates_splice ~source ~selected_span:span
      ~expected_preimage:operation.expected_preimage
      ~replacement:operation.replacement ~output:contents
  then Applied { contents; selected_span = span; stage }
  else conflict ~stage Rejected "internal splice validation failed"

let original_result source operation =
  if not (in_bounds source operation.original_span) then None
  else if
    String.equal
      (selected source operation.original_span)
      operation.expected_preimage
  then
    Some (apply_at source operation operation.original_span Exact_original_span)
  else if
    String.equal (selected source operation.original_span) operation.replacement
  then
    Some
      (Already_satisfied
         {
           selected_span = operation.original_span;
           stage = Exact_original_span;
         })
  else None

let already_satisfied source operation =
  if String.length operation.replacement = 0 then None
  else
    occurrences source operation.replacement
    |> List.filter (fun span -> full_context_matches source span operation)
    |> function
    | [ span ] ->
        Some
          (Already_satisfied
             { selected_span = span; stage = Unique_full_context })
    | _ -> None

let apply ~source operation =
  match original_result source operation with
  | Some result -> result
  | None -> (
      match already_satisfied source operation with
      | Some result -> result
      | None -> (
          let exact = occurrences source operation.expected_preimage in
          match exact with
          | [ span ] -> apply_at source operation span Unique_exact_preimage
          | _ -> (
              let full =
                List.filter
                  (fun span -> full_context_matches source span operation)
                  exact
              in
              match full with
              | [ span ] -> apply_at source operation span Unique_full_context
              | _ :: _ :: _ ->
                  conflict ~stage:Unique_full_context ~candidates:full
                    Ambiguous_match
                    "full byte context matches multiple candidates"
              | [] ->
                  let rec relaxed = function
                    | [] -> (
                        match exact with
                        | [] ->
                            conflict Missing_match
                              "expected preimage is absent from target bytes"
                        | _ :: _ :: _ ->
                            conflict ~stage:Unique_full_context
                              ~candidates:exact Ambiguous_match
                              "multiple exact preimages remain without a \
                               unique byte-context match"
                        | [ _ ] ->
                            conflict ~stage:Unique_full_context
                              ~candidates:exact Missing_match
                              "the unique exact preimage lost its byte context")
                    | bound :: rest -> (
                        let matches =
                          List.filter
                            (fun span ->
                              context_matches source span
                                ~before_context:operation.before_context
                                ~after_context:operation.after_context ~bound)
                            exact
                        in
                        match matches with
                        | [ span ] ->
                            apply_at source operation span
                              (Relaxed_context bound)
                        | _ :: _ :: _ ->
                            conflict ~stage:(Relaxed_context bound)
                              ~candidates:matches Ambiguous_match
                              "relaxed byte context matches multiple candidates"
                        | [] -> relaxed rest)
                  in
                  relaxed operation.relaxed_context_bytes)))
