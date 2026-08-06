type path = string list
type span = { start_byte : int; end_byte : int }
type declaration_kind = Function | Class | Interface | Type_alias | Variable

type token_kind =
  | Identifier of string
  | String_literal of string
  | Symbol of char

type token = { token_kind : token_kind; token_start : int; token_end : int }

type declaration = {
  declaration_kind : declaration_kind;
  declaration_name : string;
  declaration_structural_path : path;
  declaration_span : span;
  declaration_name_span : span;
  declaration_signature : string list;
}

type parsed = { source : string; declarations : declaration list }

type parse_error =
  | Unterminated_block_comment of int
  | Unterminated_string_literal of int
  | Unbalanced_delimiter of { offset : int; delimiter : char }

let ( let* ) = Result.bind

let parse_error_to_string = function
  | Unterminated_block_comment offset ->
      Printf.sprintf "unterminated block comment at byte %d" offset
  | Unterminated_string_literal offset ->
      Printf.sprintf "unterminated string literal at byte %d" offset
  | Unbalanced_delimiter { offset; delimiter } ->
      Printf.sprintf "unbalanced delimiter %C at byte %d" delimiter offset

let declarations parsed = parsed.declarations
let declaration_kind declaration = declaration.declaration_kind
let declaration_name declaration = declaration.declaration_name

let declaration_structural_path declaration =
  declaration.declaration_structural_path

let declaration_span declaration = declaration.declaration_span
let declaration_name_span declaration = declaration.declaration_name_span

let is_identifier_start = function
  | 'a' .. 'z' | 'A' .. 'Z' | '_' | '$' -> true
  | _ -> false

let is_identifier_continue character =
  is_identifier_start character
  || match character with '0' .. '9' -> true | _ -> false

let rec scan_quoted source start delimiter index =
  if index >= String.length source then
    Error (Unterminated_string_literal start)
  else
    match source.[index] with
    | '\\' ->
        if index + 1 >= String.length source then
          Error (Unterminated_string_literal start)
        else scan_quoted source start delimiter (index + 2)
    | character when Char.equal character delimiter -> Ok (index + 1)
    | _ -> scan_quoted source start delimiter (index + 1)

let rec scan_block_comment source start index =
  if index + 1 >= String.length source then
    Error (Unterminated_block_comment start)
  else if Char.equal source.[index] '*' && Char.equal source.[index + 1] '/'
  then Ok (index + 2)
  else scan_block_comment source start (index + 1)

let lex source =
  let length = String.length source in
  let rec skip_line_comment index =
    if index >= length || Char.equal source.[index] '\n' then index
    else skip_line_comment (index + 1)
  in
  let rec scan index reversed =
    if index >= length then Ok (List.rev reversed)
    else
      match source.[index] with
      | ' ' | '\t' | '\r' | '\n' -> scan (index + 1) reversed
      | '/' when index + 1 < length && Char.equal source.[index + 1] '/' ->
          scan (skip_line_comment (index + 2)) reversed
      | '/' when index + 1 < length && Char.equal source.[index + 1] '*' ->
          let* next = scan_block_comment source index (index + 2) in
          scan next reversed
      | ('\'' | '"' | '`') as delimiter ->
          let* next = scan_quoted source index delimiter (index + 1) in
          scan next
            ({
               token_kind =
                 String_literal (String.sub source index (next - index));
               token_start = index;
               token_end = next;
             }
            :: reversed)
      | character when is_identifier_start character ->
          let rec stop index =
            if index < length && is_identifier_continue source.[index] then
              stop (index + 1)
            else index
          in
          let next = stop (index + 1) in
          let value = String.sub source index (next - index) in
          scan next
            ({
               token_kind = Identifier value;
               token_start = index;
               token_end = next;
             }
            :: reversed)
      | character ->
          scan (index + 1)
            ({
               token_kind = Symbol character;
               token_start = index;
               token_end = index + 1;
             }
            :: reversed)
  in
  scan 0 []

let token_identifier token =
  match token.token_kind with
  | Identifier value -> Some value
  | String_literal _ | Symbol _ -> None

let validate_delimiters tokens =
  let rec visit stack = function
    | [] -> (
        match stack with
        | [] -> Ok ()
        | (delimiter, offset) :: _ ->
            Error (Unbalanced_delimiter { offset; delimiter }))
    | token :: rest -> (
        match token.token_kind with
        | Symbol (('(' | '[' | '{') as delimiter) ->
            visit ((delimiter, token.token_start) :: stack) rest
        | Symbol ((')' | ']' | '}') as closing) -> (
            match stack with
            | (opening, _) :: tail
              when (Char.equal opening '(' && Char.equal closing ')')
                   || (Char.equal opening '[' && Char.equal closing ']')
                   || (Char.equal opening '{' && Char.equal closing '}') ->
                visit tail rest
            | _ ->
                Error
                  (Unbalanced_delimiter
                     { offset = token.token_start; delimiter = closing }))
        | Identifier _ | String_literal _ | Symbol _ -> visit stack rest)
  in
  visit [] tokens

