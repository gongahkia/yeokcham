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

use yeokcham_core::{GitRepository, LocalRepository, RepositoryEncryptionKey, RepositoryKeyExport};

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

fn pack_cache_entries(repository: &Path) -> Vec<PathBuf> {
    let cache = repository.join("cache/packs");
    fs::read_dir(&cache)
        .expect("read pack cache")
        .map(|entry| entry.expect("read pack cache entry").path())
        .filter(|path| path.is_dir())
        .collect()
}

fn pack_cache_entry(repository: &Path) -> PathBuf {
    let entries = pack_cache_entries(repository);
    assert_eq!(entries.len(), 1, "one effective ref state must be cached");
    entries.into_iter().next().expect("cached entry")
}

fn directory_byte_count(path: &Path) -> u64 {
    fs::read_dir(path)
        .expect("read cache directory")
        .map(|entry| entry.expect("read cache entry").path())
        .map(|entry| {
            let metadata = fs::symlink_metadata(&entry).expect("inspect cache entry");
            assert!(
                !metadata.file_type().is_symlink(),
                "cache must not contain symlinks"
            );
            if metadata.is_dir() {
                directory_byte_count(&entry)
            } else {
                metadata.len()
            }
        })
        .sum()
}

fn run_git_bare(repository: &Path, arguments: &[&str]) -> Vec<u8> {
    let output = Command::new("git")
        .arg("--git-dir")
        .arg(repository)
        .args(arguments)
        .output()
        .expect("run Git in bare repository");
    assert!(
        output.status.success(),
        "Git command must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    output.stdout
}

#[cfg(unix)]
fn make_cache_file_writable(path: &Path) {
    use std::os::unix::fs::PermissionsExt;

    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
        .expect("make disposable cache file writable");
}

#[cfg(not(unix))]
fn make_cache_file_writable(_: &Path) {
    panic!("pack-cache corruption test requires Unix permissions");
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
fn cli_creates_a_non_overwriting_passphrase_encrypted_recovery_export() {
    let directory = TestDirectory::new();
    let repository = directory.path().join("repository");
    let export_path = directory.path().join("repository.ykrk");
    let repository = LocalRepository::create(&repository).expect("create repository");
    let passphrase = b"test recovery passphrase\n";
    let mut command = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .args(["key", "create-export", "--passphrase-stdin"])
        .arg(repository.path())
        .arg(&export_path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("start key export");
    command
        .stdin
        .take()
        .expect("key-export stdin")
        .write_all(passphrase)
        .expect("write passphrase");
    let output = command.wait_with_output().expect("wait key export");
    assert!(
        output.status.success(),
        "key export must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        String::from_utf8_lossy(&output.stdout).contains("created encrypted recovery key export")
    );
    assert!(!String::from_utf8_lossy(&output.stderr).contains("test recovery passphrase"));
    let export = RepositoryKeyExport::from_bytes(fs::read(&export_path).expect("read export"))
        .expect("parse export");
    assert_eq!(
        RepositoryEncryptionKey::import_with_passphrase(&export, b"test recovery passphrase")
            .expect("import export")
            .repository_id(),
        repository.id(),
    );

    let mut duplicate = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .args(["key", "create-export", "--passphrase-stdin"])
        .arg(repository.path())
        .arg(&export_path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("start duplicate key export");
    duplicate
        .stdin
        .take()
        .expect("duplicate stdin")
        .write_all(passphrase)
        .expect("write duplicate passphrase");
    let output = duplicate
        .wait_with_output()
        .expect("wait duplicate key export");
    assert!(!output.status.success());
    assert!(!String::from_utf8_lossy(&output.stderr).contains("test recovery passphrase"));
}

#[test]
fn cli_persists_and_inspects_a_token_free_github_mirror_policy() {
    let directory = TestDirectory::new();
    let repository =
        LocalRepository::create(directory.path().join("repository")).expect("create repository");
    let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .args(["github", "configure"])
        .arg(repository.path())
        .args([
            "--repository",
            "yeokcham/example",
            "--direction",
            "bidirectional-fast-forward",
            "--force-update",
            "require-exact-checkpoint",
            "--publish",
            "heads",
            "--publish",
            "refs/tags/v1.0",
        ])
        .output()
        .expect("configure GitHub mirror");
    assert!(
        output.status.success(),
        "GitHub configuration must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        output.stdout,
        b"github_mirror_configured direction=bidirectional-fast-forward force_update_policy=require-exact-checkpoint publication_rules=2\n"
    );
    assert!(!String::from_utf8_lossy(&output.stderr).contains("yeokcham/example"));

    let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .args(["github", "inspect"])
        .arg(repository.path())
        .output()
        .expect("inspect GitHub mirror");
    assert!(
        output.status.success(),
        "GitHub inspection must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        output.stdout,
        b"github_mirror_configured direction=bidirectional-fast-forward force_update_policy=require-exact-checkpoint publication_rules=2 checkpoints=0\n"
    );
    assert!(!String::from_utf8_lossy(&output.stdout).contains("yeokcham/example"));
}

#[test]
fn cli_previews_the_complete_selected_github_publication_graph() {
    let directory = TestDirectory::new();
    let source = directory.path().join("source");
    let repository = directory.path().join("repository");
    fs::create_dir(&source).expect("create source repository");
    run_git(&source, &["init", "-b", "main"]);
    run_git(&source, &["config", "user.name", "Yeokcham Test"]);
    run_git(
        &source,
        &["config", "user.email", "yeokcham-test@example.invalid"],
    );
    fs::write(source.join("published.txt"), b"published fixture\n").expect("write fixture");
    run_git(&source, &["add", "published.txt"]);
    run_git(&source, &["commit", "-m", "published fixture"]);
    run_git(&source, &["tag", "-a", "v1.0", "-m", "version one"]);
    let source_ids = GitRepository::open(&source)
        .expect("open source")
        .reachable_object_ids()
        .expect("source object IDs");

    let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .args(["init", "--from-git"])
        .arg(&source)
        .arg(&repository)
        .output()
        .expect("import source");
    assert!(
        output.status.success(),
        "import must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .args(["github", "configure"])
        .arg(&repository)
        .args([
            "--repository",
            "yeokcham/example",
            "--direction",
            "publish-only",
            "--publish",
            "heads",
            "--publish",
            "tags",
        ])
        .output()
        .expect("configure GitHub mirror");
    assert!(
        output.status.success(),
        "configuration must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .args(["github", "plan", "--show-objects"])
        .arg(&repository)
        .output()
        .expect("preview GitHub publication");
    assert!(
        output.status.success(),
        "publication preview must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8(output.stdout).expect("publication output is UTF-8");
    assert!(stdout.contains(&format!(
        "github_publication_plan references=2 objects={}",
        source_ids.len()
    )));
    assert!(stdout.contains("github_publication_reference local=refs/heads/main"));
    assert!(stdout.contains("github_publication_reference local=refs/tags/v1.0"));
    let planned_object_count = stdout
        .lines()
        .filter(|line| line.starts_with("github_publication_object="))
        .count();
    assert_eq!(planned_object_count, source_ids.len());
    for id in source_ids {
        assert!(
            stdout.contains(&format!("github_publication_object={id}")),
            "preview must report reachable object {id}"
        );
    }
    assert!(!stdout.contains("published fixture"));
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
fn cli_clears_disposable_cache_without_damaging_repository() {
    let directory = TestDirectory::new();
    let repository = directory.path().join("repository");
    let repository = LocalRepository::create(&repository).expect("create repository");
    let cache_entry = repository.path().join("cache/packs/stale/entry");
    fs::create_dir_all(cache_entry.parent().expect("cache entry parent")).expect("create cache");
    fs::write(&cache_entry, b"disposable cache").expect("write cache entry");

    for _ in 0..2 {
        let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
            .args(["cache", "clear"])
            .arg(repository.path())
            .output()
            .expect("clear cache");
        assert!(
            output.status.success(),
            "cache clear must succeed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(output.stdout, b"cache_cleared\n");
        assert!(!repository.path().join("cache").exists());
    }

    let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .arg("verify")
        .arg(repository.path())
        .output()
        .expect("verify after cache clear");
    assert!(
        output.status.success(),
        "cache deletion must not damage canonical storage: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[cfg(unix)]
#[test]
fn cli_refuses_a_symlinked_cache_path() {
    use std::os::unix::fs::symlink;

    let directory = TestDirectory::new();
    let repository = directory.path().join("repository");
    let repository = LocalRepository::create(&repository).expect("create repository");
    let target = directory.path().join("outside-cache");
    fs::create_dir(&target).expect("create outside directory");
    let sentinel = target.join("sentinel");
    fs::write(&sentinel, b"preserve").expect("write sentinel");
    symlink(&target, repository.path().join("cache")).expect("symlink cache");

    let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .args(["cache", "clear"])
        .arg(repository.path())
        .output()
        .expect("clear symlinked cache");
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("error[corrupt_data]"));
    assert_eq!(fs::read(sentinel).expect("read sentinel"), b"preserve");
}

#[test]
fn remote_helper_serves_blob_none_and_size_filtered_promisor_clones() {
    let directory = TestDirectory::new();
    let source = directory.path().join("source");
    let repository = directory.path().join("repository");
    fs::create_dir(&source).expect("create source repository");
    run_git(&source, &["init", "-b", "main"]);
    run_git(&source, &["config", "user.name", "Yeokcham Test"]);
    run_git(
        &source,
        &["config", "user.email", "yeokcham-test@example.invalid"],
    );
    fs::create_dir(source.join("history")).expect("create history directory");
    fs::write(source.join("history/historical.bin"), vec![0x48; 64 * 1024])
        .expect("write historical blob");
    run_git(&source, &["add", "history/historical.bin"]);
    run_git(&source, &["commit", "-m", "historical blob fixture"]);
    let historical_blob = String::from_utf8(run_git(
        &source,
        &["rev-parse", "HEAD:history/historical.bin"],
    ))
    .expect("historical blob ID is UTF-8")
    .trim()
    .to_owned();
    fs::remove_file(source.join("history/historical.bin")).expect("remove historical blob");
    fs::create_dir(source.join("assets")).expect("create assets directory");
    fs::create_dir(source.join("app")).expect("create app directory");
    fs::write(source.join("assets/large.bin"), vec![0x4b; 64 * 1024]).expect("write large blob");
    fs::write(source.join("app/selected.txt"), b"selected sparse path\n")
        .expect("write selected sparse path");
    run_git(&source, &["add", "-A"]);
    run_git(&source, &["commit", "-m", "partial clone fixture"]);
    let current_blob = String::from_utf8(run_git(&source, &["rev-parse", "HEAD:assets/large.bin"]))
        .expect("current blob ID is UTF-8")
        .trim()
        .to_owned();
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
    let historical_missing = format!("?{historical_blob}");
    let current_missing = format!("?{current_blob}");
    for (filter, name) in [("blob:none", "blob-none"), ("blob:limit=1", "blob-limit")] {
        let checkout = directory.path().join(name);
        let output = Command::new("git")
            .args(["clone", "--quiet", "--no-checkout", "--filter"])
            .arg(filter)
            .arg(&remote)
            .arg(&checkout)
            .env("PATH", &helper_path)
            .output()
            .expect("clone filtered remote helper");
        assert!(
            output.status.success(),
            "filtered clone must succeed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(
            run_git(&checkout, &["config", "--get", "remote.origin.promisor"]),
            b"true\n"
        );
        assert_eq!(
            run_git(
                &checkout,
                &["config", "--get", "remote.origin.partialclonefilter"],
            ),
            format!("{filter}\n").into_bytes(),
        );
        let missing = run_git(
            &checkout,
            &["rev-list", "--objects", "--missing=print", "HEAD"],
        );
        assert!(
            String::from_utf8_lossy(&missing)
                .lines()
                .any(|line| line.starts_with('?')),
            "filtered clone must retain at least one promisor object",
        );
        assert!(
            String::from_utf8_lossy(&missing)
                .lines()
                .any(|line| line == historical_missing),
            "filtered clone must not download an unrelated historical blob",
        );
        let output = Command::new("git")
            .arg("-C")
            .arg(&checkout)
            .args(["checkout", "--quiet", "main"])
            .env("PATH", &helper_path)
            .output()
            .expect("lazy checkout");
        assert!(
            output.status.success(),
            "lazy checkout must succeed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(
            fs::read(source.join("assets/large.bin")).expect("read source"),
            fs::read(checkout.join("assets/large.bin")).expect("read checkout")
        );
        assert!(
            String::from_utf8_lossy(&run_git(
                &checkout,
                &["rev-list", "--objects", "--missing=print", "HEAD"],
            ))
            .lines()
            .any(|line| line == historical_missing),
            "hydration must not download an unrelated historical blob",
        );
        run_git(&checkout, &["fsck", "--full", "--strict"]);
    }

    let sparse_checkout = directory.path().join("sparse-checkout");
    let output = Command::new("git")
        .args(["clone", "--quiet", "--no-checkout", "--filter=blob:none"])
        .arg(&remote)
        .arg(&sparse_checkout)
        .env("PATH", &helper_path)
        .output()
        .expect("clone sparse remote helper");
    assert!(
        output.status.success(),
        "sparse clone must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    run_git(
        &sparse_checkout,
        &["sparse-checkout", "set", "--cone", "app"],
    );
    let output = Command::new("git")
        .arg("-C")
        .arg(&sparse_checkout)
        .args(["checkout", "--quiet", "main"])
        .env("PATH", &helper_path)
        .output()
        .expect("checkout sparse path");
    assert!(
        output.status.success(),
        "sparse checkout must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        fs::read(source.join("app/selected.txt")).expect("read source sparse path"),
        fs::read(sparse_checkout.join("app/selected.txt")).expect("read checkout sparse path")
    );
    assert!(!sparse_checkout.join("assets/large.bin").exists());
    assert!(
        String::from_utf8_lossy(&run_git(
            &sparse_checkout,
            &["rev-list", "--objects", "--missing=print", "HEAD"],
        ))
        .lines()
        .any(|line| line == current_missing),
        "sparse checkout must not hydrate an excluded current blob",
    );
    run_git(&sparse_checkout, &["fsck", "--full", "--strict"]);
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

    let cached_repository = pack_cache_entry(&repository);
    run_git_bare(&cached_repository, &["fsck", "--full", "--strict"]);
    let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .args(["cache", "inspect"])
        .arg(&repository)
        .output()
        .expect("inspect pack cache");
    assert!(
        output.status.success(),
        "cache inspection must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let cache_statistics = String::from_utf8(output.stdout).expect("cache statistics are UTF-8");
    assert!(cache_statistics.contains("pack_cache_entries=1"));
    assert!(cache_statistics.contains("pack_cache_files="));
    let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .args(["cache", "verify"])
        .arg(&repository)
        .output()
        .expect("verify pack cache");
    assert!(
        output.status.success(),
        "cache verification must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(String::from_utf8_lossy(&output.stdout).contains("verified_pack_cache_entries=1"));
    let pack_directory = cached_repository.join("objects/pack");
    let cache_index = fs::read_dir(&pack_directory)
        .expect("read cached pack directory")
        .map(|entry| entry.expect("read cached pack entry").path())
        .find(|path| path.extension().is_some_and(|extension| extension == "idx"))
        .expect("cached repository must contain one pack index");
    let original_index = fs::read(&cache_index).expect("read cached pack index");

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
    assert_eq!(
        fs::read(&cache_index).expect("read cache index after cache hit"),
        original_index,
        "an unchanged ref state must reuse its validated pack cache",
    );

    make_cache_file_writable(&cache_index);
    fs::write(&cache_index, b"corrupt cache index").expect("corrupt disposable cache");
    let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .args(["cache", "verify"])
        .arg(&repository)
        .output()
        .expect("verify corrupt pack cache");
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("error[corrupt_data]"));
    let output = Command::new("git")
        .arg("-C")
        .arg(&checkout)
        .args(["fetch", "--quiet", "origin"])
        .env("PATH", &helper_path)
        .output()
        .expect("fetch after cache corruption");
    assert!(
        output.status.success(),
        "fetch must rebuild a corrupt disposable cache: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_ne!(
        fs::read(&cache_index).expect("read rebuilt cache index"),
        b"corrupt cache index",
        "a cache index must be regenerated before use",
    );
    run_git_bare(&cached_repository, &["fsck", "--full", "--strict"]);

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
    let cache_entries = pack_cache_entries(&repository);
    assert_eq!(
        cache_entries.len(),
        2,
        "an updated ref state must use a distinct cache entry",
    );
    let updated_cache = cache_entries
        .iter()
        .find(|entry| *entry != &cached_repository)
        .expect("updated cache entry");
    run_git_bare(updated_cache, &["fsck", "--full", "--strict"]);
    let maximum_bytes = directory_byte_count(updated_cache);
    let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .args(["cache", "trim", "--max-bytes"])
        .arg(maximum_bytes.to_string())
        .arg(&repository)
        .output()
        .expect("trim pack cache");
    assert!(
        output.status.success(),
        "cache trimming must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(String::from_utf8_lossy(&output.stdout).contains("trimmed_pack_cache_entries=1"));
    assert!(
        !cached_repository.exists(),
        "least-recently-used cache must be removed"
    );
    assert!(updated_cache.exists(), "most-recent cache must remain");
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

#[test]
fn remote_helper_pushes_only_verified_durable_ref_transitions() {
    let directory = TestDirectory::new();
    let source = directory.path().join("source");
    let repository = directory.path().join("repository");
    let first_client = directory.path().join("first-client");
    let second_client = directory.path().join("second-client");
    let verification_clone = directory.path().join("verification-clone");
    fs::create_dir(&source).expect("create source repository");
    run_git(&source, &["init", "-b", "main"]);
    run_git(&source, &["config", "user.name", "Yeokcham Test"]);
    run_git(
        &source,
        &["config", "user.email", "yeokcham-test@example.invalid"],
    );
    fs::write(source.join("README.md"), b"initial\n").expect("write initial fixture");
    run_git(&source, &["add", "README.md"]);
    run_git(&source, &["commit", "-m", "initial"]);
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
    for client in [&first_client, &second_client] {
        let output = Command::new("git")
            .args(["clone", "--quiet", &remote])
            .arg(client)
            .env("PATH", &helper_path)
            .output()
            .expect("clone Yeokcham remote");
        assert!(
            output.status.success(),
            "clone must succeed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        run_git(client, &["config", "user.name", "Yeokcham Test"]);
        run_git(
            client,
            &["config", "user.email", "yeokcham-test@example.invalid"],
        );
    }

    fs::write(first_client.join("README.md"), b"accepted main update\n")
        .expect("update first client");
    run_git(&first_client, &["add", "README.md"]);
    run_git(&first_client, &["commit", "-m", "accepted main update"]);
    let initial_remote_main = run_git(&first_client, &["rev-parse", "refs/remotes/origin/main"]);
    let initial_remote_main = std::str::from_utf8(&initial_remote_main)
        .expect("initial remote main is UTF-8")
        .trim();
    let accepted_main = run_git(&first_client, &["rev-parse", "HEAD"]);
    let output = Command::new("git")
        .arg("-C")
        .arg(&first_client)
        .args(["push", "origin", "main"])
        .env("PATH", &helper_path)
        .output()
        .expect("push fast-forward main");
    assert!(
        output.status.success(),
        "fast-forward push must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    run_git(
        &first_client,
        &[
            "update-ref",
            "refs/remotes/origin/main",
            initial_remote_main,
        ],
    );
    let output = Command::new("git")
        .arg("-C")
        .arg(&first_client)
        .args(["push", "origin", "main"])
        .env("PATH", &helper_path)
        .output()
        .expect("retry accepted main push after a lost response");
    assert!(
        output.status.success(),
        "retry must converge after ref rediscovery: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .args(["inspect", "refs"])
        .arg(&repository)
        .output()
        .expect("inspect retry journal");
    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout).contains("events=1"));

    run_git(&first_client, &["switch", "-c", "topic"]);
    fs::write(first_client.join("topic.txt"), b"topic\n").expect("write topic fixture");
    run_git(&first_client, &["add", "topic.txt"]);
    run_git(&first_client, &["commit", "-m", "topic"]);
    let output = Command::new("git")
        .arg("-C")
        .arg(&first_client)
        .args(["push", "--set-upstream", "origin", "topic"])
        .env("PATH", &helper_path)
        .output()
        .expect("create topic branch");
    assert!(
        output.status.success(),
        "branch creation must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let output = Command::new("git")
        .arg("-C")
        .arg(&first_client)
        .args(["push", "origin", "--delete", "topic"])
        .env("PATH", &helper_path)
        .output()
        .expect("delete topic branch");
    assert!(
        output.status.success(),
        "branch deletion must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    run_git(&first_client, &["switch", "main"]);
    run_git(&first_client, &["tag", "-a", "v1", "-m", "version one"]);
    let output = Command::new("git")
        .arg("-C")
        .arg(&first_client)
        .args(["push", "origin", "v1"])
        .env("PATH", &helper_path)
        .output()
        .expect("create immutable tag");
    assert!(
        output.status.success(),
        "tag creation must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    run_git(&first_client, &["tag", "-f", "v1", "HEAD"]);
    let output = Command::new("git")
        .arg("-C")
        .arg(&first_client)
        .args(["push", "--force", "origin", "v1"])
        .env("PATH", &helper_path)
        .output()
        .expect("attempt tag replacement");
    assert!(
        !output.status.success(),
        "immutable tag replacement must fail: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let output = Command::new("git")
        .arg("-C")
        .arg(&second_client)
        .args(["fetch", "--quiet", "origin"])
        .env("PATH", &helper_path)
        .output()
        .expect("refresh second client remote tracking refs");
    assert!(
        output.status.success(),
        "fetch must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    fs::write(second_client.join("README.md"), b"divergent update\n")
        .expect("write divergent update");
    run_git(&second_client, &["add", "README.md"]);
    run_git(&second_client, &["commit", "-m", "divergent update"]);
    let output = Command::new("git")
        .arg("-C")
        .arg(&second_client)
        .args(["push", "--force", "origin", "HEAD:main"])
        .env("PATH", &helper_path)
        .output()
        .expect("attempt non-fast-forward branch replacement");
    assert!(
        !output.status.success(),
        "forced branch replacement must fail: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let output = Command::new("git")
        .args(["clone", "--quiet", &remote])
        .arg(&verification_clone)
        .env("PATH", &helper_path)
        .output()
        .expect("clone verified pushed state");
    assert!(
        output.status.success(),
        "verification clone must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        run_git(&verification_clone, &["rev-parse", "HEAD"]),
        accepted_main,
        "rejected branch replacement must not alter the canonical ref",
    );
    assert_eq!(
        fs::read(verification_clone.join("README.md")).expect("read verified clone"),
        b"accepted main update\n",
    );
    run_git(&verification_clone, &["fsck", "--full", "--strict"]);
    let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .arg("verify")
        .arg(&repository)
        .output()
        .expect("verify pushed Yeokcham repository");
    assert!(
        output.status.success(),
        "canonical verification must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .args(["inspect", "refs"])
        .arg(&repository)
        .output()
        .expect("inspect push journal");
    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout).contains("events=4"));
}
