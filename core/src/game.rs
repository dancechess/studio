use std::sync::Mutex;

use pgn_reader::{BufferedReader, Nag, RawComment, RawHeader, SanPlus, Skip, Visitor};
use shakmaty::fen::Fen;
use shakmaty::san::San;
use shakmaty::{CastlingMode, Chess, Color, EnPassantMode, Position};

use crate::{ChessError, START_FEN};

pub const ROOT_ID: u32 = 0;

/// One node in the variation tree. Node 0 is the root (the starting position,
/// no move); every other node represents the move that leads to it.
/// `children[0]` is the main continuation, the rest are variations.
#[derive(Debug, Clone, Default)]
struct Node {
    san: String,
    parent: Option<u32>,
    children: Vec<u32>,
    nags: Vec<u8>,
    comment: Option<String>,
}

#[derive(Debug, Clone)]
struct GameInner {
    headers: Vec<(String, String)>,
    root_fen: String,
    nodes: Vec<Node>,
}

impl Default for GameInner {
    fn default() -> Self {
        GameInner {
            headers: Vec::new(),
            root_fen: START_FEN.to_string(),
            nodes: vec![Node::default()],
        }
    }
}

/// Full move info for one node, bridged to Swift as a record.
#[derive(uniffi::Record)]
pub struct NodeInfo {
    pub id: u32,
    pub parent: Option<u32>,
    pub children: Vec<u32>,
    pub san: String,
    pub nags: Vec<u8>,
    pub comment: Option<String>,
    /// 1-based fullmove number of this move.
    pub move_number: u32,
    /// True if this move was played by White.
    pub is_white_move: bool,
}

#[derive(uniffi::Object)]
pub struct Game {
    inner: Mutex<GameInner>,
}

impl GameInner {
    fn root_position(&self) -> Result<Chess, ChessError> {
        let fen: Fen = self.root_fen.parse().map_err(|e| ChessError::InvalidFen {
            reason: format!("{e}"),
        })?;
        fen.into_position(CastlingMode::Standard)
            .map_err(|e| ChessError::InvalidFen {
                reason: format!("{e}"),
            })
    }

    /// Moves (SAN) from the root to `id`, root first.
    fn path_to(&self, id: u32) -> Vec<u32> {
        let mut path = Vec::new();
        let mut cur = Some(id);
        while let Some(i) = cur {
            if i != ROOT_ID {
                path.push(i);
            }
            cur = self.nodes[i as usize].parent;
        }
        path.reverse();
        path
    }

    fn position_at(&self, id: u32) -> Result<Chess, ChessError> {
        let mut pos = self.root_position()?;
        for i in self.path_to(id) {
            let san: San =
                self.nodes[i as usize]
                    .san
                    .parse()
                    .map_err(|e| ChessError::InvalidMove {
                        reason: format!("{e}"),
                    })?;
            let m = san.to_move(&pos).map_err(|e| ChessError::InvalidMove {
                reason: format!("bad move '{}' in game: {e}", self.nodes[i as usize].san),
            })?;
            pos.play_unchecked(&m);
        }
        Ok(pos)
    }

    /// (fullmove number, is_white_move) of the move at `id`.
    /// For the root (no move) it reports the upcoming move instead.
    fn numbering(&self, id: u32) -> (u32, bool) {
        let ply_in_game = self.path_to(id).len() as u32; // >= 1 for non-root
        let (base_fullmove, base_white) = self
            .root_fen
            .parse::<Fen>()
            .ok()
            .map(|f| {
                let setup = f.into_setup();
                (
                    u32::from(setup.fullmoves),
                    setup.turn == Color::White,
                )
            })
            .unwrap_or((1, true));
        if ply_in_game == 0 {
            return (base_fullmove, base_white);
        }
        let base_ply = if base_white { 0 } else { 1 };
        let abs_ply = base_ply + ply_in_game - 1; // 0-based ply of this move
        (base_fullmove + abs_ply / 2, abs_ply % 2 == 0)
    }

    fn node_info(&self, id: u32) -> NodeInfo {
        let n = &self.nodes[id as usize];
        let (move_number, is_white_move) = self.numbering(id);
        NodeInfo {
            id,
            parent: n.parent,
            children: n.children.clone(),
            san: n.san.clone(),
            nags: n.nags.clone(),
            comment: n.comment.clone(),
            move_number,
            is_white_move,
        }
    }

    // --- PGN serialization ---

    fn write_pgn(&self) -> String {
        let mut out = String::new();
        for (k, v) in &self.headers {
            out.push_str(&format!("[{} \"{}\"]\n", k, v.replace('"', "\\\"")));
        }
        if !self.headers.is_empty() {
            out.push('\n');
        }
        let mut body = String::new();
        self.write_moves(&mut body, ROOT_ID, true);
        let result = self
            .headers
            .iter()
            .find(|(k, _)| k == "Result")
            .map(|(_, v)| v.as_str())
            .unwrap_or("*");
        if !body.is_empty() {
            body.push(' ');
        }
        body.push_str(result);
        out.push_str(&wrap_pgn_body(&body));
        out.push('\n');
        out
    }