let keyword = function
  | "function" -> Some Function
  | "class" -> Some Class
  | "interface" -> Some Interface
  | "type" -> Some Type_alias
  | "const" | "let" | "var" -> Some Variable
  | _ -> None

let kind_to_string = function
  | Function -> "function"
  | Class -> "class"
  | Interface -> "interface"
  | Type_alias -> "type"
  | Variable -> "variable"

let modifier = function
  | "export" | "default" | "declare" | "async" | "abstract" | "readonly"
  | "public" | "private" | "protected" | "static" ->
      true
  | _ -> false

let depth_before tokens =
  let rec build depth reversed = function
    | [] -> List.rev reversed
    | token :: rest ->
        let next_depth =
          match token.token_kind with
          | Symbol '{' | Symbol '(' | Symbol '[' -> depth + 1
          | Symbol '}' | Symbol ')' | Symbol ']' -> depth - 1
          | Identifier _ | String_literal _ | Symbol _ -> depth
        in
        build next_depth (depth :: reversed) rest
  in
  build 0 [] tokens

let declaration_start tokens index =
  let length = Array.length tokens in
  let follows_modifier =
    index > 0
    &&
    match token_identifier tokens.(index - 1) with
    | Some value -> modifier value
    | None -> false
  in
  let rec skip_modifiers position =
    if position < length then
      match token_identifier tokens.(position) with
      | Some value when modifier value -> skip_modifiers (position + 1)
      | _ -> position
    else position
  in
  let keyword_index = skip_modifiers index in
  if follows_modifier || keyword_index >= length then None
  else
    match token_identifier tokens.(keyword_index) with
    | Some value -> (
        match keyword value with
        | None -> None
        | Some declaration_kind -> (
            let name_index =
              match declaration_kind with
              | Function -> (
                  if keyword_index + 1 >= length then length
                  else
                    match tokens.(keyword_index + 1).token_kind with
                    | Symbol '*' -> keyword_index + 2
                    | Identifier _ | String_literal _ | Symbol _ ->
                        keyword_index + 1)
              | Class | Interface | Type_alias | Variable -> keyword_index + 1
            in
            if name_index >= length then None
            else
              match token_identifier tokens.(name_index) with
              | None -> None
              | Some name ->
                  Some
                    ( declaration_kind,
                      name,
                      tokens.(index).token_start,
                      tokens.(name_index).token_start,
                      tokens.(name_index).token_end )))
    | None -> None

let signature source name_end span_end =
  let segment = String.sub source name_end (span_end - name_end) in
  match lex segment with
  | Error _ -> []
  | Ok tokens ->
      let tokens =
        List.map
          (function
            | { token_kind = Identifier value; _ } -> value
            | { token_kind = String_literal value; _ } -> value
            | { token_kind = Symbol value; _ } -> String.make 1 value)
          tokens
      in
      let rec remove_trailing_parameter_commas = function
        | "," :: ")" :: rest -> ")" :: remove_trailing_parameter_commas rest
        | token :: rest -> token :: remove_trailing_parameter_commas rest
        | [] -> []
      in
      remove_trailing_parameter_commas tokens

let parse source =
  let* tokens = lex source in
  let* () = validate_delimiters tokens in
  let tokens = Array.of_list tokens in
  let depths = Array.of_list (depth_before (Array.to_list tokens)) in
  let preliminary =
    Array.to_list (Array.mapi (fun index token -> (index, token)) tokens)
    |> List.filter_map (fun (index, _) ->
        if depths.(index) <> 0 then None else declaration_start tokens index)
  in
  let length = String.length source in
  let declarations =
    List.mapi
      (fun ordinal
           (declaration_kind, declaration_name, start_byte, name_start, name_end)
         ->
        let end_byte =
          match List.nth_opt preliminary (ordinal + 1) with
          | Some (_, _, next_start, _, _) -> next_start
          | None -> length
        in
        {
          declaration_kind;
          declaration_name;
          declaration_structural_path =
            [
              "top-level";
              kind_to_string declaration_kind;
              string_of_int ordinal;
            ];
          declaration_span = { start_byte; end_byte };
          declaration_name_span =
            { start_byte = name_start; end_byte = name_end };
          declaration_signature = signature source name_end end_byte;
        })
      preliminary
  in
  Ok { source; declarations }

