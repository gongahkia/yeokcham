#!/usr/bin/env python3
"""Compile copied pure OCaml functions in an external directory; no project build.

This probes Encoding, Chunking and Line_hunks verbatim. Content.decode/payload/store
are extracted with their small helpers. Fixture adapters observe writer branching;
this is NOT a full Snapshot/store runtime test.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--emission', required=True, type=Path)
    p.add_argument('--work', required=True, type=Path)
    args = p.parse_args()
    root = Path(__file__).resolve().parents[4]
    work = args.work.resolve()
    if work == root or root in work.parents:
        p.error('work must be outside checkout')
    work.mkdir(parents=True, exist_ok=False)
    source_paths = ['lib/yeokcham_encoding/yeokcham_encoding.ml',
                    'lib/yeokcham_chunking/yeokcham_chunking.ml',
                    'lib/yeokcham_v1_composition/line_hunks.ml',
                    'lib/yeokcham_snapshot/yeokcham_snapshot.ml']
    sources = {name: (root/name).read_text() for name in source_paths}
    for name in source_paths[:3]:
        shutil.copy2(root/name, work/Path(name).name)
    snapshot = sources[source_paths[3]]
    section = snapshot.split('module Content = struct\n', 1)[1]
    decode = section[section.index('  let decode payload_value ='):section.index('  let load repository identity =')]
    payload = section[section.index('  let payload value ='):section.index('  let store repository value =')]
    store = section[section.index('  let store repository value ='):section.index('  let decode payload_value =')]
    helpers = snapshot[snapshot.index('let encoding_array values ='):snapshot.index('let raw_object_id value =')]
    canonical = snapshot[snapshot.index('let canonical_payload_matches expected payload ='):snapshot.index('let valid_name name =')]
    preamble = '''module Encoding = Yeokcham_encoding
type error = Encoding_error of Encoding.construction_error | Invalid_schema of string | Store_error of string
           | Unsupported_schema_version of int64 | Noncanonical_schema_bytes
let ( let* ) = Result.bind
'''
    adapters = '''module Envelope = struct type object_type = Content end
module Store = struct let put () value = Ok value end
module Manifest = struct let store_bytes () value = Ok (`Manifest (String.length value)) end
let inline_file_limit = 64 * 1024
let envelope Envelope.Content value = Ok (`Inline (Encoding.encode value))
'''
    content = preamble + helpers + canonical + adapters + '\nmodule Content = struct\n' + payload + store + decode + '\nend\n'
    main_ml = r'''
let read path = In_channel.with_open_bin path In_channel.input_all
let write path data = Out_channel.with_open_bin path (fun c -> output_string c data)
let ok = function Ok x -> x | Error _ -> failwith "probe input refused"
let () =
  match Sys.argv.(1) with
  | "cbor" ->
      let limits = Encoding.make_limits ~max_depth:64 ~max_items:131200 () |> ok in
      (match Encoding.decode ~limits (read Sys.argv.(2)) with
       | Ok value -> write Sys.argv.(3) (Encoding.encode value);print_endline "Accepted"
       | Error { Encoding.kind = (Encoding.Depth_limit_exceeded _ | Encoding.Work_limit_exceeded); _ } -> print_endline "ResourceLimit"
       | Error _ -> print_endline "InvalidEncoding")
  | "writer" ->
      (match Content.store () (read Sys.argv.(2)) |> ok with
       | `Inline bytes -> write Sys.argv.(3) bytes;print_endline "inline"
       | `Manifest size -> Printf.printf "manifest:%d\n" size)
  | "payload" ->
      let raw = read Sys.argv.(2) in
      (match Encoding.decode raw with
       | Error _ -> print_endline "InvalidEncoding"
       | Ok value ->
           write Sys.argv.(3) (Encoding.encode value);
           (match Content.decode value with
            | Ok bytes -> Printf.printf "InlineReadable:%d\n" (String.length bytes)
            | Error _ -> print_endline "NotInline"))
  | "chunks" ->
      let raw = read Sys.argv.(2) in
      let feed = int_of_string Sys.argv.(3) in
      let splitter = Yeokcham_chunking.create_splitter Yeokcham_chunking.default |> ok in
      let lengths = ref [] in
      let add xs = List.iter (fun s -> lengths := String.length s :: !lengths) xs in
      let rec loop start =
        if start < String.length raw then (
          let n = min feed (String.length raw-start) in
          add (Yeokcham_chunking.feed splitter (String.sub raw start n));loop (start+n))
      in
      loop 0;add (Yeokcham_chunking.finish splitter);
      print_endline (String.concat "," (List.map string_of_int (List.rev !lengths)))
  | "table" -> Array.iter (fun x -> Printf.printf "%016Lx\n" x) Yeokcham_chunking.buzhash_table
  | "leaf" ->
      (match Line_hunks.merge ~base:(read Sys.argv.(2))
               ~variants:[read Sys.argv.(3);read Sys.argv.(4)] with
       | Error _ -> print_endline "Conflicted"
       | Ok bytes -> write Sys.argv.(5) bytes;print_endline "Ready")
  | _ -> failwith "unknown reference mode"
'''
    (work/'probe.ml').write_text(content+main_ml)
    command = ['ocamlc', '-o', 'probe', 'yeokcham_encoding.ml', 'yeokcham_chunking.ml',
               'line_hunks.ml', 'probe.ml']
    result = subprocess.run(command, cwd=work, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    exe = work/'probe'
    corpus = json.loads((args.emission/'corpus.json').read_text())
    payloads = 0
    inline = {}
    for identity in corpus['objects']:
        source = args.emission/'payloads'/f'{identity}.bin'
        destination = work/'roundtrip.bin'
        r = subprocess.run([str(exe), 'payload', str(source), str(destination)],
                           capture_output=True, text=True, check=True)
        if r.stdout.strip() != 'InvalidEncoding':
            assert source.read_bytes() == destination.read_bytes(), identity
            payloads += 1
        if corpus['objects'][identity]['kind'] == 1 and r.stdout.startswith('InlineReadable:'):
            inline[identity] = int(r.stdout.strip().split(':')[1])
    chunks = 0
    for case in corpus['files']:
        if not case['chunk_ends']:
            continue
        ends = case['chunk_ends'];lengths = [b-a for a,b in zip([0]+ends,ends)]
        for size in case['feed_sizes_checked'] or [65536]:
            r = subprocess.check_output([str(exe), 'chunks',
                    str(args.emission/'inputs'/f'{case["name"]}.bin'), str(size)], text=True)
            actual = [int(x) for x in r.strip().split(',')] if r.strip() else []
            assert actual == lengths, (case['name'], size, actual, lengths)
            chunks += 1
    writer_boundaries = []
    for case in corpus['files']:
        r = subprocess.check_output([str(exe), 'writer',
                str(args.emission/'inputs'/f'{case["name"]}.bin'), str(work/'writer-payload.bin')], text=True).strip()
        assert r == ('inline' if case['length'] <= 65536 else f'manifest:{case["length"]}')
        if r == 'inline':
            assert (work/'writer-payload.bin').read_bytes() == (args.emission/'payloads'/f'{case["content_object"]}.bin').read_bytes()
        writer_boundaries.append({'name': case['name'], 'bytes': case['length'], 'branch': r})
    generic_checks = 0
    for case in [c for c in corpus['negative'] if c.get('layer') == 'cbor'] + corpus['generic_cbor_positive']:
        if 'raw_hex' in case:
            raw = bytes.fromhex(case['raw_hex'])
        else:
            tag, count = case['raw_recipe'];assert tag == 'zero-array'
            raw = b'\x9a'+count.to_bytes(4,'big')+bytes(count)
        (work/'generic-cbor.bin').write_bytes(raw)
        status = subprocess.check_output([str(exe), 'cbor', str(work/'generic-cbor.bin'), str(work/'generic-roundtrip.bin')], text=True).strip()
        assert status == case.get('expected', 'Accepted'), (case, status)
        if status == 'Accepted':
            assert (work/'generic-roundtrip.bin').read_bytes() == raw
        generic_checks += 1
    table = bytes.fromhex(subprocess.check_output([str(exe), 'table'], text=True))
    assert hashlib.sha256(table).hexdigest() == corpus['table_sha256_be64']
    legacy = corpus['legacy']['root']
    assert inline[legacy] == 65537
    result = {'compiler': subprocess.check_output(['ocamlc', '-version'], text=True).strip(),
              'copied_sources': {name: hashlib.sha256((root/name).read_bytes()).hexdigest()
                                 for name in source_paths},
              'extracted_content_decode_sha256': hashlib.sha256(decode.encode()).hexdigest(),
              'extracted_content_store_sha256': hashlib.sha256(store.encode()).hexdigest(),
              'canonical_payload_roundtrips': payloads, 'chunk_feed_comparisons': chunks,
              'writer_branch_checks': writer_boundaries, 'bounded_generic_cbor_checks': generic_checks,
              'table_sha256_be64': hashlib.sha256(table).hexdigest(),
              'legacy_inline_readable_length': inline[legacy],
              'inline_readable_lengths': sorted(set(inline.values())),
              'not_qualified': ['full Snapshot/store runtime', 'pinned OCaml 5.5.0 build',
                                'native filesystem', 'production Python']}
    (work/'probe-results.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
