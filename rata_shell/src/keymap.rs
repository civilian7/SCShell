//! Map Win32 virtual-key + modifiers to xterm input sequences.

pub const MOD_SHIFT: u32 = 0x01;
pub const MOD_CTRL: u32 = 0x02;
pub const MOD_ALT: u32 = 0x04;
pub const MOD_WIN: u32 = 0x08;

// Selected Win32 VK constants we care about (avoid pulling all of windows-rs).
const VK_BACK: u32 = 0x08;
const VK_TAB: u32 = 0x09;
const VK_RETURN: u32 = 0x0D;
const VK_ESCAPE: u32 = 0x1B;
const VK_PRIOR: u32 = 0x21;
const VK_NEXT: u32 = 0x22;
const VK_END: u32 = 0x23;
const VK_HOME: u32 = 0x24;
const VK_LEFT: u32 = 0x25;
const VK_UP: u32 = 0x26;
const VK_RIGHT: u32 = 0x27;
const VK_DOWN: u32 = 0x28;
const VK_INSERT: u32 = 0x2D;
const VK_DELETE: u32 = 0x2E;
const VK_F1: u32 = 0x70;
const VK_F12: u32 = 0x7B;

fn modparam(mods: u32) -> u8 {
    let s = (mods & MOD_SHIFT != 0) as u8;
    let a = (mods & MOD_ALT != 0) as u8;
    let c = (mods & MOD_CTRL != 0) as u8;
    1 + s + (a << 1) + (c << 2)
}

/// Convert a VK + modifier mask to the byte sequence to write to the PTY input.
/// `app_cursor_keys` selects between normal (`ESC[A`) and application
/// (`ESC O A`) cursor key modes — TUIs that issue `DECCKM` need the latter.
pub fn encode(vk: u32, mods: u32, app_cursor_keys: bool) -> Vec<u8> {
    let mp = modparam(mods);
    let with_mods = mp != 1;

    let csi_arrow = |letter: u8| -> Vec<u8> {
        if with_mods {
            format!("\x1b[1;{}{}", mp, letter as char).into_bytes()
        } else if app_cursor_keys {
            vec![0x1b, b'O', letter]
        } else {
            vec![0x1b, b'[', letter]
        }
    };

    let csi_tilde = |code: u32| -> Vec<u8> {
        if with_mods {
            format!("\x1b[{};{}~", code, mp).into_bytes()
        } else {
            format!("\x1b[{}~", code).into_bytes()
        }
    };

    match vk {
        VK_BACK => {
            if mods & MOD_ALT != 0 {
                vec![0x1b, 0x7f]
            } else {
                vec![0x7f]
            }
        }
        VK_TAB => {
            if mods & MOD_SHIFT != 0 {
                vec![0x1b, b'[', b'Z']
            } else {
                vec![b'\t']
            }
        }
        VK_RETURN => vec![b'\r'],
        VK_ESCAPE => vec![0x1b],
        VK_UP => csi_arrow(b'A'),
        VK_DOWN => csi_arrow(b'B'),
        VK_RIGHT => csi_arrow(b'C'),
        VK_LEFT => csi_arrow(b'D'),
        VK_HOME => csi_arrow(b'H'),
        VK_END => csi_arrow(b'F'),
        VK_INSERT => csi_tilde(2),
        VK_DELETE => csi_tilde(3),
        VK_PRIOR => csi_tilde(5),
        VK_NEXT => csi_tilde(6),
        VK_F1 => f_key(11, with_mods, mp),
        v if v >= VK_F1 && v <= VK_F12 => {
            let codes = [11, 12, 13, 14, 15, 17, 18, 19, 20, 21, 23, 24];
            f_key(codes[(v - VK_F1) as usize], with_mods, mp)
        }
        // Ctrl + letter → control byte
        v if (mods & MOD_CTRL != 0)
            && (b'A' as u32..=b'Z' as u32).contains(&v) =>
        {
            vec![(v - b'A' as u32 + 1) as u8]
        }
        _ => Vec::new(),
    }
}

fn f_key(code: u32, with_mods: bool, mp: u8) -> Vec<u8> {
    if with_mods {
        format!("\x1b[{};{}~", code, mp).into_bytes()
    } else {
        format!("\x1b[{}~", code).into_bytes()
    }
}