type text_anchor = {
  before_context : string;
  selected : string;
  after_context : string;
}

type exact_textual_fallback = {
  expected_source : string;
  replacement_source : string;
  textual_anchor : text_anchor;
}

type semantic_anchor = {
  language : string;
  kind : declaration_kind;
  symbol_identity : string option;
  structural_path : path;
  source_signature : string list;
  textual_fallback : exact_textual_fallback;
}

type proposal_kind =
  | Rename_declaration of { from_name : string; to_name : string }
  | Move_declaration of { from_path : path; to_path : path }
  | Replace_declaration of { replacement : string }

type proposal = {
  proposal_kind : proposal_kind;
  proposal_anchor : semantic_anchor;
}

type inference_error =
  | Before_parse_failure of parse_error
  | After_parse_failure of parse_error

let inference_error_to_string = function
  | Before_parse_failure error ->
      "before source: " ^ parse_error_to_string error
  | After_parse_failure error -> "after source: " ^ parse_error_to_string error

let substring source start_byte end_byte =
  String.sub source start_byte (end_byte - start_byte)

let textual_anchor source declaration =
  let context = 48 in
  let span = declaration.declaration_span in
  let before_start = max 0 (span.start_byte - context) in
  let after_end = min (String.length source) (span.end_byte + context) in
  {
    before_context = substring source before_start span.start_byte;
    selected = substring source span.start_byte span.end_byte;
    after_context = substring source span.end_byte after_end;
  }

let make_anchor ~before ~after declaration =
  {
    language = "typescript";
    kind = declaration.declaration_kind;
    symbol_identity = Some declaration.declaration_name;
    structural_path = declaration.declaration_structural_path;
    source_signature = declaration.declaration_signature;
    textual_fallback =
      {
        expected_source = before;
        replacement_source = after;
        textual_anchor = textual_anchor before declaration;
      };
  }

let proposal_kind proposal = proposal.proposal_kind
let proposal_anchor proposal = proposal.proposal_anchor
let proposal_fallback proposal = proposal.proposal_anchor.textual_fallback
let same_signature left right = left = right

let declaration_text parsed declaration =
  substring parsed.source declaration.declaration_span.start_byte
    declaration.declaration_span.end_byte

let unique = function [ value ] -> Some value | _ -> None

let infer ~path:_ ~before ~after =
  let* before =
    parse before |> Result.map_error (fun error -> Before_parse_failure error)
  in
  let* after =
    parse after |> Result.map_error (fun error -> After_parse_failure error)
  in
  let proposal_for declaration =
    let same_kind =
      List.filter
        (fun candidate ->
          candidate.declaration_kind = declaration.declaration_kind)
        after.declarations
    in
    let same_name =
      List.filter
        (fun candidate ->
          String.equal candidate.declaration_name declaration.declaration_name)
        same_kind
    in
    let same_signature_candidates =
      List.filter
        (fun candidate ->
          same_signature declaration.declaration_signature
            candidate.declaration_signature)
        same_kind
    in
    let anchor =
      make_anchor ~before:before.source ~after:after.source declaration
    in
    match unique same_name with
    | Some candidate
      when same_signature declaration.declaration_signature
             candidate.declaration_signature
           && declaration.declaration_structural_path
              <> candidate.declaration_structural_path ->
        Some
          {
            proposal_kind =
              Move_declaration
                {
                  from_path = declaration.declaration_structural_path;
                  to_path = candidate.declaration_structural_path;
                };
            proposal_anchor = anchor;
          }
    | Some candidate
      when not
             (String.equal
                (declaration_text before declaration)
                (declaration_text after candidate)) ->
        Some
          {
            proposal_kind =
              Replace_declaration
                { replacement = declaration_text after candidate };
            proposal_anchor = anchor;
          }
    | Some _ -> None
    | None -> (
        match unique same_signature_candidates with
        | Some candidate
          when not
                 (String.equal declaration.declaration_name
                    candidate.declaration_name) ->
            Some
              {
                proposal_kind =
                  Rename_declaration
                    {
                      from_name = declaration.declaration_name;
                      to_name = candidate.declaration_name;
                    };
                proposal_anchor = anchor;
              }
        | Some _ | None -> None)
  in
  Ok (List.filter_map proposal_for before.declarations)

type confidence = Exact | High | Medium | Low | Unknown

let confidence_to_string = function
  | Exact -> "exact"
  | High -> "high"
  | Medium -> "medium"
  | Low -> "low"
  | Unknown -> "unknown"

