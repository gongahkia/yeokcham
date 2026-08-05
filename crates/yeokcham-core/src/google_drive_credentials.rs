use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

use crate::{
    DriveAccessToken, DriveOAuthConfiguration, DriveOAuthToken, DriveOAuthTransport, Error,
    ErrorKind, Result,
};

const CREDENTIAL_SERVICE: &str = "io.github.yeokcham.google-drive";
const MAXIMUM_REFRESH_TOKEN_BYTES: usize = 16 * 1024;

/// One refresh token loaded from an operating-system credential store.
pub struct DriveStoredCredential {
    refresh_token: Zeroizing<String>,
}

impl DriveStoredCredential {
    /// Returns the refresh token for an immediate Google token-refresh request only.
    pub fn refresh_token(&self) -> &str {
        &self.refresh_token
    }

    /// Exchanges this stored refresh token for one new in-memory bearer access token.
    pub fn refresh_access_token<T: DriveOAuthTransport>(
        &self,
        configuration: &DriveOAuthConfiguration,
        transport: &T,
    ) -> Result<DriveAccessToken> {
        configuration.refresh_access_token(&self.refresh_token, transport)
    }
}

impl std::fmt::Debug for DriveStoredCredential {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("DriveStoredCredential(<redacted>)")
    }
}

/// OS credential persistence for one configured Google Desktop OAuth client.
pub trait DriveCredentialStore: Send + Sync {
    /// Replaces the configured client's persisted refresh token.
    fn store(&self, configuration: &DriveOAuthConfiguration, token: &DriveOAuthToken)
    -> Result<()>;

    /// Loads the configured client's persisted refresh token.
    fn load(&self, configuration: &DriveOAuthConfiguration) -> Result<DriveStoredCredential>;

    /// Deletes the configured client's persisted refresh token if it exists.
    fn delete(&self, configuration: &DriveOAuthConfiguration) -> Result<()>;
}

/// The platform-native Keychain/keyring credential-store implementation.
#[derive(Clone, Copy, Debug, Default)]
pub struct KeyringDriveCredentialStore;

impl DriveCredentialStore for KeyringDriveCredentialStore {
    fn store(
        &self,
        configuration: &DriveOAuthConfiguration,
        token: &DriveOAuthToken,
    ) -> Result<()> {
        validate_refresh_token(token.refresh_token())?;
        entry(configuration)?
            .set_password(token.refresh_token())
            .map_err(|error| {
                Error::with_source(
                    ErrorKind::Io,
                    "Drive credentials could not be persisted",
                    error,
                )
            })
    }

    fn load(&self, configuration: &DriveOAuthConfiguration) -> Result<DriveStoredCredential> {
        let token = match entry(configuration)?.get_password() {
            Ok(token) => token,
            Err(keyring::Error::NoEntry) => {
                return Err(Error::new(
                    ErrorKind::NotFound,
                    "Drive credentials do not exist",
                ));
            }
            Err(error) => {
                return Err(Error::with_source(
                    ErrorKind::Io,
                    "Drive credentials could not be loaded",
                    error,
                ));
            }
        };
        validate_refresh_token(&token)?;
        Ok(DriveStoredCredential {
            refresh_token: Zeroizing::new(token),
        })
    }

    fn delete(&self, configuration: &DriveOAuthConfiguration) -> Result<()> {
        match entry(configuration)?.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(error) => Err(Error::with_source(
                ErrorKind::Io,
                "Drive credentials could not be deleted",
                error,
            )),
        }
    }
}

fn entry(configuration: &DriveOAuthConfiguration) -> Result<keyring::Entry> {
    let account = hex::encode(Sha256::digest(configuration.client_id().as_bytes()));
    keyring::Entry::new(CREDENTIAL_SERVICE, &account).map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "Drive credential store could not be initialized",
            error,
        )
    })
}

