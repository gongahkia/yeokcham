use std::{env, ffi::OsString, net::SocketAddr, path::PathBuf, process::ExitCode};

use yeokcham_core::{Error, ErrorKind, LocalRepository, Result};
use yeokcham_server::Server;

const USAGE: &str =
    "usage: yeokcham-server --repository <yeokcham-repo> [--bind <loopback-address>]";

struct Options {
    repository: PathBuf,
    bind: SocketAddr,
}

fn main() -> ExitCode {
    match parse_options(env::args_os().skip(1).collect()).and_then(|options| {
        let repository = LocalRepository::open(options.repository)?;
        let server = Server::bind(repository, options.bind)?;
        println!("listening=http://{}", server.local_addr()?);
        server.serve()
    }) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("error[{}]: {error}", error.code());
            ExitCode::FAILURE
        }
    }
}

fn parse_options(arguments: Vec<OsString>) -> Result<Options> {
    let mut repository = None;
    let mut bind = None;
    let mut arguments = arguments.into_iter();
    while let Some(argument) = arguments.next() {
        match argument.to_str() {
            Some("--repository") if repository.is_none() => {
                repository = Some(PathBuf::from(arguments.next().ok_or_else(usage_error)?));
            }
            Some("--bind") if bind.is_none() => {
                let value = arguments.next().ok_or_else(usage_error)?;
                bind = Some(
                    value
                        .to_str()
                        .ok_or_else(usage_error)?
                        .parse()
                        .map_err(|_| {
                            Error::new(
                                ErrorKind::InvalidInput,
                                "native HTTP bind address is invalid",
                            )
                        })?,
                );
            }
            _ => return Err(usage_error()),
        }
    }
    Ok(Options {
        repository: repository.ok_or_else(usage_error)?,
        bind: bind.unwrap_or(SocketAddr::from(([127, 0, 0, 1], 0))),
    })
}

fn usage_error() -> Error {
    Error::new(ErrorKind::InvalidInput, USAGE)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_to_an_ephemeral_ipv4_loopback_bind() {
        let options = parse_options(vec![
            OsString::from("--repository"),
            OsString::from("store"),
        ])
        .expect("parse options");
        assert_eq!(options.repository, PathBuf::from("store"));
        assert_eq!(options.bind, "127.0.0.1:0".parse().expect("address"));
    }

    #[test]
    fn rejects_invalid_or_duplicate_options() {
        for arguments in [
            vec![OsString::from("--repository")],
            vec![
                OsString::from("--bind"),
                OsString::from("localhost:1"),
                OsString::from("--repository"),
                OsString::from("store"),
            ],
            vec![
                OsString::from("--repository"),
                OsString::from("one"),
                OsString::from("--repository"),
                OsString::from("two"),
            ],
            vec![
                OsString::from("--repository"),
                OsString::from("store"),
                OsString::from("--bind"),
                OsString::from("127.0.0.1:0"),
                OsString::from("--bind"),
                OsString::from("127.0.0.1:1"),
            ],
        ] {
            assert!(parse_options(arguments).is_err());
        }
    }
}
