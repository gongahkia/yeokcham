[@@@warning "-41-42"]

module Patch = Paengi_textual_patch

type expected_outcome = Exact_textual_bytes of string | Safe_conflict

type textual_operation = {
  original_path : string;
  original_start_byte : int;
  expected_preimage : string;
  replacement : string;
  before_context : string;
  after_context : string;
}

type fallback_expectation = {
  parser_complete : bool;
  textual_fallback_required : bool;
  fallback_syntax_kinds : string list;
}

type module_expectation = {
  root_files : string list;
  module_paths_complete : bool;
  module_statuses : string list;
}

type fixture = {
  dataset_version : int;
  fixture_id : string;
  category : string;
  original_project : (string * string) list;
  authored_changed_project : (string * string) list;
  retarget_base : (string * string) list;
  target_path : string;
  textual_operation : textual_operation;
  expected_target_span : Patch.span option;
  expected_outcome : expected_outcome;
  fallback_expectation : fallback_expectation;
  module_expectation : module_expectation option;
  adversarial_explanation : string;
}

let version = 1

let rec find_substring source target index =
  let target_length = String.length target in
  if index + target_length > String.length source then None
  else if String.equal (String.sub source index target_length) target then
    Some index
  else find_substring source target (index + 1)

let require_substring source target =
  match find_substring source target 0 with
  | Some index -> index
  | None -> invalid_arg ("fixture source omitted " ^ target)

let replace_first source old_name new_name =
  let start = require_substring source old_name in
  String.sub source 0 start ^ new_name
  ^ String.sub source
      (start + String.length old_name)
      (String.length source - start - String.length old_name)

let patch_span start_byte width =
  Patch.{ start_byte; end_byte = start_byte + width }

let context source start_byte width =
  let before_start = max 0 (start_byte - 16) in
  let after_start = start_byte + width in
  let after_end = min (String.length source) (after_start + 16) in
  ( String.sub source before_start (start_byte - before_start),
    String.sub source after_start (after_end - after_start) )

let splice source span replacement =
  String.sub source 0 span.Patch.start_byte
  ^ replacement
  ^ String.sub source span.Patch.end_byte
      (String.length source - span.Patch.end_byte)

let safe_rust_path path =
  String.length path > 3
  && String.ends_with ~suffix:".rs" path
  && (not (String.starts_with ~prefix:"/" path))
  && (not (String.contains path '\000'))
  && (not (String.contains path '\\'))
  && String.split_on_char '/' path
     |> List.for_all (fun component ->
         String.length component > 0
         && not (String.equal component "." || String.equal component ".."))

let canonical_project project =
  let project =
    List.sort (fun (left, _) (right, _) -> String.compare left right) project
  in
  if List.length project > 16 then
    invalid_arg "fixture project exceeds file bound";
  let rec valid = function
    | [] -> true
    | (path, contents) :: rest ->
        safe_rust_path path
        && String.length contents <= 64 * 1024
        && (match rest with
          | (next, _) :: _ -> not (String.equal path next)
          | [] -> true)
        && valid rest
  in
  if valid project then project
  else invalid_arg "fixture project is not a bounded canonical Rust map"

let find_source project path =
  match List.assoc_opt path project with
  | Some source -> source
  | None -> invalid_arg ("fixture source map omitted " ^ path)

