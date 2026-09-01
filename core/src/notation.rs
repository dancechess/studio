//! Flattens the variation tree into a token stream for the notation view.
//!
//! Layout rules (ChessBase-style):
//! - the mainline (depth 0) flows as ordinary paragraphs;
//! - each depth-1 variation starts its own paragraph, indented one level,
//!   and the mainline resumes in a fresh depth-0 paragraph afterwards;
//! - variations nested deeper stay inline, wrapped in parentheses.
//!
//! Rendering contract for the Swift side: join tokens with a single space,
//! except no space after `OpenParen` and none before `CloseParen`.
//! `ParagraphBreak.depth` is the indent level of the paragraph that follows.
//! Move-suffix NAGs ($1–$6) are merged into the move text ("Nf3!?"), so a
//! `Nag` token is always a standalone evaluation glyph.

use crate::game::{Game, GameInner, ROOT_ID};

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum TokenKind {
    MoveNumber,
    Move,
    Nag,
    Comment,
    OpenParen,
    CloseParen,
    ParagraphBreak,
}

#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct NotationToken {
    pub kind: TokenKind,
    pub text: String,
    /// The move node this token belongs to (clicking it selects that node).
    /// None only for structural tokens (parens, paragraph breaks).
    pub node_id: Option<u32>,
    /// Variation depth: 0 = mainline.
    pub depth: u32,
}

/// Glyph for a move-suffix NAG ($1–$6), appended directly to the SAN.
fn suffix_glyph(nag: u8) -> Option<&'static str> {
    Some(match nag {
        1 => "!",
        2 => "?",
        3 => "!!",
        4 => "??",
        5 => "!?",
        6 => "?!",
        _ => return None,
    })
}

/// Display text for an evaluation/positional NAG token.
fn eval_glyph(nag: u8) -> String {
    match nag {
        7 => "□".into(),
        10 => "=".into(),
        13 => "∞".into(),
        14 => "⩲".into(),
        15 => "⩱".into(),
        16 => "±".into(),
        17 => "∓".into(),
        18 => "+−".into(),
        19 => "−+".into(),
        22 | 23 => "⨀".into(),
        32 | 33 => "⟳".into(),
        36 | 37 => "→".into(),
        40 | 41 => "↑".into(),
        44 | 45 => "=∞".into(),
        132 | 133 => "⇆".into(),
        140 => "∆".into(),
        146 => "N".into(),
        n => format!("${n}"),
    }
}

impl GameInner {
    pub(crate) fn notation_tokens(&self) -> Vec<NotationToken> {
        let mut out = Vec::new();
        if let Some(c) = self.node_comment(ROOT_ID) {
            out.push(NotationToken {
                kind: TokenKind::Comment,
                text: c,
                node_id: Some(ROOT_ID),
                depth: 0,
            });
        }
        self.emit_line(&mut out, ROOT_ID, 0, true);
        // drop a trailing paragraph break (nothing follows it)
        if out.last().map(|t| t.kind) == Some(TokenKind::ParagraphBreak) {
            out.pop();
        }
        out
    }

    fn emit_line(&self, out: &mut Vec<NotationToken>, from: u32, depth: u32, mut force_number: bool) {
        let mut cur = from;
        loop {
            let children = self.node_children(cur);
            let Some(&main) = children.first() else { break };
            let interrupting = self.emit_move(out, main, depth, force_number);
            let alts = &children[1..];
            for &alt in alts {
                if depth == 0 {
                    out.push(structural(TokenKind::ParagraphBreak, 1));
                    self.emit_move(out, alt, 1, true);
                    self.emit_line(out, alt, 1, false);
                } else {
                    out.push(structural(TokenKind::OpenParen, depth + 1));
                    self.emit_move(out, alt, depth + 1, true);
                    self.emit_line(out, alt, depth + 1, false);
                    out.push(structural(TokenKind::CloseParen, depth + 1));
                }
            }
            if depth == 0 && !alts.is_empty() && !self.node_children(main).is_empty() {
                out.push(structural(TokenKind::ParagraphBreak, 0));
            }
            force_number = interrupting || !alts.is_empty();
            cur = main;
        }
    }

    /// Emits number + move (+ NAGs, comment) for one node. Returns true when
    /// the following black move must restate its number (flow interrupted).
    fn emit_move(&self, out: &mut Vec<NotationToken>, id: u32, depth: u32, force_number: bool) -> bool {
        let (num, white) = self.numbering(id);
        if white || force_number {
            out.push(NotationToken {
                kind: TokenKind::MoveNumber,
                text: if white { format!("{num}.") } else { format!("{num}...") },
                node_id: Some(id),
                depth,
            });
        }
        let (suffixes, evals): (Vec<u8>, Vec<u8>) =
            self.node_nags(id).iter().partition(|n| suffix_glyph(**n).is_some());
        let mut text = self.node_san(id);
        for n in &suffixes {
            text.push_str(suffix_glyph(*n).unwrap());
        }
        out.push(NotationToken {
            kind: TokenKind::Move,
            text,
            node_id: Some(id),
            depth,
        });
        for n in &evals {
            out.push(NotationToken {
                kind: TokenKind::Nag,
                text: eval_glyph(*n),
                node_id: Some(id),
                depth,
            });
        }
        let mut interrupting = false;
        if let Some(c) = self.node_comment(id) {
            out.push(NotationToken {
                kind: TokenKind::Comment,
                text: c,
                node_id: Some(id),
                depth,
            });
            interrupting = true;
        }
        interrupting
    }
}

