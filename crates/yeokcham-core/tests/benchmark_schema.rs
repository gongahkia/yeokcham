use std::path::{Path, PathBuf};
use std::{fs, fs::File};

use serde_json::Value;

fn workspace_path(relative: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join(relative)
}

fn read_json(relative: &str) -> Value {
    let path = workspace_path(relative);
    let file = File::open(&path).unwrap_or_else(|error| panic!("open {}: {error}", path.display()));
    serde_json::from_reader(file)
        .unwrap_or_else(|error| panic!("parse {}: {error}", path.display()))
}

#[test]
fn benchmark_schema_and_example_are_valid() {
    let schema = read_json("benchmarks/schema/benchmark-result-v1.schema.json");
    let example = read_json("benchmarks/examples/benchmark-result-v1.synthetic.json");

    jsonschema::draft202012::meta::validate(&schema).expect("schema matches Draft 2020-12");
    let validator = jsonschema::draft202012::options()
        .should_validate_formats(true)
        .build(&schema)
        .expect("compile benchmark schema");
    validator
        .validate(&example)
        .expect("example matches schema");
}

#[test]
fn benchmark_schema_rejects_missing_provenance() {
    let schema = read_json("benchmarks/schema/benchmark-result-v1.schema.json");
    let mut example = read_json("benchmarks/examples/benchmark-result-v1.synthetic.json");
    example["provenance"]
        .as_object_mut()
        .expect("provenance object")
        .remove("git_version");

    assert!(jsonschema::draft202012::validate(&schema, &example).is_err());
}

#[test]
fn benchmark_schema_rejects_negative_metrics_and_unknown_fields() {
    let schema = read_json("benchmarks/schema/benchmark-result-v1.schema.json");
    let validator = jsonschema::draft202012::new(&schema).expect("compile benchmark schema");
    let mut example = read_json("benchmarks/examples/benchmark-result-v1.synthetic.json");
    example["metrics"]["peak_rss_bytes"] = (-1).into();
    example["unexpected"] = true.into();

    assert!(!validator.is_valid(&example));
}

#[test]
fn benchmark_schema_rejects_invalid_time_and_sensitive_data() {
    let schema = read_json("benchmarks/schema/benchmark-result-v1.schema.json");
    let validator = jsonschema::draft202012::options()
        .should_validate_formats(true)
        .build(&schema)
        .expect("compile benchmark schema");
    let mut example = read_json("benchmarks/examples/benchmark-result-v1.synthetic.json");
    example["recorded_at"] = "not-a-timestamp".into();
    example["contains_sensitive_data"] = true.into();

    assert!(!validator.is_valid(&example));
}

#[test]
fn benchmark_schema_accepts_unavailable_platform_io_metrics() {
    let schema = read_json("benchmarks/schema/benchmark-result-v1.schema.json");
    let validator = jsonschema::draft202012::new(&schema).expect("compile benchmark schema");
    let mut example = read_json("benchmarks/examples/benchmark-result-v1.synthetic.json");
    example["metrics"]["io_bytes_read"] = Value::Null;
    example["metrics"]["io_bytes_written"] = Value::Null;

    assert!(validator.is_valid(&example));
}

#[test]
fn every_committed_measured_result_matches_the_schema() {
    let schema = read_json("benchmarks/schema/benchmark-result-v1.schema.json");
    let validator = jsonschema::draft202012::options()
        .should_validate_formats(true)
        .build(&schema)
        .expect("compile benchmark schema");
    let mut results = Vec::new();
    collect_json_files(&workspace_path("benchmarks/results"), &mut results);

    for result in results {
        let file = File::open(&result)
            .unwrap_or_else(|error| panic!("open {}: {error}", result.display()));
        let value: Value = serde_json::from_reader(file)
            .unwrap_or_else(|error| panic!("parse {}: {error}", result.display()));
        validator
            .validate(&value)
            .unwrap_or_else(|error| panic!("validate {}: {error}", result.display()));
    }
}

fn collect_json_files(directory: &Path, files: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    for entry in entries {
        let entry = entry.expect("read benchmark result directory entry");
        let path = entry.path();
        if path.is_dir() {
            collect_json_files(&path, files);
        } else if path
            .extension()
            .is_some_and(|extension| extension == "json")
        {
            files.push(path);
        }
    }
}