    fn write_moves(&self, out: &mut String, from: u32, mut force_number: bool) {
        let mut cur = from;
        loop {
            let children = &self.nodes[cur as usize].children;
            if children.is_empty() {
                break;
            }
            let main = children[0];
            let interrupting = self.write_one_move(out, main, force_number);
            for &alt in &children[1..] {
                push_sep(out);
                out.push('(');
                self.write_one_move(out, alt, true);
                self.write_moves(out, alt, false);
                out.push(')');
            }
            force_number = interrupting || children.len() > 1;
            cur = main;
        }
    }

    /// Writes one move (number, SAN, NAGs, comment). Returns true if what
    /// follows needs a re-stated move number (a comment interrupts the flow).
    fn write_one_move(&self, out: &mut String, id: u32, force_number: bool) -> bool {
        let n = &self.nodes[id as usize];
        let (num, white) = self.numbering(id);
        push_sep(out);
        if white {
            out.push_str(&format!("{num}. "));
        } else if force_number {
            out.push_str(&format!("{num}... "));
        }
        out.push_str(&n.san);
        for nag in &n.nags {
            out.push_str(&format!(" ${nag}"));
        }
        let mut interrupting = false;
        if let Some(c) = &n.comment {
            out.push_str(&format!(" {{ {c} }}"));
            interrupting = true;
        }
        interrupting
    }
}

fn push_sep(out: &mut String) {
    if !out.is_empty() && !out.ends_with(' ') && !out.ends_with('(') {
        out.push(' ');
    }
}

/// Hard-wrap the movetext at ~80 columns, as PGN convention expects.
fn wrap_pgn_body(body: &str) -> String {
    let mut out = String::new();
    let mut line_len = 0;
    for word in body.split(' ') {
        if line_len > 0 && line_len + 1 + word.len() > 80 {
            out.push('\n');
            line_len = 0;
        } else if line_len > 0 {
            out.push(' ');
            line_len += 1;
        }
        out.push_str(word);
        line_len += word.len();
    }
    out
}

#[uniffi::export]
impl Game {
    /// A new empty game from the standard starting position.
    #[uniffi::constructor]
    pub fn new() -> Self {
        Game {
            inner: Mutex::new(GameInner::default()),
        }
    }

    /// Parses the first game in `pgn`.
    #[uniffi::constructor]
    pub fn from_pgn(pgn: String) -> Result<Self, ChessError> {
        let mut reader = BufferedReader::new_cursor(&pgn);
        let mut builder = GameBuilder::default();
        let inner = reader
            .read_game(&mut builder)
            .map_err(|e| ChessError::InvalidMove {
                reason: format!("PGN read error: {e}"),
            })?
            .ok_or(ChessError::InvalidMove {
                reason: "no game found in PGN".into(),
            })?;
        Ok(Game {
            inner: Mutex::new(inner),
        })
    }

    // --- reading ---

    pub fn headers(&self) -> Vec<Vec<String>> {
        let inner = self.inner.lock().unwrap();
        inner
            .headers
            .iter()
            .map(|(k, v)| vec![k.clone(), v.clone()])
            .collect()
    }

    pub fn header(&self, key: String) -> Option<String> {
        let inner = self.inner.lock().unwrap();
        inner
            .headers
            .iter()
            .find(|(k, _)| *k == key)
            .map(|(_, v)| v.clone())
    }

    pub fn node(&self, id: u32) -> NodeInfo {
        self.inner.lock().unwrap().node_info(id)
    }

    /// Node ids of the mainline, root excluded, in order.
    pub fn mainline(&self) -> Vec<u32> {
        let inner = self.inner.lock().unwrap();
        let mut ids = Vec::new();
        let mut cur = ROOT_ID;
        while let Some(&next) = inner.nodes[cur as usize].children.first() {
            ids.push(next);
            cur = next;
        }
        ids
    }

    pub fn fen_at(&self, id: u32) -> Result<String, ChessError> {
        let inner = self.inner.lock().unwrap();
        let pos = inner.position_at(id)?;
        Ok(Fen::from_position(pos, EnPassantMode::Legal).to_string())
    }

    pub fn legal_moves_at(&self, id: u32) -> Result<Vec<String>, ChessError> {
        let inner = self.inner.lock().unwrap();
        Ok(crate::legal_moves_san(
            Fen::from_position(inner.position_at(id)?, EnPassantMode::Legal).to_string(),
        )?)
    }

    // --- editing ---