fn structural(kind: TokenKind, depth: u32) -> NotationToken {
    NotationToken {
        kind,
        text: String::new(),
        node_id: None,
        depth,
    }
}

#[uniffi::export]
impl Game {
    /// The whole game flattened for the notation view. Regenerate after any
    /// tree edit; navigation alone never changes it.
    pub fn notation_tokens(&self) -> Vec<NotationToken> {
        self.inner.lock().unwrap().notation_tokens()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use TokenKind::*;

    fn toks(pgn: &str) -> Vec<NotationToken> {
        Game::from_pgn(pgn.into()).unwrap().notation_tokens()
    }

    /// Compact readable dump: "1. e4 ¶1 1... c5 ( 2... d6 )" etc.
    fn dump(tokens: &[NotationToken]) -> String {
        tokens
            .iter()
            .map(|t| match t.kind {
                ParagraphBreak => format!("¶{}", t.depth),
                OpenParen => "(".into(),
                CloseParen => ")".into(),
                Comment => format!("{{{}}}", t.text),
                _ => t.text.clone(),
            })
            .collect::<Vec<_>>()
            .join(" ")
    }

    #[test]
    fn mainline_numbering_black_not_restated() {
        let d = dump(&toks("1. e4 e5 2. Nf3 Nc6 *"));
        assert_eq!(d, "1. e4 e5 2. Nf3 Nc6");
    }

    #[test]
    fn depth1_variation_gets_own_paragraph_and_mainline_resumes() {
        let d = dump(&toks("1. e4 e5 ( 1... c5 2. Nf3 ) 2. Nf3 Nc6 *"));
        assert_eq!(d, "1. e4 e5 ¶1 1... c5 2. Nf3 ¶0 2. Nf3 Nc6");
    }

    #[test]
    fn depth2_variation_stays_inline_in_parens() {
        let d = dump(&toks("1. e4 e5 ( 1... c5 2. Nf3 ( 2. Nc3 Nc6 ) 2... d6 ) 2. Nf3 *"));
        assert_eq!(
            d,
            "1. e4 e5 ¶1 1... c5 2. Nf3 ( 2. Nc3 Nc6 ) 2... d6 ¶0 2. Nf3"
        );
    }

    #[test]
    fn comment_interrupts_flow_and_restates_number() {
        let d = dump(&toks("1. e4 { best by test } 1... e5 2. Nf3 *"));
        assert_eq!(d, "1. e4 {best by test} 1... e5 2. Nf3");
    }

    #[test]
    fn nags_merge_suffix_and_separate_eval() {
        let g = Game::from_pgn("1. e4 e5 2. Nf3 $1 $14 *".into()).unwrap();
        let tokens = g.notation_tokens();
        let nf3 = tokens.iter().find(|t| t.kind == Move && t.text.starts_with("Nf3")).unwrap();
        assert_eq!(nf3.text, "Nf3!");
        let eval = tokens.iter().find(|t| t.kind == Nag).unwrap();
        assert_eq!(eval.text, "⩲");
        assert_eq!(eval.node_id, nf3.node_id);
    }

    #[test]
    fn every_move_token_is_clickable_and_parens_balance() {
        let pgn = std::fs::read_to_string(
            concat!(env!("CARGO_MANIFEST_DIR"), "/../fixtures/repertoire_sample.pgn"),
        )
        .unwrap();
        let game = Game::from_pgn(pgn).unwrap();
        let tokens = game.notation_tokens();

        let mut depth_check = 0i32;
        for t in &tokens {
            match t.kind {
                OpenParen => depth_check += 1,
                CloseParen => depth_check -= 1,
                Move | MoveNumber => {
                    assert!(t.node_id.is_some());
                    // node ids must resolve
                    let _ = game.node(t.node_id.unwrap());
                }
                _ => {}
            }
            assert!(depth_check >= 0);
        }
        assert_eq!(depth_check, 0);

        // exactly one Move token per reachable non-root node
        let mut reachable = 0;
        let mut stack = vec![0u32];
        while let Some(id) = stack.pop() {
            let n = game.node(id);
            reachable += n.children.len();
            stack.extend(n.children);
        }
        let move_tokens = tokens.iter().filter(|t| t.kind == Move).count();
        assert_eq!(move_tokens, reachable);
    }
}