let make_fixture ~fixture_id ~category ~original_project
    ~authored_changed_project ~retarget_base ~target_path ~old_name ~new_name
    ~fallback_expectation ?module_expectation ~adversarial_explanation
    ~expected_outcome () =
  let original_project = canonical_project original_project in
  let authored_changed_project = canonical_project authored_changed_project in
  let retarget_base = canonical_project retarget_base in
  let original_path =
    match original_project with
    | [ (path, _) ] -> path
    | _ -> (
        match
          List.find_opt
            (fun (_, source) ->
              Option.is_some (find_substring source old_name 0))
            original_project
        with
        | Some (path, _) -> path
        | None -> invalid_arg "fixture has no original name")
  in
  let original = find_source original_project original_path in
  let target = find_source retarget_base target_path in
  let original_start_byte = require_substring original old_name in
  let target_start_byte = require_substring target old_name in
  let before_context, after_context =
    context original original_start_byte (String.length old_name)
  in
  let textual_operation =
    {
      original_path;
      original_start_byte;
      expected_preimage = old_name;
      replacement = new_name;
      before_context;
      after_context;
    }
  in
  let expected_target_span =
    match expected_outcome with
    | Exact_textual_bytes _ ->
        Some (patch_span target_start_byte (String.length old_name))
    | Safe_conflict -> None
  in
  {
    dataset_version = version;
    fixture_id;
    category;
    original_project;
    authored_changed_project;
    retarget_base;
    target_path;
    textual_operation;
    expected_target_span;
    expected_outcome;
    fallback_expectation;
    module_expectation;
    adversarial_explanation;
  }

let exact_expected target old_name new_name =
  let start_byte = require_substring target old_name in
  splice target (patch_span start_byte (String.length old_name)) new_name

let simple_source = "pub fn greet(value: &str) -> &str { value }\n"
let simple_renamed = replace_first simple_source "greet" "welcome"

let no_fallback =
  {
    parser_complete = true;
    textual_fallback_required = false;
    fallback_syntax_kinds = [];
  }

let macro_fallback =
  {
    parser_complete = true;
    textual_fallback_required = true;
    fallback_syntax_kinds = [ "macro-definition"; "macro-invocation" ];
  }

let damaged_fallback =
  {
    parser_complete = false;
    textual_fallback_required = true;
    fallback_syntax_kinds = [ "parser-damage" ];
  }

let complete_root =
  Some
    {
      root_files = [ "src/lib.rs" ];
      module_paths_complete = true;
      module_statuses = [ "resolved" ];
    }

let renamed_after_insertion =
  let target = "// independently inserted\n" ^ simple_source in
  make_fixture ~fixture_id:"rename-after-insertion"
    ~category:"function rename after independent insertion"
    ~original_project:[ ("src/lib.rs", simple_source) ]
    ~authored_changed_project:[ ("src/lib.rs", simple_renamed) ]
    ~retarget_base:[ ("src/lib.rs", target) ]
    ~target_path:"src/lib.rs" ~old_name:"greet" ~new_name:"welcome"
    ~fallback_expectation:no_fallback ?module_expectation:complete_root
    ~adversarial_explanation:
      "the byte oracle moves after unrelated bytes; it does not infer Rust \
       intent"
    ~expected_outcome:
      (Exact_textual_bytes (exact_expected target "greet" "welcome"))
    ()

let renamed_after_within_file_move =
  let target = "pub fn helper() {}\n\n" ^ simple_source in
  make_fixture ~fixture_id:"rename-after-within-file-move"
    ~category:"function rename after within-file move"
    ~original_project:[ ("src/lib.rs", simple_source) ]
    ~authored_changed_project:[ ("src/lib.rs", simple_renamed) ]
    ~retarget_base:[ ("src/lib.rs", target) ]
    ~target_path:"src/lib.rs" ~old_name:"greet" ~new_name:"welcome"
    ~fallback_expectation:no_fallback ?module_expectation:complete_root
    ~adversarial_explanation:
      "only an exact byte patch is expected after declaration reordering"
    ~expected_outcome:
      (Exact_textual_bytes (exact_expected target "greet" "welcome"))
    ()

