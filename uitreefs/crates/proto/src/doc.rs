//! Subtree documents (DESIGN § Atomic updates): two-space indent,
//! `text=<<END` blocks. `print(parse(x)) == x` for canonical input.
//!
//! ```text
//! div root  style='v_flex size_full p=24 gap=16'
//!   text title  style='text_xl font_semibold'  text='Sign in'
//!   markdown help  text=<<END
//! # Help
//!
//! Some *markdown*.
//! END
//! ```
//!
//! Each line is `type name [word...] [prop=value...] [: style...]` in the one
//! quoting rule, indented two spaces per level below the line's parent. A
//! bare word is a boolean (`stripe` means `stripe=on`; `secret` is a flag),
//! and everything after a lone `:` is the node's style, unquoted. There is exactly one root,
//! at no indent. Blank lines between nodes are ignored.
//!
//! A value written `prop=<<MARK` (unquoted, `MARK` of letters, digits and
//! `_`) is a block: its text is the lines after the node line, verbatim, up
//! to a line holding only `MARK` (leading spaces allowed). The lines are
//! joined with `\n`, so a value ending in a newline has an empty last line.
//! Several blocks on one line follow it in order.
//!
//! The canonical form, which `print` writes: `type name` with one space,
//! two spaces before each property, values quoted only when needed, a block
//! for every value holding a newline (marker `END`, or `END1`, `END2`... if
//! the text has an `END` line), and the marker at the node's indent.

use crate::tok::{self, Tok};
use crate::{Error, ErrorKind};

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct DocNode {
    pub ty: String,
    pub name: String,
    /// Bare words: booleans and flags (`stripe`, `secret`).
    pub bare: Vec<String>,
    pub props: Vec<(String, String)>,
    pub children: Vec<DocNode>,
}

impl DocNode {
    pub fn new(ty: impl Into<String>, name: impl Into<String>) -> Self {
        DocNode {
            ty: ty.into(),
            name: name.into(),
            ..Default::default()
        }
    }

    pub fn prop(&self, k: &str) -> Option<&str> {
        self.props
            .iter()
            .find(|(n, _)| n == k)
            .map(|(_, v)| v.as_str())
    }

    pub fn child(&self, name: &str) -> Option<&DocNode> {
        self.children.iter().find(|c| c.name == name)
    }
}

fn bad(line: usize, detail: impl std::fmt::Display) -> Error {
    Error::new(ErrorKind::BadSyntax, format!("line {line}: {detail}"))
}