    pub fn set_header(&self, key: String, value: String) {
        let mut inner = self.inner.lock().unwrap();
        if let Some(pair) = inner.headers.iter_mut().find(|(k, _)| *k == key) {
            pair.1 = value;
        } else {
            inner.headers.push((key, value));
        }
    }

    /// Plays `san` from node `id`. Reuses an existing child with the same
    /// move, otherwise appends a new child (a variation if one exists).
    /// Returns the id of the reached node.
    pub fn add_move(&self, id: u32, san: String) -> Result<u32, ChessError> {
        let mut inner = self.inner.lock().unwrap();
        // validate against the actual position
        let pos = inner.position_at(id)?;
        let parsed: San = san.parse().map_err(|e| ChessError::InvalidMove {
            reason: format!("{e}"),
        })?;
        let m = parsed.to_move(&pos).map_err(|e| ChessError::InvalidMove {
            reason: format!("{e}"),
        })?;
        // normalize to SanPlus so check/mate suffixes are consistent
        let san = shakmaty::san::SanPlus::from_move(pos, &m).to_string();
        if let Some(&existing) = inner.nodes[id as usize]
            .children
            .iter()
            .find(|&&c| inner.nodes[c as usize].san == san)
        {
            return Ok(existing);
        }
        let new_id = inner.nodes.len() as u32;
        inner.nodes.push(Node {
            san,
            parent: Some(id),
            ..Default::default()
        });
        inner.nodes[id as usize].children.push(new_id);
        Ok(new_id)
    }

    pub fn set_comment(&self, id: u32, comment: Option<String>) {
        let mut inner = self.inner.lock().unwrap();
        inner.nodes[id as usize].comment = comment.filter(|c| !c.is_empty());
    }

    pub fn add_nag(&self, id: u32, nag: u8) {
        let mut inner = self.inner.lock().unwrap();
        let nags = &mut inner.nodes[id as usize].nags;
        if !nags.contains(&nag) {
            nags.push(nag);
        }
    }

    pub fn clear_nags(&self, id: u32) {
        self.inner.lock().unwrap().nodes[id as usize].nags.clear();
    }

    /// Makes `id` the first child of its parent (promotes the variation).
    pub fn promote_variation(&self, id: u32) {
        let mut inner = self.inner.lock().unwrap();
        if let Some(parent) = inner.nodes[id as usize].parent {
            let children = &mut inner.nodes[parent as usize].children;
            if let Some(pos) = children.iter().position(|&c| c == id) {
                children.remove(pos);
                children.insert(0, id);
            }
        }
    }

    /// Removes the move at `id` and its whole subtree. Subtree nodes stay
    /// allocated but unreachable; ids of other nodes remain stable.
    pub fn delete_node(&self, id: u32) {
        let mut inner = self.inner.lock().unwrap();
        if id == ROOT_ID {
            return;
        }
        if let Some(parent) = inner.nodes[id as usize].parent {
            inner.nodes[parent as usize].children.retain(|&c| c != id);
        }
    }

    pub fn to_pgn(&self) -> String {
        self.inner.lock().unwrap().write_pgn()
    }
}

// --- PGN parsing ---

#[derive(Default)]
struct GameBuilder {
    game: GameInner,
    current: u32,
    stack: Vec<u32>,
}

impl Visitor for GameBuilder {
    type Result = GameInner;

    fn begin_game(&mut self) {
        self.game = GameInner::default();
        self.current = ROOT_ID;
        self.stack.clear();
    }

    fn header(&mut self, key: &[u8], value: RawHeader<'_>) {
        let key = String::from_utf8_lossy(key).to_string();
        let value = value.decode_utf8_lossy().to_string();
        if key == "FEN" {
            self.game.root_fen = value.clone();
        }
        self.game.headers.push((key, value));
    }

    fn san(&mut self, san_plus: SanPlus) {
        let new_id = self.game.nodes.len() as u32;
        self.game.nodes.push(Node {
            san: san_plus.to_string(),
            parent: Some(self.current),
            ..Default::default()
        });
        self.game.nodes[self.current as usize].children.push(new_id);
        self.current = new_id;
    }

    fn nag(&mut self, nag: Nag) {
        self.game.nodes[self.current as usize].nags.push(nag.0);
    }

    fn comment(&mut self, comment: RawComment<'_>) {
        let text = String::from_utf8_lossy(comment.as_bytes()).trim().to_string();
        if text.is_empty() {
            return;
        }
        let node = &mut self.game.nodes[self.current as usize];
        node.comment = Some(match node.comment.take() {
            Some(prev) => format!("{prev} {text}"),
            None => text,
        });
    }

    fn begin_variation(&mut self) -> Skip {
        self.stack.push(self.current);
        // a variation is an alternative to the move just played
        self.current = self.game.nodes[self.current as usize]
            .parent
            .unwrap_or(ROOT_ID);
        Skip(false)
    }