type match_evidence =
  | Exact_symbol_identity of string
  | Structural_path_match of path
  | Token_similarity of { common : int; total : int }
  | Textual_context_match of { occurrences : int }
  | Parse_failure of parse_error

type match_conflict_kind =
  | Missing_anchor
  | Ambiguous_anchor
  | Low_confidence_anchor
  | Textual_fallback_required
  | Target_parse_failure

let match_conflict_kind_to_string = function
  | Missing_anchor -> "missing-anchor"
  | Ambiguous_anchor -> "ambiguous-anchor"
  | Low_confidence_anchor -> "low-confidence-anchor"
  | Textual_fallback_required -> "textual-fallback-required"
  | Target_parse_failure -> "target-parse-failure"

type match_conflict = {
  match_conflict_kind : match_conflict_kind;
  match_conflict_anchor : semantic_anchor;
  match_conflict_candidates : declaration list;
  match_conflict_evidence : match_evidence list;
}

type anchor_match = {
  matched_declaration : declaration;
  matched_confidence : confidence;
  matched_evidence : match_evidence list;
}

type match_result = Matched of anchor_match | Match_conflict of match_conflict

let sorted_unique values = List.sort_uniq String.compare values

let similarity left right =
  let left = sorted_unique left in
  let right = sorted_unique right in
  let common =
    List.length (List.filter (fun value -> List.mem value right) left)
  in
  let total = List.length (sorted_unique (left @ right)) in
  (common, total)

let occurrences source selected =
  if String.is_empty selected then 0
  else
    let selected_length = String.length selected in
    let rec count index total =
      if index + selected_length > String.length source then total
      else if String.equal (String.sub source index selected_length) selected
      then count (index + 1) (total + 1)
      else count (index + 1) total
    in
    count 0 0

let conflict ~kind ~anchor ?(candidates = []) ~evidence () =
  Match_conflict
    {
      match_conflict_kind = kind;
      match_conflict_anchor = anchor;
      match_conflict_candidates = candidates;
      match_conflict_evidence = evidence;
    }

let resolve_candidates anchor candidates confidence evidence =
  match candidates with
  | [ declaration ] ->
      Matched
        {
          matched_declaration = declaration;
          matched_confidence = confidence;
          matched_evidence = evidence;
        }
  | [] -> conflict ~kind:Missing_anchor ~anchor ~evidence ()
  | _ -> conflict ~kind:Ambiguous_anchor ~anchor ~candidates ~evidence ()

