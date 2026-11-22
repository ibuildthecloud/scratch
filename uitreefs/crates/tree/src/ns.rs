//! The client's namespace (DESIGN § The tree) and the tree's own paths.
//!
//! Inside, the tree keeps the layout it always had: `windows/<w>/root/...`
//! for nodes, `windows/<w>/overlays/...` for overlays, `keymap`, `menus/`,
//! `clipboard`, `drags/`, `assets/`. Clients see shorter names, and a
//! window directory that is also its root node:
//!
//! | client sees              | the tree keeps                     |
//! | ------------------------ | ---------------------------------- |
//! | `win/main/f/emp`         | `windows/main/root/f/emp`          |
//! | `win/main/style`         | `windows/main/root/style`          |
//! | `win/main/title` (and `ctl`, `events`, `bounds`, `state`, `focus`) | `windows/main/title` |
//! | `win/main/over/dlg`      | `windows/main/overlays/dlg`        |
//! | `win/main/@total`        | the one node named `total` in it   |
//! | `keys`, `menu/`, `clip`, `clipfiles`, `drag/`, `asset/` | `keymap`, `menus/`, `clipboard`, `clipboard-files`, `drags/`, `assets/` |
//!
//! Window-relative node paths (in events, `focus`, `anchor=`) drop the
//! `root/`: `f/emp/in`, with `.` for the root itself and `over/x` for an
//! overlay.

use crate::state::{State, WINDOW_FILES};
use proto::{Error, ErrorKind};

/// Root names: (client, tree).
pub const ROOT_NAMES: &[(&str, &str)] = &[
    ("keys", "keymap"),
    ("clip", "clipboard"),
    ("clipfiles", "clipboard-files"),
    ("menu", "menus"),
    ("drag", "drags"),
    ("asset", "assets"),
    ("win", "windows"),
];

/// Names in a window directory that are the window's own, not its root
/// node's, and can't be child names of the root (`ctl`, `events` and
/// `bounds` are node files anyway).
pub const WINDOW_OWN: &[&str] = &["over"];

/// Window files a child of the root may hide (`text title` is common).
pub const SHADOWABLE: &[&str] = &["title", "state", "focus"];

fn root_to_int(n: &str) -> &str {
    ROOT_NAMES
        .iter()
        .find(|(e, _)| *e == n)
        .map(|(_, i)| *i)
        .unwrap_or(n)
}

fn root_to_ext(n: &str) -> &str {
    ROOT_NAMES
        .iter()
        .find(|(_, i)| *i == n)
        .map(|(e, _)| *e)
        .unwrap_or(n)
}

/// A client's window-relative node path to the tree's (`f/emp` ->
/// `root/f/emp`, `.` -> `root`, `over/x` -> `overlays/x`).
pub fn rel_to_int(rel: &str) -> String {
    let rel = rel.trim().trim_matches('/');
    let rel = rel.strip_prefix("./").unwrap_or(rel);
    if rel.is_empty() || rel == "." {
        return "root".into();
    }
    if rel == "over" {
        return "overlays".into();
    }
    if let Some(r) = rel.strip_prefix("over/") {
        return format!("overlays/{r}");
    }
    // Already the tree's own spelling (from the host): leave it.
    if rel == "root" || rel.starts_with("root/") || rel == "overlays" || rel.starts_with("overlays/") {
        return rel.to_string();
    }
    format!("root/{rel}")
}

/// The tree's window-relative path to the client's (`root/f/emp` -> `f/emp`).
pub fn rel_to_ext(rel: &str) -> String {
    if rel == "root" {
        return ".".into();
    }
    if let Some(r) = rel.strip_prefix("root/") {
        return r.to_string();
    }
    if rel == "overlays" {
        return "over".into();
    }
    if let Some(r) = rel.strip_prefix("overlays/") {
        return format!("over/{r}");
    }
    rel.to_string()
}

/// The tree's full path to the client's (`windows/main/root/a/title` ->
/// `win/main/a/title`).
pub fn to_ext(path: &str) -> String {
    let path = path.trim_matches('/');
    if let Some(rest) = path.strip_prefix("windows/") {
        let (w, r) = rest.split_once('/').unwrap_or((rest, ""));
        if r.is_empty() {
            return format!("win/{w}");
        }
        let e = rel_to_ext(r);
        return if e == "." {
            format!("win/{w}")
        } else {
            format!("win/{w}/{e}")
        };
    }
    let (first, rest) = path.split_once('/').unwrap_or((path, ""));
    let first = root_to_ext(first);
    if rest.is_empty() {
        first.to_string()
    } else {
        format!("{first}/{rest}")
    }
}