fn heredoc_marker(t: &Tok) -> Option<&str> {
    if t.quoted {
        return None;
    }
    let (_, v) = t.prop_split()?;
    let m = v.strip_prefix("<<")?;
    (!m.is_empty() && m.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')).then_some(m)
}

pub fn parse(s: &str) -> Result<DocNode, Error> {
    let lines: Vec<&str> = s.split('\n').collect();
    // stack[d] is the open node at depth d.
    let mut stack: Vec<DocNode> = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        let n = i + 1;
        i += 1;
        if line.chars().all(tok::is_blank) {
            continue;
        }
        let indent = line.len() - line.trim_start_matches(' ').len();
        if line[indent..].starts_with('\t') {
            return Err(bad(n, "tab in indent"));
        }
        if !indent.is_multiple_of(2) {
            return Err(bad(n, "odd indent"));
        }
        let depth = indent / 2;
        if depth > stack.len() {
            return Err(bad(n, "indent skips a level"));
        }
        if depth == 0 && !stack.is_empty() {
            return Err(bad(n, "more than one root"));
        }
        if depth + 1 > crate::limits::NODE_DEPTH {
            return Err(Error::new(
                ErrorKind::TooLarge,
                format!("line {n}: deeper than {}", crate::limits::NODE_DEPTH),
            ));
        }

        let toks = tok::tokens(line).map_err(|e| bad(n, e.detail))?;
        let (toks, style) = tok::split_style(toks);
        if toks.len() < 2 {
            return Err(bad(n, "want type and name"));
        }
        for t in &toks[..2] {
            if t.prop_split().is_some() {
                return Err(bad(n, format!("want type and name before {}", t.text)));
            }
        }
        let mut node = DocNode::new(toks[0].text.clone(), toks[1].text.clone());
        if node.ty.is_empty() || node.name.is_empty() {
            return Err(bad(n, "empty type or name"));
        }
        let mut blocks: Vec<(usize, String)> = Vec::new();
        for t in &toks[2..] {
            let Some((k, v)) = t.prop_split() else {
                let w = &t.text;
                let ok = !t.quoted
                    && w.starts_with(|c: char| c.is_ascii_alphabetic() || c == '_')
                    && w.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-');
                if !ok {
                    return Err(bad(n, format!("want prop=value or a flag, got {w}")));
                }
                node.bare.push(w.clone());
                continue;
            };
            if let Some(m) = heredoc_marker(t) {
                blocks.push((node.props.len(), m.to_string()));
                node.props.push((k.to_string(), String::new()));
            } else {
                node.props.push((k.to_string(), v.to_string()));
            }
        }
        for (pi, marker) in blocks {
            let start = i;
            loop {
                let Some(l) = lines.get(i) else {
                    return Err(bad(n, format!("no {marker} line ends the block")));
                };
                i += 1;
                if l.trim_start_matches(' ') == marker {
                    break;
                }
            }
            node.props[pi].1 = lines[start..i - 1].join("\n");
        }
        if let Some(st) = style {
            node.props.push(("style".into(), st));
        }

        while stack.len() > depth {
            let c = stack.pop().unwrap();
            stack.last_mut().unwrap().children.push(c);
        }
        stack.push(node);
    }
    while stack.len() > 1 {
        let c = stack.pop().unwrap();
        stack.last_mut().unwrap().children.push(c);
    }
    stack
        .pop()
        .ok_or_else(|| Error::new(ErrorKind::BadSyntax, "empty document"))
}

fn marker_for(v: &str) -> String {
    let taken = |m: &str| v.split('\n').any(|l| l.trim_start_matches(' ') == m);
    if !taken("END") {
        return "END".into();
    }
    (1..)
        .map(|i| format!("END{i}"))
        .find(|m| !taken(m))
        .unwrap()
}

fn print_into(n: &DocNode, depth: usize, out: &mut String) {
    let indent = "  ".repeat(depth);
    out.push_str(&indent);
    out.push_str(&tok::quote_word(&n.ty));
    out.push(' ');
    out.push_str(&tok::quote_word(&n.name));
    for b in &n.bare {
        out.push_str("  ");
        out.push_str(b);
    }
    let mut blocks = Vec::new();
    let style = n
        .props
        .iter()
        .find(|(k, v)| k == "style" && !v.is_empty() && !v.contains(['\'', '\n']))
        .map(|(_, v)| v.clone());
    for (k, v) in &n.props {
        if k == "style" && style.is_some() {
            continue;
        }
        out.push_str("  ");
        out.push_str(k);
        out.push('=');
        if v.contains('\n') {
            let m = marker_for(v);
            out.push_str("<<");
            out.push_str(&m);
            blocks.push((m, v));
        } else if v.starts_with("<<") {
            out.push_str(&tok::quote_always(v));
        } else {
            out.push_str(&tok::quote(v));
        }
    }
    if let Some(st) = style {
        out.push_str("  : ");
        out.push_str(&st);
    }
    out.push('\n');
    for (m, v) in blocks {
        out.push_str(v);
        out.push('\n');
        out.push_str(&indent);
        out.push_str(&m);
        out.push('\n');
    }
    for c in &n.children {
        print_into(c, depth + 1, out);
    }
}

pub fn print(n: &DocNode) -> String {
    let mut out = String::new();
    print_into(n, 0, &mut out);
    out
}
