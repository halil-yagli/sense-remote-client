//! Sense Remote: Ctrl+Alt+Shift+1-9 (Mac: Cmd+Option+Shift+1-9) for the favorites list (#71, S12).
//!
//! In the default (rdev) input mode the chord would go to the remote computer as keys. The
//! shortcut matcher asks [`action_for`] first and, when it answers, treats the chord like any
//! other bound shortcut: consumed here, `sense_fav_<n>` pushed to Flutter
//! (`SenseFavoritesHotkeys.handleAction`). Pure functions, so they are unit-tested.

use crate::keyboard::shortcuts::Modifier;

/// Action id prefix; the Flutter side registers `sense_fav_1` .. `sense_fav_9`.
pub const ACTION_PREFIX: &str = "sense_fav_";

/// The slot (1-9) of a digit key, main row or numpad.
pub fn slot_of_key(key: rdev::Key) -> Option<u8> {
    use rdev::Key::*;
    Some(match key {
        Num1 | Kp1 => 1,
        Num2 | Kp2 => 2,
        Num3 | Kp3 => 3,
        Num4 | Kp4 => 4,
        Num5 | Kp5 => 5,
        Num6 | Kp6 => 6,
        Num7 | Kp7 => 7,
        Num8 | Kp8 => 8,
        Num9 | Kp9 => 9,
        _ => return None,
    })
}

/// True for exactly Primary+Alt+Shift (Ctrl on Windows, Cmd on Mac; nothing else held).
pub fn is_chord(mods: &[Modifier]) -> bool {
    mods.len() == 3
        && mods.contains(&Modifier::Primary)
        && mods.contains(&Modifier::Alt)
        && mods.contains(&Modifier::Shift)
}

/// `sense_fav_<n>` when the key and modifiers are the favorites chord.
pub fn action_for(key: rdev::Key, mods: &[Modifier]) -> Option<String> {
    if !is_chord(mods) {
        return None;
    }
    slot_of_key(key).map(|n| format!("{ACTION_PREFIX}{n}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    const CHORD: [Modifier; 3] = [Modifier::Primary, Modifier::Alt, Modifier::Shift];

    #[test]
    fn digits_map_to_slots() {
        assert_eq!(action_for(rdev::Key::Num1, &CHORD).as_deref(), Some("sense_fav_1"));
        assert_eq!(action_for(rdev::Key::Num9, &CHORD).as_deref(), Some("sense_fav_9"));
        assert_eq!(action_for(rdev::Key::Kp5, &CHORD).as_deref(), Some("sense_fav_5"));
        assert_eq!(action_for(rdev::Key::Num0, &CHORD), None);
        assert_eq!(action_for(rdev::Key::KeyA, &CHORD), None);
    }

    #[test]
    fn modifiers_must_match_exactly() {
        let k = rdev::Key::Num3;
        assert_eq!(action_for(k, &[]), None);
        assert_eq!(action_for(k, &[Modifier::Primary, Modifier::Alt]), None);
        assert_eq!(action_for(k, &[Modifier::Alt, Modifier::Shift]), None);
        // Mac: Ctrl on top of Cmd is another chord.
        assert_eq!(
            action_for(k, &[Modifier::Primary, Modifier::Ctrl, Modifier::Alt, Modifier::Shift]),
            None
        );
        assert_eq!(action_for(k, &[Modifier::Ctrl, Modifier::Alt, Modifier::Shift]), None);
        // Order does not matter.
        assert_eq!(
            action_for(k, &[Modifier::Shift, Modifier::Alt, Modifier::Primary]).as_deref(),
            Some("sense_fav_3")
        );
    }
}