let renamed_after_cross_module_move =
  let target = "// moved from api\n" ^ simple_source in
  make_fixture ~fixture_id:"rename-after-cross-module-move"
    ~category:"function rename after cross-module move"
    ~original_project:
      [ ("src/api.rs", simple_source); ("src/lib.rs", "mod api;\n") ]
    ~authored_changed_project:
      [ ("src/api.rs", simple_renamed); ("src/lib.rs", "mod api;\n") ]
    ~retarget_base:
      [ ("src/lib.rs", "mod service;\n"); ("src/service.rs", target) ]
    ~target_path:"src/service.rs" ~old_name:"greet" ~new_name:"welcome"
    ~fallback_expectation:no_fallback
    ~module_expectation:
      {
        root_files = [ "src/lib.rs" ];
        module_paths_complete = true;
        module_statuses = [ "resolved"; "resolved" ];
      }
    ~adversarial_explanation:
      "the changed module path is fixture context, not name or move resolution"
    ~expected_outcome:
      (Exact_textual_bytes (exact_expected target "greet" "welcome"))
    ()

let ambiguous_duplicate =
  let target = "// shifted\n" ^ simple_source ^ "\n" ^ simple_source in
  make_fixture ~fixture_id:"ambiguous-duplicate-rename"
    ~category:"ambiguous duplicate rename"
    ~original_project:[ ("src/lib.rs", simple_source) ]
    ~authored_changed_project:[ ("src/lib.rs", simple_renamed) ]
    ~retarget_base:[ ("src/lib.rs", target) ]
    ~target_path:"src/lib.rs" ~old_name:"greet" ~new_name:"welcome"
    ~fallback_expectation:no_fallback ?module_expectation:complete_root
    ~adversarial_explanation:
      "two exact declarations must remain a structured textual ambiguity"
    ~expected_outcome:Safe_conflict ()

let macro_heavy =
  let original =
    "macro_rules! define { () => { pub fn greet() {} } }\ndefine!();\n"
  in
  let target = "// independently inserted\n" ^ original in
  make_fixture ~fixture_id:"macro-heavy-textual-fallback"
    ~category:"macro-heavy textual fallback"
    ~original_project:[ ("src/lib.rs", original) ]
    ~authored_changed_project:
      [ ("src/lib.rs", replace_first original "greet" "welcome") ]
    ~retarget_base:[ ("src/lib.rs", target) ]
    ~target_path:"src/lib.rs" ~old_name:"greet" ~new_name:"welcome"
    ~fallback_expectation:macro_fallback
    ~adversarial_explanation:
      "the byte oracle is textual-only; macro-generated declarations are \
       unavailable"
    ~expected_outcome:
      (Exact_textual_bytes (exact_expected target "greet" "welcome"))
    ()

let parser_damaged =
  let original = "pub fn greet( {\n" in
  let target = "// independently inserted\n" ^ original in
  make_fixture ~fixture_id:"parser-damaged-textual-fallback"
    ~category:"invalid-source textual fallback"
    ~original_project:[ ("src/lib.rs", original) ]
    ~authored_changed_project:
      [ ("src/lib.rs", replace_first original "greet" "welcome") ]
    ~retarget_base:[ ("src/lib.rs", target) ]
    ~target_path:"src/lib.rs" ~old_name:"greet" ~new_name:"welcome"
    ~fallback_expectation:damaged_fallback
    ~adversarial_explanation:
      "parser damage allows no semantic claim but preserves exact byte fallback"
    ~expected_outcome:
      (Exact_textual_bytes (exact_expected target "greet" "welcome"))
    ()

let all =
  [
    renamed_after_insertion;
    renamed_after_within_file_move;
    renamed_after_cross_module_move;
    ambiguous_duplicate;
    macro_heavy;
    parser_damaged;
  ]
  |> List.sort (fun left right ->
      String.compare left.fixture_id right.fixture_id)

let find fixture_id =
  List.find_opt (fun fixture -> String.equal fixture.fixture_id fixture_id) all

let target_bytes fixture = find_source fixture.retarget_base fixture.target_path

let textual_patch fixture =
  let operation = fixture.textual_operation in
  Patch.make
    ~original_span:
      (patch_span operation.original_start_byte
         (String.length operation.expected_preimage))
    ~expected_preimage:operation.expected_preimage
    ~replacement:operation.replacement ~before_context:operation.before_context
    ~after_context:operation.after_context
    ~relaxed_context_bytes:Patch.default_relaxed_context_bytes
