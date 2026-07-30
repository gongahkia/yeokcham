use std::{
    env,
    ffi::OsString,
    fs,
    io::Write,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::atomic::{AtomicUsize, Ordering},
    time::{SystemTime, UNIX_EPOCH},
};

use yeokcham_core::GitRepository;

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

fn remote_helper_path() -> OsString {
    let helper = Path::new(env!("CARGO_BIN_EXE_git-remote-yeokcham"));
    let helper_directory = helper.parent().expect("helper parent directory");
    let path = env::var_os("PATH").expect("PATH");
    let paths = std::iter::once(helper_directory.to_path_buf()).chain(env::split_paths(&path));
    env::join_paths(paths).expect("valid PATH")
}

fn remote_uri(repository: &Path) -> String {
    format!("yeokcham::{}", repository.display())
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

#[test]
fn remote_helper_clones_lists_refs_and_repeats_fetch_without_source_disclosure() {
    let directory = TestDirectory::new();
    let source = directory.path().join("source");
    let repository = directory.path().join("repository");
    let checkout = directory.path().join("checkout");
    fs::create_dir(&source).expect("create source repository");
    run_git(&source, &["init", "-b", "main"]);
    run_git(&source, &["config", "user.name", "Yeokcham Test"]);
    run_git(
        &source,
        &["config", "user.email", "yeokcham-test@example.invalid"],
    );
    fs::write(source.join("README.md"), b"remote helper fixture\n").expect("write fixture");
    fs::write(source.join("tiny.txt"), b"tiny\n").expect("write tiny blob");
    run_git(&source, &["add", "."]);
    run_git(&source, &["commit", "-m", "fixture"]);
    run_git(&source, &["branch", "topic"]);
    run_git(&source, &["tag", "-a", "v1", "-m", "version one"]);

    let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .args(["init", "--from-git"])
        .arg(&source)
        .arg(&repository)
        .output()
        .expect("import source repository");
    assert!(
        output.status.success(),
        "import must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let helper_path = remote_helper_path();
    let remote = remote_uri(&repository);
    let output = Command::new("git")
        .args(["ls-remote", "--heads", "--tags", &remote])
        .env("PATH", &helper_path)
        .output()
        .expect("list remote refs");
    assert!(
        output.status.success(),
        "ls-remote must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let refs = String::from_utf8(output.stdout).expect("ref listing is UTF-8");
    assert!(refs.contains("refs/heads/main"));
    assert!(refs.contains("refs/heads/topic"));
    assert!(refs.contains("refs/tags/v1"));

    let output = Command::new("git")
        .args(["clone", "--quiet", &remote])
        .arg(&checkout)
        .env("PATH", &helper_path)
        .output()
        .expect("clone remote helper");
    assert!(
        output.status.success(),
        "clone must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        fs::read(source.join("README.md")).expect("read source"),
        fs::read(checkout.join("README.md")).expect("read checkout")
    );
    assert_eq!(
        run_git(&source, &["rev-parse", "refs/tags/v1"]),
        run_git(&checkout, &["rev-parse", "refs/tags/v1"])
    );
    assert_eq!(
        GitRepository::open(&source)
            .expect("open source")
            .reachable_object_ids()
            .expect("source object IDs"),
        GitRepository::open(&checkout)
            .expect("open checkout")
            .reachable_object_ids()
            .expect("checkout object IDs")
    );
    run_git(&checkout, &["fsck", "--full", "--strict"]);

    let output = Command::new("git")
        .arg("-C")
        .arg(&checkout)
        .args(["fetch", "--quiet", "origin"])
        .env("PATH", &helper_path)
        .output()
        .expect("repeat fetch");
    assert!(
        output.status.success(),
        "repeat fetch must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(run_git(&checkout, &["status", "--porcelain"]).is_empty());

    fs::write(
        source.join("README.md"),
        b"remote helper fixture, updated\n",
    )
    .expect("update fixture");
    run_git(&source, &["add", "README.md"]);
    run_git(&source, &["commit", "-m", "updated fixture"]);
    run_git(&source, &["branch", "-D", "topic"]);
    let device_id = "6ba7b814-9dad-41d1-80b4-00c04fd430c8";
    let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .args(["sync", "--from-git"])
        .arg(&source)
        .arg(&repository)
        .args(["--device", device_id])
        .output()
        .expect("sync updated source");
    assert!(
        output.status.success(),
        "sync must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .args(["inspect", "refs"])
        .arg(&repository)
        .output()
        .expect("inspect ref journal");
    assert!(output.status.success());
    let refs = String::from_utf8(output.stdout).expect("ref inspection is UTF-8");
    assert!(refs.contains("events=1"));
    assert!(refs.contains(device_id));

    let output = Command::new("git")
        .arg("-C")
        .arg(&checkout)
        .args(["fetch", "--quiet", "--prune", "origin"])
        .env("PATH", &helper_path)
        .output()
        .expect("fetch update");
    assert!(
        output.status.success(),
        "fetch update must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        run_git(&source, &["rev-parse", "refs/heads/main"]),
        run_git(&checkout, &["rev-parse", "refs/remotes/origin/main"])
    );
    run_git(&checkout, &["merge", "--ff-only", "origin/main"]);
    assert_eq!(
        fs::read(source.join("README.md")).expect("read updated source"),
        fs::read(checkout.join("README.md")).expect("read checkout before fast-forward")
    );
    let output = Command::new("git")
        .arg("-C")
        .arg(&checkout)
        .args(["rev-parse", "--verify", "refs/remotes/origin/topic"])
        .output()
        .expect("check pruned branch");
    assert!(!output.status.success(), "deleted branch must be pruned");
    run_git(&checkout, &["fsck", "--full", "--strict"]);

    let mut helper = Command::new(env!("CARGO_BIN_EXE_git-remote-yeokcham"))
        .arg("secret-source-location")
        .env("YEOKCHAM_LOG", "debug")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("start helper");
    helper
        .stdin
        .take()
        .expect("helper stdin")
        .write_all(b"capabilities\n\n")
        .expect("write helper protocol");
    let output = helper.wait_with_output().expect("wait helper");
    assert!(output.status.success());
    assert_eq!(output.stdout, b"connect\n\n");
    let stderr = String::from_utf8(output.stderr).expect("stderr is UTF-8");
    assert!(stderr.contains("remote_helper_command"));
    assert!(!stderr.contains("secret-source-location"));
}
