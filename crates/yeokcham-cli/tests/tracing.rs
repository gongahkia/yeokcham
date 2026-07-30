use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::atomic::{AtomicUsize, Ordering},
    time::{SystemTime, UNIX_EPOCH},
};

static TEST_COUNTER: AtomicUsize = AtomicUsize::new(0);

struct TestDirectory(PathBuf);

impl TestDirectory {
    fn new() -> Self {
        let sequence = TEST_COUNTER.fetch_add(1, Ordering::Relaxed);
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock after epoch")
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "yeokcham-cli-test-{}-{nanos}-{sequence}",
            std::process::id()
        ));
        fs::create_dir(&path).expect("create test directory");
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TestDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn run_git(directory: &Path, arguments: &[&str]) -> Vec<u8> {
    let output = Command::new("git")
        .arg("-C")
        .arg(directory)
        .args(arguments)
        .output()
        .expect("run Git");
    assert!(
        output.status.success(),
        "Git command must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    output.stdout
}

#[test]
fn default_filter_emits_no_debug_output() {
    let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .arg("--help")
        .env_remove("YEOKCHAM_LOG")
        .output()
        .expect("run yeokcham");

    assert!(output.status.success());
    assert!(output.stderr.is_empty());
}

#[test]
fn debug_filter_emits_startup_event() {
    let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .arg("--help")
        .env("YEOKCHAM_LOG", "debug")
        .output()
        .expect("run yeokcham");
    let stderr = String::from_utf8(output.stderr).expect("stderr is UTF-8");

    assert!(output.status.success());
    assert!(stderr.contains("yeokcham initialized"));
    assert!(stderr.contains("event=\"startup\""));
}

#[test]
fn invalid_filter_does_not_echo_input() {
    let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .env("YEOKCHAM_LOG", "[secret-content")
        .output()
        .expect("run yeokcham");
    let stderr = String::from_utf8(output.stderr).expect("stderr is UTF-8");

    assert!(!output.status.success());
    assert_eq!(
        stderr,
        "error[invalid_input]: invalid YEOKCHAM_LOG filter\n"
    );
    assert!(!stderr.contains("secret-content"));
}

#[test]
fn cli_import_verify_inspect_and_export_round_trip() {
    let directory = TestDirectory::new();
    let source = directory.path().join("source");
    let repository = directory.path().join("repository");
    let exported = directory.path().join("exported.git");
    let checkout = directory.path().join("checkout");
    fs::create_dir(&source).expect("create source repository");
    run_git(&source, &["init", "-b", "main"]);
    run_git(&source, &["config", "user.name", "Yeokcham Test"]);
    run_git(
        &source,
        &["config", "user.email", "yeokcham-test@example.invalid"],
    );
    fs::write(source.join("tiny.txt"), b"tiny").expect("write tiny blob");
    fs::write(source.join("whole.bin"), vec![0x5a; 2_048]).expect("write whole blob");
    fs::write(source.join("chunked.bin"), vec![0x6b; 64 * 1024]).expect("write chunked blob");
    run_git(&source, &["add", "."]);
    run_git(&source, &["commit", "-m", "fixture"]);
    run_git(&source, &["gc", "--prune=now"]);

    let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .args(["init", "--from-git"])
        .arg(&source)
        .arg(&repository)
        .output()
        .expect("import with CLI");
    assert!(
        output.status.success(),
        "CLI import must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(String::from_utf8_lossy(&output.stdout).contains("chunked_blobs=1"));

    let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .arg("verify")
        .arg(&repository)
        .output()
        .expect("verify with CLI");
    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("tiny_blob_group_manifests=1"));
    assert!(stdout.contains("ref_snapshots=1"));

    let object_id = String::from_utf8(run_git(&source, &["rev-parse", "HEAD:chunked.bin"]))
        .expect("object ID is UTF-8");
    let object_id = object_id.trim();
    let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .args(["inspect", "object"])
        .arg(&repository)
        .arg(object_id)
        .output()
        .expect("inspect object with CLI");
    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout).contains("storage=ChunkedBlob"));

    let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .args(["inspect", "storage"])
        .arg(&repository)
        .output()
        .expect("inspect storage with CLI");
    assert!(output.status.success());

    let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .arg("export-git")
        .arg(&repository)
        .arg(&exported)
        .output()
        .expect("export with CLI");
    assert!(output.status.success());
    let output = Command::new("git")
        .arg("--git-dir")
        .arg(&exported)
        .args(["fsck", "--full", "--strict"])
        .output()
        .expect("run Git fsck");
    assert!(
        output.status.success(),
        "Git fsck must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    run_git(
        directory.path(),
        &["clone", exported.to_str().expect("UTF-8 path"), "checkout"],
    );
    assert_eq!(
        fs::read(source.join("chunked.bin")).expect("read source"),
        fs::read(checkout.join("chunked.bin")).expect("read checkout")
    );
}
