use base::platform::windows::is_windows_version_or_greater;

// Sense Remote: this mode no longer uses RustDesk's injected topmost window
// (`win_topmost_window`, an external WindowInjection.dll that the Sense build does not ship).
// The Sense maintenance curtain (`crate::sense::curtain`) covers every physical screen with its
// own windows, excluded from capture, and keeps the Sense icon above it (wave 3 I10).
pub use self::sense::PrivacyModeImpl;

pub(super) const PRIVACY_MODE_IMPL: &str = super::PRIVACY_MODE_IMPL_WIN_EXCLUDE_FROM_CAPTURE;

pub(super) fn is_supported() -> bool {
    // https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowdisplayaffinity
    // https://en.wikipedia.org/wiki/Windows_10_version_history
    is_windows_version_or_greater(10, 0, 19041, 0, 0)
}

mod sense {
    use super::super::{PrivacyMode, PrivacyModeState, INVALID_PRIVACY_MODE_CONN_ID};
    use crate::sense::curtain;
    use hbb_common::{allow_err, log, ResultType};

    /// Sense Remote: privacy mode = maintenance curtain + local input blocked (as in RustDesk's
    /// mode 1; Ctrl+P on the computer itself still turns it off, see `win_input`).
    pub struct PrivacyModeImpl {
        impl_key: String,
        conn_id: i32,
    }

    impl PrivacyModeImpl {
        pub fn new(impl_key: &str) -> Self {
            Self {
                impl_key: impl_key.to_owned(),
                conn_id: INVALID_PRIVACY_MODE_CONN_ID,
            }
        }
    }

    impl PrivacyMode for PrivacyModeImpl {
        fn is_async_privacy_mode(&self) -> bool {
            false
        }

        fn init(&self) -> ResultType<()> {
            Ok(())
        }

        fn clear(&mut self) {
            allow_err!(self.turn_off_privacy(self.conn_id, None));
        }

        fn turn_on_privacy(&mut self, conn_id: i32) -> ResultType<bool> {
            if self.check_on_conn_id(conn_id)? {
                log::debug!("Privacy mode of conn {} is already on", conn_id);
                return Ok(true);
            }
            curtain::show()?;
            if let Err(e) = super::super::win_input::hook() {
                curtain::hide();
                return Err(e);
            }
            self.conn_id = conn_id;
            Ok(true)
        }

        fn turn_off_privacy(
            &mut self,
            conn_id: i32,
            state: Option<PrivacyModeState>,
        ) -> ResultType<()> {
            self.check_off_conn_id(conn_id)?;
            let unhook = super::super::win_input::unhook();
            curtain::hide();
            if self.conn_id != INVALID_PRIVACY_MODE_CONN_ID {
                if let Some(state) = state {
                    allow_err!(super::super::set_privacy_mode_state(
                        conn_id,
                        state,
                        super::PRIVACY_MODE_IMPL.to_string(),
                        1_000
                    ));
                }
                self.conn_id = INVALID_PRIVACY_MODE_CONN_ID;
            }
            unhook
        }

        #[inline]
        fn pre_conn_id(&self) -> i32 {
            self.conn_id
        }

        #[inline]
        fn get_impl_key(&self) -> &str {
            &self.impl_key
        }
    }

    impl Drop for PrivacyModeImpl {
        fn drop(&mut self) {
            if self.conn_id != INVALID_PRIVACY_MODE_CONN_ID {
                allow_err!(self.turn_off_privacy(self.conn_id, None));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    // Sense Remote (I10): Windows offers only the curtain mode, never the black-screen ones.
    #[test]
    fn sense_offers_only_the_curtain() {
        let impls = super::super::get_supported_privacy_mode_impl();
        assert!(impls.len() <= 1, "{:?}", impls);
        assert!(impls.iter().all(|(k, _)| *k == super::PRIVACY_MODE_IMPL));
        let default = super::super::DEFAULT_PRIVACY_MODE_IMPL.as_str();
        assert!(default.is_empty() || default == super::PRIVACY_MODE_IMPL);
        assert_eq!(super::is_supported(), !impls.is_empty());
    }
}
