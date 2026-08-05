use std::{env, ffi::OsString, net::SocketAddr, path::PathBuf, process::ExitCode};

use yeokcham_core::{Error, ErrorKind, LocalRepository, Result};
use yeokcham_server::{AuthenticationToken, Server, create_authentication_token_file};

const USAGE: &str = "usage:\n  yeokcham-server --repository <yeokcham-repo> --auth-token-file <private-token-file> [--bind <loopback-address>]\n  yeokcham-server token create <private-token-file>";

struct Options {
    repository: PathBuf,
    authentication_token_file: PathBuf,
    bind: SocketAddr,
}

enum Command {
    Serve(Options),
    CreateToken(PathBuf),
}

fn main() -> ExitCode {
    match parse_command(env::args_os().skip(1).collect()).and_then(|command| match command {
        Command::Serve(options) => {
            let repository = LocalRepository::open(options.repository)?;
            let authentication = AuthenticationToken::load(options.authentication_token_file)?;
            let server = Server::bind(repository, options.bind, authentication)?;
            println!("listening=http://{}", server.local_addr()?);
            server.serve()
        }
        Command::CreateToken(path) => {
            create_authentication_token_file(path)?;
            println!("authentication token file created");
            Ok(())
        }
    }) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("error[{}]: {error}", error.code());
            ExitCode::FAILURE
        }
    }
}

fn parse_command(arguments: Vec<OsString>) -> Result<Command> {
    if arguments.len() == 3
        && arguments
            .first()
            .is_some_and(|argument| argument == "token")
        && arguments
            .get(1)
            .is_some_and(|argument| argument == "create")
    {
        return Ok(Command::CreateToken(PathBuf::from(&arguments[2])));
    }
    parse_options(arguments).map(Command::Serve)
}

fn parse_options(arguments: Vec<OsString>) -> Result<Options> {
    let mut repository = None;
    let mut authentication_token_file = None;
    let mut bind = None;
    let mut arguments = arguments.into_iter();
    while let Some(argument) = arguments.next() {
        match argument.to_str() {
            Some("--repository") if repository.is_none() => {
                repository = Some(PathBuf::from(arguments.next().ok_or_else(usage_error)?));
            }
            Some("--auth-token-file") if authentication_token_file.is_none() => {
                authentication_token_file =
                    Some(PathBuf::from(arguments.next().ok_or_else(usage_error)?));
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
        authentication_token_file: authentication_token_file.ok_or_else(usage_error)?,
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
            OsString::from("--auth-token-file"),
            OsString::from("token"),
        ])
        .expect("parse options");
        assert_eq!(options.repository, PathBuf::from("store"));
        assert_eq!(options.authentication_token_file, PathBuf::from("token"));
        assert_eq!(options.bind, "127.0.0.1:0".parse().expect("address"));
    }

    #[test]
    fn rejects_invalid_or_duplicate_options() {
        for arguments in [
            vec![OsString::from("--repository")],
            vec![OsString::from("--repository"), OsString::from("store")],
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
                OsString::from("--auth-token-file"),
                OsString::from("token"),
                OsString::from("--bind"),
                OsString::from("127.0.0.1:0"),
                OsString::from("--bind"),
                OsString::from("127.0.0.1:1"),
            ],
        ] {
            assert!(parse_options(arguments).is_err());
        }
    }

    #[test]
    fn parses_exact_token_creation_command() {
        let command = parse_command(vec![
            OsString::from("token"),
            OsString::from("create"),
            OsString::from("token"),
        ])
        .expect("parse command");
        assert!(matches!(command, Command::CreateToken(path) if path == PathBuf::from("token")));
        assert!(parse_command(vec![OsString::from("token")]).is_err());
    }
}