fn validate_refresh_token(token: &str) -> Result<()> {
    if token.is_empty()
        || token.len() > MAXIMUM_REFRESH_TOKEN_BYTES
        || !token.bytes().all(|byte| !byte.is_ascii_control())
    {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "stored Drive refresh token is invalid",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::{collections::BTreeMap, sync::Mutex};

    use super::*;
    use crate::DriveOAuthHttpResponse;

    #[derive(Default)]
    struct MemoryCredentialStore {
        credentials: Mutex<BTreeMap<String, String>>,
    }

    struct RefreshTransport {
        form: Mutex<BTreeMap<String, String>>,
    }

    impl DriveOAuthTransport for RefreshTransport {
        fn post_form(
            &self,
            _endpoint: &str,
            form: &[(&str, &str)],
        ) -> Result<DriveOAuthHttpResponse> {
            self.form.lock().expect("form mutex").extend(
                form.iter()
                    .map(|(name, value)| ((*name).to_owned(), (*value).to_owned())),
            );
            DriveOAuthHttpResponse::new(
                200,
                br#"{"access_token":"refreshed-access-token","token_type":"Bearer","expires_in":3600}"#.to_vec(),
            )
        }
    }

    impl DriveCredentialStore for MemoryCredentialStore {
        fn store(
            &self,
            configuration: &DriveOAuthConfiguration,
            token: &DriveOAuthToken,
        ) -> Result<()> {
            self.credentials.lock().expect("credential mutex").insert(
                configuration.client_id().to_owned(),
                token.refresh_token().to_owned(),
            );
            Ok(())
        }

        fn load(&self, configuration: &DriveOAuthConfiguration) -> Result<DriveStoredCredential> {
            self.credentials
                .lock()
                .expect("credential mutex")
                .get(configuration.client_id())
                .cloned()
                .map(|refresh_token| DriveStoredCredential {
                    refresh_token: Zeroizing::new(refresh_token),
                })
                .ok_or_else(|| Error::new(ErrorKind::NotFound, "Drive credentials do not exist"))
        }

        fn delete(&self, configuration: &DriveOAuthConfiguration) -> Result<()> {
            self.credentials
                .lock()
                .expect("credential mutex")
                .remove(configuration.client_id());
            Ok(())
        }
    }

    fn configuration() -> DriveOAuthConfiguration {
        DriveOAuthConfiguration::new("123.apps.googleusercontent.com").expect("configuration")
    }

    fn token() -> DriveOAuthToken {
        DriveOAuthToken::test_token("access-token", "refresh-token")
    }

    #[test]
    fn persists_loads_and_deletes_refresh_tokens_through_the_store_seam() {
        let store = MemoryCredentialStore::default();
        let configuration = configuration();
        store.store(&configuration, &token()).expect("store token");

        let credential = store.load(&configuration).expect("load token");
        assert_eq!(credential.refresh_token(), "refresh-token");
        assert_eq!(
            format!("{credential:?}"),
            "DriveStoredCredential(<redacted>)"
        );
        store.delete(&configuration).expect("delete token");
        assert_eq!(
            store
                .load(&configuration)
                .expect_err("deleted token")
                .kind(),
            ErrorKind::NotFound
        );
    }

    #[test]
    fn refreshes_a_loaded_credential_without_persisting_an_access_token() {
        let store = MemoryCredentialStore::default();
        let configuration = configuration();
        store.store(&configuration, &token()).expect("store token");
        let credential = store.load(&configuration).expect("load token");
        let transport = RefreshTransport {
            form: Mutex::new(BTreeMap::new()),
        };

        let access_token = credential
            .refresh_access_token(&configuration, &transport)
            .expect("refresh access token");
        assert_eq!(access_token.access_token(), "refreshed-access-token");
        assert_eq!(
            transport
                .form
                .lock()
                .expect("form mutex")
                .get("refresh_token"),
            Some(&"refresh-token".to_owned())
        );
        assert_eq!(
            store
                .load(&configuration)
                .expect("stored token")
                .refresh_token(),
            "refresh-token"
        );
    }
}