    fn end_variation(&mut self) {
        self.current = self.stack.pop().unwrap_or(ROOT_ID);
    }

    fn end_game(&mut self) -> GameInner {
        std::mem::take(&mut self.game)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SIMPLE: &str = "[Event \"Test\"]\n[Result \"1-0\"]\n\n1. e4 e5 2. Nf3 ( 2. f4 exf4 { the King's Gambit } ) 2... Nc6 $1 3. Bb5 1-0\n";

    #[test]
    fn parses_mainline_and_variation() {
        let game = Game::from_pgn(SIMPLE.into()).unwrap();
        let mainline = game.mainline();
        let sans: Vec<String> = mainline.iter().map(|&id| game.node(id).san).collect();
        assert_eq!(sans, vec!["e4", "e5", "Nf3", "Nc6", "Bb5"]);
        // variation hangs off the position after 1...e5
        let nf3 = game.node(mainline[2]);
        let after_e5 = game.node(nf3.parent.unwrap());
        assert_eq!(after_e5.children.len(), 2);
        let f4 = game.node(after_e5.children[1]);
        assert_eq!(f4.san, "f4");
        let exf4 = game.node(f4.children[0]);
        assert_eq!(exf4.comment.as_deref(), Some("the King's Gambit"));
        // NAG on 2...Nc6
        assert_eq!(game.node(mainline[3]).nags, vec![1]);
    }

    #[test]
    fn numbering_is_correct() {
        let game = Game::from_pgn(SIMPLE.into()).unwrap();
        let ids = game.mainline();
        let e5 = game.node(ids[1]);
        assert_eq!((e5.move_number, e5.is_white_move), (1, false));
        let bb5 = game.node(ids[4]);
        assert_eq!((bb5.move_number, bb5.is_white_move), (3, true));
    }

    #[test]
    fn fen_and_legal_moves_at_node() {
        let game = Game::from_pgn(SIMPLE.into()).unwrap();
        let ids = game.mainline();
        let fen = game.fen_at(ids[0]).unwrap();
        assert!(fen.contains("4P3"));
        assert!(game.legal_moves_at(ids[1]).unwrap().contains(&"Nf3".into()));
    }

    #[test]
    fn add_move_creates_variation_and_reuses_existing() {
        let game = Game::new();
        let e4 = game.add_move(ROOT_ID, "e4".into()).unwrap();
        let again = game.add_move(ROOT_ID, "e4".into()).unwrap();
        assert_eq!(e4, again);
        let d4 = game.add_move(ROOT_ID, "d4".into()).unwrap();
        assert_ne!(e4, d4);
        assert_eq!(game.node(ROOT_ID).children, vec![e4, d4]);
        assert!(game.add_move(ROOT_ID, "Ke2".into()).is_err());
        // check suffix is normalized in
        let e5 = game.add_move(e4, "e5".into()).unwrap();
        let qh5 = game.add_move(e5, "Qh5".into()).unwrap();
        let g6 = game.add_move(qh5, "g6".into()).unwrap();
        let qxe5 = game.add_move(g6, "Qxe5".into()).unwrap();
        assert_eq!(game.node(qxe5).san, "Qxe5+");
    }

    #[test]
    fn round_trip_preserves_tree() {
        let game = Game::from_pgn(SIMPLE.into()).unwrap();
        let pgn = game.to_pgn();
        let game2 = Game::from_pgn(pgn.clone()).unwrap();
        assert_eq!(trees(&game), trees(&game2), "round-trip changed the tree:\n{pgn}");
    }

    #[test]
    fn round_trip_fixture_with_deep_variations() {
        let pgn = std::fs::read_to_string(
            concat!(env!("CARGO_MANIFEST_DIR"), "/../fixtures/repertoire_sample.pgn"),
        )
        .unwrap();
        let game = Game::from_pgn(pgn).unwrap();
        let out = game.to_pgn();
        let game2 = Game::from_pgn(out.clone()).unwrap();
        assert_eq!(trees(&game), trees(&game2));
        // and every node's position must be reachable (all SANs legal in context)
        for id in all_ids(&game) {
            game.fen_at(id).unwrap();
        }
    }

    fn all_ids(game: &Game) -> Vec<u32> {
        let mut ids = vec![ROOT_ID];
        let mut i = 0;
        while i < ids.len() {
            ids.extend(game.node(ids[i]).children.clone());
            i += 1;
        }
        ids
    }

    /// Canonical (san, nags, comment, child-count) preorder dump for equality checks.
    fn trees(game: &Game) -> Vec<(String, Vec<u8>, Option<String>, usize)> {
        all_ids(game)
            .into_iter()
            .map(|id| {
                let n = game.node(id);
                (n.san, n.nags, n.comment, n.children.len())
            })
            .collect()
    }
}
