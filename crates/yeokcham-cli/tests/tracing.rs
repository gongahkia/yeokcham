use std::process::Command;

#[test]
fn default_filter_emits_no_debug_output() {
    let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
        .env_remove("YEOKCHAM_LOG")
        .output()
        .expect("run yeokcham");

    assert!(output.status.success());
    assert!(output.stderr.is_empty());
}

#[test]
fn debug_filter_emits_startup_event() {
    let output = Command::new(env!("CARGO_BIN_EXE_yeokcham"))
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