/// A client path to the tree's, resolving `@name` against `st`. Paths the
/// tree doesn't know come back translated anyway, so the caller's lookup
/// fails with its usual `not found`.
pub(crate) fn to_int(st: &State, path: &str) -> Result<String, Error> {
    let path = path.trim_matches('/');
    let (first, rest) = path.split_once('/').unwrap_or((path, ""));
    if first != "win" {
        let first = root_to_int(first);
        return Ok(if rest.is_empty() {
            first.to_string()
        } else {
            format!("{first}/{rest}")
        });
    }
    if rest.is_empty() {
        return Ok("windows".into());
    }
    let (w, r) = rest.split_once('/').unwrap_or((rest, ""));
    if r.is_empty() {
        return Ok(format!("windows/{w}"));
    }
    let (head, tail) = r.split_once('/').unwrap_or((r, ""));
    // A child of the root named `title`, `state` or `focus` hides the
    // window's file of that name; `set . title=` still reaches the window.
    let shadowed = SHADOWABLE.contains(&head) && st.nodes.contains_key(&format!("windows/{w}/root/{head}"));
    if tail.is_empty() && WINDOW_FILES.contains(&head) && !shadowed {
        return Ok(format!("windows/{w}/{head}"));
    }
    let base = format!("windows/{w}");
    let rel = rel_to_int(r);
    resolve_at(st, &base, &rel)
}

/// Resolves `@name` elements in `rel` (relative to `base`, which is a
/// window directory or a node): each `@name` is the one descendant of the
/// path so far named `name`.
pub(crate) fn resolve_at(st: &State, base: &str, rel: &str) -> Result<String, Error> {
    if !rel.contains('@') {
        return Ok(join(base, rel));
    }
    let mut cur = base.to_string();
    for el in rel.split('/') {
        if let Some(name) = el.strip_prefix('@') {
            cur = find_named(st, &cur, name)?;
        } else {
            cur = join(&cur, el);
        }
    }
    Ok(cur)
}

fn join(base: &str, rel: &str) -> String {
    if rel.is_empty() || rel == "." {
        base.to_string()
    } else if base.is_empty() {
        rel.to_string()
    } else {
        format!("{base}/{rel}")
    }
}

/// The unique node named `name` below `scope`.
pub(crate) fn find_named(st: &State, scope: &str, name: &str) -> Result<String, Error> {
    let prefix = format!("{scope}/");
    let found: Vec<&String> = st
        .nodes
        .range(prefix.clone()..)
        .take_while(|(k, _)| k.starts_with(&prefix))
        .filter(|(k, _)| k.rsplit('/').next() == Some(name))
        .map(|(k, _)| k)
        .collect();
    match found.len() {
        1 => Ok(found[0].clone()),
        0 => Err(Error::new(ErrorKind::NotFound, format!("@{name}"))),
        _ => {
            let list: Vec<String> = found
                .iter()
                .map(|p| {
                    crate::state::win_relative(p)
                        .map(rel_to_ext)
                        .unwrap_or_else(|| p.to_string())
                })
                .collect();
            Err(Error::new(
                ErrorKind::InUse,
                format!("ambiguous: {name} ({})", list.join(", ")),
            ))
        }
    }
}

/// Rewrites the tree's paths in a line of text (an error, a trace line) to
/// the client's: each word, or `k=` value, that starts with `windows/`.
pub fn ext_text(s: &str) -> String {
    if !s.contains("windows/") && !ROOT_NAMES.iter().any(|(_, i)| s.contains(i)) {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len());
    let mut word = String::new();
    let flush = |word: &mut String, out: &mut String| {
        if !word.is_empty() {
            out.push_str(&ext_word(word));
            word.clear();
        }
    };
    for c in s.chars() {
        if c == ' ' || c == '\t' || c == '\n' || c == '(' || c == ',' || c == '\'' {
            flush(&mut word, &mut out);
            out.push(c);
        } else {
            word.push(c);
        }
    }
    flush(&mut word, &mut out);
    out
}

fn ext_word(w: &str) -> String {
    let (pre, path) = match w.find('=') {
        Some(i) => (&w[..=i], &w[i + 1..]),
        None => ("", w),
    };
    let (path, colon) = match path.strip_suffix(':') {
        Some(p) => (p, ":"),
        None => (path, ""),
    };
    let first = path.split('/').next().unwrap_or("");
    let known = first == "windows"
        || (path.contains('/') && ROOT_NAMES.iter().any(|(_, i)| *i == first && *i != "windows"))
        || (["keymap", "clipboard", "clipboard-files"].contains(&path));
    if known {
        format!("{pre}{}{colon}", to_ext(path))
    } else {
        w.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips() {
        for (e, i) in [
            ("win/main", "windows/main"),
            ("win/main/f/emp/in/value", "windows/main/root/f/emp/in/value"),
            ("win/main/style", "windows/main/root/style"),
            ("win/main/title", "windows/main/title"),
            ("win/main/ctl", "windows/main/ctl"),
            ("win/main/over/dlg/ctl", "windows/main/overlays/dlg/ctl"),
            ("keys", "keymap"),
            ("menu/File", "menus/File"),
            ("clip", "clipboard"),
            ("drag/7/data", "drags/7/data"),
        ] {
            let st = State::default();
            assert_eq!(to_int(&st, e).unwrap(), i, "{e}");
            assert_eq!(to_ext(i), e, "{i}");
        }
        assert_eq!(to_ext("windows/main/root"), "win/main");
        assert_eq!(rel_to_ext("root"), ".");
        assert_eq!(rel_to_int("."), "root");
        assert_eq!(
            ext_text("not found: windows/main/root/body/total/text"),
            "not found: win/main/body/total/text"
        );
        assert_eq!(
            ext_text("write path=windows/main/root/x/text data=hi"),
            "write path=win/main/x/text data=hi"
        );
    }
}
