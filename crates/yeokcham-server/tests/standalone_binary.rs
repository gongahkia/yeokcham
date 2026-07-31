use std::{
    fs,
    io::{Read, Write},
    net::{SocketAddr, TcpListener, TcpStream},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    thread,
    time::Duration,
};

use yeokcham_core::LocalRepository;

struct TestDirectory(PathBuf);

impl TestDirectory {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "yeokcham-server-standalone-{}",
            uuid::Uuid::new_v4()
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

struct ServerProcess(Child);

impl Drop for ServerProcess {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[test]
fn standalone_binary_serves_authenticated_loopback_health() {
    let temporary = TestDirectory::new();
    let repository = temporary.path().join("repository");
    LocalRepository::create(&repository).expect("create repository");
    let token_path = temporary.path().join("token");
    let binary = env!("CARGO_BIN_EXE_yeokcham-server");
    let created = Command::new(binary)
        .args(["token", "create"])
        .arg(&token_path)
        .output()
        .expect("create token process");
    assert!(created.status.success());
    assert_eq!(created.stdout, b"authentication token file created\n");
    let token = fs::read_to_string(&token_path)
        .expect("read token")
        .trim_end_matches('\n')
        .to_owned();
    let address = available_loopback_address();
    let mut server = ServerProcess(
        Command::new(binary)
            .args(["--repository"])
            .arg(&repository)
            .args(["--auth-token-file"])
            .arg(&token_path)
            .args(["--bind", &address.to_string()])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("start standalone server"),
    );

    for _ in 0..100 {
        if let Ok(response) = request_health(address, &token) {
            assert!(response.starts_with(b"HTTP/1.1 200 OK\r\n"));
            assert!(response.ends_with(b"{\"version\":1,\"status\":\"ok\"}"));
            return;
        }
        assert!(server.0.try_wait().expect("check server").is_none());
        thread::sleep(Duration::from_millis(10));
    }
    panic!("standalone server did not serve loopback health");
}

fn available_loopback_address() -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").expect("reserve loopback address");
    listener.local_addr().expect("read loopback address")
}

fn request_health(address: SocketAddr, token: &str) -> std::io::Result<Vec<u8>> {
    let mut stream = TcpStream::connect_timeout(&address, Duration::from_millis(25))?;
    stream.set_read_timeout(Some(Duration::from_millis(100)))?;
    stream.write_all(
        format!(
            "GET /v1/health HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {token}\r\n\r\n"
        )
        .as_bytes(),
    )?;
    let mut response = Vec::new();
    stream.read_to_end(&mut response)?;
    Ok(response)
}