let locate_anchor ~source anchor =
  match parse source with
  | Error error ->
      conflict ~kind:Target_parse_failure ~anchor
        ~evidence:[ Parse_failure error ] ()
  | Ok parsed -> (
      let same_kind =
        List.filter
          (fun candidate -> candidate.declaration_kind = anchor.kind)
          parsed.declarations
      in
      let identity_candidates =
        match anchor.symbol_identity with
        | None -> []
        | Some identity ->
            List.filter
              (fun candidate ->
                String.equal candidate.declaration_name identity)
              same_kind
      in
      let exact_candidates =
        List.filter
          (fun candidate ->
            same_signature anchor.source_signature
              candidate.declaration_signature)
          identity_candidates
      in
      if exact_candidates <> [] then
        match (anchor.symbol_identity, exact_candidates) with
        | Some identity, candidate :: _ ->
            let common, total =
              similarity anchor.source_signature candidate.declaration_signature
            in
            resolve_candidates anchor exact_candidates Exact
              [
                Exact_symbol_identity identity;
                Token_similarity { common; total };
              ]
        | None, _ | _, [] ->
            conflict ~kind:Missing_anchor ~anchor ~evidence:[] ()
      else
        let structural_candidates =
          List.filter
            (fun candidate ->
              candidate.declaration_structural_path = anchor.structural_path)
            same_kind
        in
        match structural_candidates with
        | [ candidate ] ->
            let common, total =
              similarity anchor.source_signature candidate.declaration_signature
            in
            if total > 0 && common = total then
              Matched
                {
                  matched_declaration = candidate;
                  matched_confidence = High;
                  matched_evidence =
                    [
                      Structural_path_match anchor.structural_path;
                      Token_similarity { common; total };
                    ];
                }
            else
              let scored =
                List.map
                  (fun declaration ->
                    let common, total =
                      similarity anchor.source_signature
                        declaration.declaration_signature
                    in
                    (declaration, common, total))
                  same_kind
              in
              let best =
                List.fold_left
                  (fun current ((_, common, total) as candidate) ->
                    match current with
                    | None -> Some candidate
                    | Some (_, best_common, best_total) ->
                        if common * best_total > best_common * total then
                          Some candidate
                        else current)
                  None scored
              in
              let candidates, common, total =
                match best with
                | Some (_, common, total) ->
                    ( List.filter
                        (fun (_, candidate_common, candidate_total) ->
                          candidate_common * total = common * candidate_total)
                        scored
                      |> List.map (fun (declaration, _, _) -> declaration),
                      common,
                      total )
                | None -> ([], 0, 0)
              in
              if candidates = [] || total = 0 then
                let found =
                  occurrences source
                    anchor.textual_fallback.textual_anchor.selected
                in
                if found = 1 then
                  conflict ~kind:Textual_fallback_required ~anchor
                    ~evidence:[ Textual_context_match { occurrences = found } ]
                    ()
                else conflict ~kind:Missing_anchor ~anchor ~evidence:[] ()
              else if List.length candidates > 1 then
                conflict ~kind:Ambiguous_anchor ~anchor ~candidates
                  ~evidence:[ Token_similarity { common; total } ]
                  ()
              else
                let confidence =
                  if common * 100 >= total * 90 then High
                  else if common * 100 >= total * 60 then Medium
                  else Low
                in
                if confidence = High then
                  match candidates with
                  | [ candidate ] ->
                      Matched
                        {
                          matched_declaration = candidate;
                          matched_confidence = confidence;
                          matched_evidence =
                            [ Token_similarity { common; total } ];
                        }
                  | [] -> conflict ~kind:Missing_anchor ~anchor ~evidence:[] ()
                  | _ ->
                      conflict ~kind:Ambiguous_anchor ~anchor ~candidates
                        ~evidence:[ Token_similarity { common; total } ]
                        ()
                else
                  conflict ~kind:Low_confidence_anchor ~anchor ~candidates
                    ~evidence:[ Token_similarity { common; total } ]
                    ()
        | [] ->
            let found =
              occurrences source anchor.textual_fallback.textual_anchor.selected
            in
            if found = 1 then
              conflict ~kind:Textual_fallback_required ~anchor
                ~evidence:[ Textual_context_match { occurrences = found } ]
                ()
            else conflict ~kind:Missing_anchor ~anchor ~evidence:[] ()
        | candidates ->
            conflict ~kind:Ambiguous_anchor ~anchor ~candidates
              ~evidence:[ Structural_path_match anchor.structural_path ]
              ())

type application_conflict_kind =
  | Matching_conflict of match_conflict_kind
  | Manual_review_required of proposal_kind

let application_conflict_kind_to_string = function
  | Matching_conflict kind -> match_conflict_kind_to_string kind
  | Manual_review_required _ -> "manual-review-required"

type application =
  | Applied of {
      applied_source : string;
      applied_confidence : confidence;
      applied_evidence : match_evidence list;
    }
  | Application_conflict of {
      application_conflict_kind : application_conflict_kind;
      application_conflict_evidence : match_evidence list;
      application_conflict_fallback : exact_textual_fallback;
    }

let replace_span source (span : span) replacement =
  String.sub source 0 span.start_byte
  ^ replacement
  ^ String.sub source span.end_byte (String.length source - span.end_byte)

let apply ~source proposal =
  let fallback = proposal_fallback proposal in
  match locate_anchor ~source proposal.proposal_anchor with
  | Match_conflict conflict ->
      Application_conflict
        {
          application_conflict_kind =
            Matching_conflict conflict.match_conflict_kind;
          application_conflict_evidence = conflict.match_conflict_evidence;
          application_conflict_fallback = fallback;
        }
  | Matched match_ -> (
      match proposal.proposal_kind with
      | Rename_declaration { from_name; to_name }
        when match_.matched_confidence = Exact
             && String.equal match_.matched_declaration.declaration_name
                  from_name ->
          Applied
            {
              applied_source =
                replace_span source
                  match_.matched_declaration.declaration_name_span to_name;
              applied_confidence = match_.matched_confidence;
              applied_evidence = match_.matched_evidence;
            }
      | Rename_declaration _ | Move_declaration _ | Replace_declaration _ ->
          Application_conflict
            {
              application_conflict_kind =
                Manual_review_required proposal.proposal_kind;
              application_conflict_evidence = match_.matched_evidence;
              application_conflict_fallback = fallback;
            })

type fallback_error = Source_does_not_match_exact_fallback

let fallback_error_to_string = function
  | Source_does_not_match_exact_fallback ->
      "source does not match the proposal's exact textual fallback"

let apply_exact_textual_fallback ~source proposal =
  let fallback = proposal_fallback proposal in
  if String.equal source fallback.expected_source then
    Ok fallback.replacement_source
  else Error Source_does_not_match_exact_fallback
