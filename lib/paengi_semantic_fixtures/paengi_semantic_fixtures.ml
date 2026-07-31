[@@@warning "-41-42-45"]

module Patch = Paengi_textual_patch
module Retarget = Paengi_semantic_retarget

type expected_outcome = Exact_bytes of string | Safe_conflict

type textual_operation = {
  original_start_byte : int;
  expected_preimage : string;
  replacement : string;
  before_context : string;
  after_context : string;
}

type fixture = {
  dataset_version : int;
  fixture_id : string;
  category : string;
  operation_id : string;
  original_project : (string * string) list;
  authored_changed_project : (string * string) list;
  retarget_base : (string * string) list;
  target_path : string;
  textual_operation : textual_operation;
  semantic_anchor : Retarget.anchor;
  semantic_candidates : Retarget.candidate list;
  expected_target_span : Patch.span option;
  expected_outcome : expected_outcome;
  acceptable_confidence_ceiling : Retarget.confidence;
  parser_complete : bool;
  resolution_complete : bool;
  type_resolution_complete : bool;
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

let patch_span start_byte width =
  Patch.{ start_byte; end_byte = start_byte + width }

let semantic_span start_byte width =
  Retarget.{ start_byte; end_byte = start_byte + width }

let context source start_byte width =
  let before_start = max 0 (start_byte - 12) in
  let after_start = start_byte + width in
  let after_end = min (String.length source) (after_start + 12) in
  Retarget.
    {
      before = String.sub source before_start (start_byte - before_start);
      selected = String.sub source start_byte width;
      after = String.sub source after_start (after_end - after_start);
    }

let splice source selected replacement =
  String.sub source 0 selected.Patch.start_byte
  ^ replacement
  ^ String.sub source selected.Patch.end_byte
      (String.length source - selected.Patch.end_byte)

let source = "export function greet(value: string): string { return value; }\n"

let authored =
  "export function welcome(value: string): string { return value; }\n"

let make_candidate ~candidate_id ~module_path ~target ~name_start
    ?(lexical_path = [ "top-level"; "function:greet" ])
    ?(resolved_symbol = Some "project.greet") ?(overload_ordinal = 0) () =
  let declaration_span = semantic_span name_start (String.length "greet") in
  Retarget.
    {
      candidate_id;
      module_path;
      exported_symbol_path = [ "greet" ];
      resolved_symbol;
      declaration_kind = "function";
      overload_ordinal;
      signature_digest = Some "(value:string)=>string";
      type_shape_digest = Some "function-1-string-string";
      lexical_path;
      declaration_shape_digest = "function:value:string:string";
      token_digest = Some "function-greet-value-string";
      declaration_span;
      name_span = Some declaration_span;
      declaration_bytes = "greet";
      declaration_context = context target name_start (String.length "greet");
      merged_declaration_count = 1;
    }

let make_anchor ~module_path ~original_start =
  let original_span = semantic_span original_start (String.length "greet") in
  Retarget.
    {
      operation_id = "rename-greet-to-welcome";
      module_path;
      exported_symbol_path = [ "greet" ];
      resolved_symbol = Some "project.greet";
      declaration_kind = "function";
      overload_ordinal = 0;
      signature_digest = Some "(value:string)=>string";
      type_shape_digest = Some "function-1-string-string";
      lexical_path = [ "top-level"; "function:greet" ];
      declaration_shape_digest = "function:value:string:string";
      token_digest = Some "function-greet-value-string";
      original_span;
      original_bytes = "greet";
      original_context = context source original_start (String.length "greet");
    }

let make_applicable ?(target_path = "src/greeting.ts")
    ?(module_path = target_path) ?(target = source) ?(parser_complete = true)
    ?(resolution_complete = true) ?(type_resolution_complete = true)
    ?(ceiling = Retarget.High) ?(explanation = "independent surrounding change")
    fixture_id category =
  let original_path = "src/greeting.ts" in
  let original_start = require_substring source "greet" in
  let target_start = require_substring target "greet" in
  let target_span = patch_span target_start (String.length "greet") in
  let anchor = make_anchor ~module_path:original_path ~original_start in
  let candidate =
    make_candidate
      ~candidate_id:(fixture_id ^ ":candidate")
      ~module_path ~target ~name_start:target_start ()
  in
  {
    dataset_version = version;
    fixture_id;
    category;
    operation_id = "rename-greet-to-welcome";
    original_project = [ (original_path, source) ];
    authored_changed_project = [ (original_path, authored) ];
    retarget_base = [ (target_path, target) ];
    target_path;
    textual_operation =
      {
        original_start_byte = original_start;
        expected_preimage = "greet";
        replacement = "welcome";
        before_context = (context source original_start 5).Retarget.before;
        after_context = (context source original_start 5).Retarget.after;
      };
    semantic_anchor = anchor;
    semantic_candidates = [ candidate ];
    expected_target_span = Some target_span;
    expected_outcome = Exact_bytes (splice target target_span "welcome");
    acceptable_confidence_ceiling = ceiling;
    parser_complete;
    resolution_complete;
    type_resolution_complete;
    adversarial_explanation = explanation;
  }

let make_ambiguous fixture_id category explanation =
  let target =
    "// independently inserted\n" ^ source ^ "// a plausible duplicate\n"
    ^ source
  in
  let original_start = require_substring source "greet" in
  let first_start = require_substring target "greet" in
  let second_start =
    match find_substring target "greet" (first_start + 1) with
    | Some start -> start
    | None -> assert false
  in
  let anchor = make_anchor ~module_path:"src/greeting.ts" ~original_start in
  {
    dataset_version = version;
    fixture_id;
    category;
    operation_id = "rename-greet-to-welcome";
    original_project = [ ("src/greeting.ts", source) ];
    authored_changed_project = [ ("src/greeting.ts", authored) ];
    retarget_base = [ ("src/greeting.ts", target) ];
    target_path = "src/greeting.ts";
    textual_operation =
      {
        original_start_byte = original_start;
        expected_preimage = "greet";
        replacement = "welcome";
        before_context = (context source original_start 5).Retarget.before;
        after_context = (context source original_start 5).Retarget.after;
      };
    semantic_anchor = anchor;
    semantic_candidates =
      [
        make_candidate ~candidate_id:(fixture_id ^ ":a")
          ~module_path:"src/greeting.ts" ~target ~name_start:first_start ();
        make_candidate ~candidate_id:(fixture_id ^ ":b")
          ~module_path:"src/greeting.ts" ~target ~name_start:second_start ();
      ];
    expected_target_span = None;
    expected_outcome = Safe_conflict;
    acceptable_confidence_ceiling = Retarget.Unknown;
    parser_complete = true;
    resolution_complete = true;
    type_resolution_complete = true;
    adversarial_explanation = explanation;
  }

let make_scope_disambiguated () =
  let fixture_id = "same-name-different-scopes" in
  let target =
    "// independently inserted\n" ^ source ^ "// a plausible duplicate\n"
    ^ source
  in
  let original_start = require_substring source "greet" in
  let first_start = require_substring target "greet" in
  let second_start =
    match find_substring target "greet" (first_start + 1) with
    | Some start -> start
    | None -> assert false
  in
  let target_span = patch_span first_start (String.length "greet") in
  let anchor = make_anchor ~module_path:"src/greeting.ts" ~original_start in
  {
    dataset_version = version;
    fixture_id;
    category = "same-name declarations in different scopes";
    operation_id = "rename-greet-to-welcome";
    original_project = [ ("src/greeting.ts", source) ];
    authored_changed_project = [ ("src/greeting.ts", authored) ];
    retarget_base = [ ("src/greeting.ts", target) ];
    target_path = "src/greeting.ts";
    textual_operation =
      {
        original_start_byte = original_start;
        expected_preimage = "greet";
        replacement = "welcome";
        before_context = (context source original_start 5).Retarget.before;
        after_context = (context source original_start 5).Retarget.after;
      };
    semantic_anchor = anchor;
    semantic_candidates =
      [
        make_candidate
          ~candidate_id:(fixture_id ^ ":lexical-match")
          ~module_path:"src/greeting.ts" ~target ~name_start:first_start ();
        make_candidate
          ~candidate_id:(fixture_id ^ ":other-scope")
          ~module_path:"src/greeting.ts" ~target ~name_start:second_start
          ~lexical_path:[ "namespace:Other"; "function:greet" ]
          ();
      ];
    expected_target_span = Some target_span;
    expected_outcome = Exact_bytes (splice target target_span "welcome");
    acceptable_confidence_ceiling = Retarget.High;
    parser_complete = true;
    resolution_complete = true;
    type_resolution_complete = true;
    adversarial_explanation =
      "identical textual contexts require lexical declaration-path evidence";
  }

let make_missing fixture_id category explanation =
  let target =
    "// target deleted the declaration\nexport const gone = true;\n"
  in
  let original_start = require_substring source "greet" in
  {
    dataset_version = version;
    fixture_id;
    category;
    operation_id = "rename-greet-to-welcome";
    original_project = [ ("src/greeting.ts", source) ];
    authored_changed_project = [ ("src/greeting.ts", authored) ];
    retarget_base = [ ("src/greeting.ts", target) ];
    target_path = "src/greeting.ts";
    textual_operation =
      {
        original_start_byte = original_start;
        expected_preimage = "greet";
        replacement = "welcome";
        before_context = (context source original_start 5).Retarget.before;
        after_context = (context source original_start 5).Retarget.after;
      };
    semantic_anchor = make_anchor ~module_path:"src/greeting.ts" ~original_start;
    semantic_candidates = [];
    expected_target_span = None;
    expected_outcome = Safe_conflict;
    acceptable_confidence_ceiling = Retarget.Unknown;
    parser_complete = false;
    resolution_complete = false;
    type_resolution_complete = false;
    adversarial_explanation = explanation;
  }

let make_already_satisfied () =
  let original_start = require_substring source "greet" in
  {
    dataset_version = version;
    fixture_id = "already-satisfied-change";
    category = "already-satisfied change";
    operation_id = "rename-greet-to-welcome";
    original_project = [ ("src/greeting.ts", source) ];
    authored_changed_project = [ ("src/greeting.ts", authored) ];
    retarget_base = [ ("src/greeting.ts", authored) ];
    target_path = "src/greeting.ts";
    textual_operation =
      {
        original_start_byte = original_start;
        expected_preimage = "greet";
        replacement = "welcome";
        before_context = (context source original_start 5).Retarget.before;
        after_context = (context source original_start 5).Retarget.after;
      };
    semantic_anchor = make_anchor ~module_path:"src/greeting.ts" ~original_start;
    semantic_candidates = [];
    expected_target_span = None;
    expected_outcome = Exact_bytes authored;
    acceptable_confidence_ceiling = Retarget.Low;
    parser_complete = true;
    resolution_complete = true;
    type_resolution_complete = true;
    adversarial_explanation = "the authored replacement is already present";
  }

let formatting_target =
  "// formatting-only independent change\r\n\
   export function greet(\r\n\
  \  value: string,\r\n\
   ): string { return value; }\r\n"

let unicode_target =
  "// 😀 café\n\
   export function greet(value: string): string { return \"héllo\"; }\n"

let bom_target = "\239\187\191" ^ source
let binary_target = "\000\255\239\187\191\r\nTOKEN\000"

let simple_categories =
  [
    ("function-rename", "function rename", source, "simple same-file rename");
    ( "function-move-within-file",
      "function move within one file",
      "// moved below helper\n" ^ source,
      "declaration position moved" );
    ( "function-move-across-files",
      "function move across files",
      "// moved module\n" ^ source,
      "module path is intentionally changed" );
    ("class-rename", "class rename", source, "class-shaped operation record");
    ("method-rename", "method rename", source, "method-shaped operation record");
    ("method-move", "method move", "class Api {}\n" ^ source, "method moved");
    ( "module-reorganisation",
      "module reorganisation",
      "// re-exported from a reorganised module\n" ^ source,
      "module evidence must not be a permanent identity" );
    ("named-exports", "named exports", source, "export path evidence");
    ("default-exports", "default exports", source, "default export evidence");
    ("re-export-aliases", "re-export aliases", source, "alias evidence");
    ( "imports-and-aliases",
      "imports and aliases",
      source,
      "import alias evidence" );
    ("overloads", "overloads", source, "overload ordinal evidence");
    ("merged-declarations", "merged declarations", source, "merged declarations");
    ( "namespaces",
      "namespaces",
      "namespace Demo {}\n" ^ source,
      "namespace path" );
    ( "generic-functions-methods",
      "generic functions and methods",
      source,
      "generic shape" );
    ( "decorators",
      "decorators",
      "@sealed\n" ^ source,
      "pinned compiler decorator parsing" );
    ( "arrow-functions",
      "arrow functions assigned to names",
      source,
      "arrow declaration" );
    ( "nested-declarations",
      "nested declarations",
      "function outer() {}\n" ^ source,
      "lexical path" );
    ( "nearby-unrelated-insertion",
      "nearby unrelated insertion",
      "const unrelated = 1;\n" ^ source,
      "nearby insertion" );
    ( "formatting-only",
      "formatting-only changes",
      formatting_target,
      "CRLF formatting" );
    ( "comment-doc-changes",
      "comment and documentation changes",
      "/** changed docs */\n" ^ source,
      "comment drift" );
    ("crlf", "CRLF", formatting_target, "CRLF byte preservation");
    ("lf", "LF", source, "LF byte preservation");
    ("utf8-bom", "UTF-8 BOM", bom_target, "BOM shifts byte spans");
    ( "unicode-identifiers-strings",
      "Unicode identifiers and strings",
      unicode_target,
      "Unicode bytes" );
    ( "emoji-before-spans",
      "emoji before declaration spans",
      "// 😀\n" ^ source,
      "emoji byte spans" );
    ( "tsx-functions-components",
      "TSX functions and components",
      source,
      "TSX component declaration" );
    ( "jsx-text-attributes",
      "JSX text and attributes",
      source,
      "JSX token context" );
    ( "tsconfig-path-mappings",
      "tsconfig path mappings",
      source,
      "virtual path mapping evidence" );
  ]

let all =
  let ordinary =
    List.map
      (fun (fixture_id, category, target, explanation) ->
        let target_path, module_path =
          if String.equal fixture_id "function-move-across-files" then
            ("src/moved/greeting.ts", "src/moved/greeting.ts")
          else ("src/greeting.ts", "src/greeting.ts")
        in
        make_applicable ~target_path ~module_path ~target ~explanation
          fixture_id category)
      simple_categories
  in
  let incomplete =
    [
      make_applicable
        ~target:("// changed signature\n" ^ source)
        ~parser_complete:false ~resolution_complete:false
        ~type_resolution_complete:false ~ceiling:Retarget.Low
        ~explanation:"changed signature must not receive high confidence"
        "changed-function-signature" "changed function signatures";
      make_applicable
        ~target:("// split into helpers\n" ^ source)
        ~parser_complete:false ~resolution_complete:false
        ~type_resolution_complete:false ~ceiling:Retarget.Low
        ~explanation:"split declarations are intentionally incomplete"
        "function-split" "function split";
      make_applicable
        ~target:("// merged declarations\n" ^ source)
        ~parser_complete:false ~resolution_complete:false
        ~type_resolution_complete:false ~ceiling:Retarget.Low
        ~explanation:"merged declarations are intentionally incomplete"
        "function-merge" "function merge";
      make_applicable ~target:"function greet( {\n" ~parser_complete:false
        ~resolution_complete:false ~type_resolution_complete:false
        ~ceiling:Retarget.Low ~explanation:"parse-damaged source"
        "parse-damaged-source" "parse-damaged source";
      make_applicable
        ~target:("import { absent } from 'missing';\n" ^ source)
        ~resolution_complete:false ~type_resolution_complete:false
        ~ceiling:Retarget.Low ~explanation:"unresolved import"
        "unresolved-imports" "unresolved imports";
    ]
  in
  let binary =
    let original_start = 2 in
    {
      dataset_version = version;
      fixture_id = "binary-textual-only";
      category = "binary or non-TypeScript textual-only behaviour";
      operation_id = "replace-token";
      original_project = [ ("assets/data.bin", "\000\255TOKEN\000") ];
      authored_changed_project = [ ("assets/data.bin", "\000\255DONE\000") ];
      retarget_base = [ ("assets/data.bin", binary_target) ];
      target_path = "assets/data.bin";
      textual_operation =
        {
          original_start_byte = original_start;
          expected_preimage = "TOKEN";
          replacement = "DONE";
          before_context = "\000\255";
          after_context = "\000";
        };
      semantic_anchor =
        Retarget.
          {
            (make_anchor ~module_path:"assets/data.bin" ~original_start) with
            operation_id = "replace-token";
          };
      semantic_candidates = [];
      expected_target_span = Some (patch_span 7 5);
      expected_outcome = Exact_bytes "\000\255\239\187\191\r\nDONE\000";
      acceptable_confidence_ceiling = Retarget.Unknown;
      parser_complete = false;
      resolution_complete = false;
      type_resolution_complete = false;
      adversarial_explanation = "arbitrary bytes are a textual-only case";
    }
  in
  ordinary @ incomplete
  @ [
      make_scope_disambiguated ();
      make_ambiguous "duplicate-highly-similar"
        "duplicate highly similar declarations"
        "identical declaration evidence must remain ambiguous";
      make_ambiguous "deliberately-ambiguous" "deliberately ambiguous targets"
        "adversarial duplicate candidates";
      make_missing "missing-target" "missing target"
        "the original declaration was removed";
      make_already_satisfied ();
      binary;
    ]

let find fixture_id =
  List.find_opt (fun fixture -> String.equal fixture.fixture_id fixture_id) all

let textual_patch (fixture : fixture) =
  let operation = fixture.textual_operation in
  Patch.make
    ~original_span:
      (patch_span operation.original_start_byte
         (String.length operation.expected_preimage))
    ~expected_preimage:operation.expected_preimage
    ~replacement:operation.replacement ~before_context:operation.before_context
    ~after_context:operation.after_context
    ~relaxed_context_bytes:Patch.default_relaxed_context_bytes

let target_bytes (fixture : fixture) =
  match List.assoc_opt fixture.target_path fixture.retarget_base with
  | Some contents -> contents
  | None -> invalid_arg ("fixture target path is absent: " ^ fixture.fixture_id)

let semantic_result (fixture : fixture) =
  Retarget.select
    ~completeness:
      Retarget.
        {
          parser_complete = fixture.parser_complete;
          resolution_complete = fixture.resolution_complete;
          type_resolution_complete = fixture.type_resolution_complete;
        }
    ~anchor:fixture.semantic_anchor ~candidates:fixture.semantic_candidates
