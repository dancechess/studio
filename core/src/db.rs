use std::sync::Mutex;
use std::time::Instant;

use pgn_reader::BufferedReader;
use rusqlite::{params, Connection};
use shakmaty::fen::Fen;
use shakmaty::san::San;
use shakmaty::zobrist::{Zobrist64, ZobristHash};
use shakmaty::{CastlingMode, Chess, EnPassantMode, Position};

use crate::game::GameBuilder;
use crate::{ChessError, START_FEN};

/// Opening-tree positions are indexed for the first N plies of each game.
const TREE_MAX_PLY: usize = 60;

const RESULT_WHITE: i64 = 0;
const RESULT_DRAW: i64 = 1;
const RESULT_BLACK: i64 = 2;
const RESULT_UNKNOWN: i64 = 3;

#[derive(uniffi::Record)]
pub struct GameSummary {
    pub id: i64,
    pub white: String,
    pub black: String,
    pub white_elo: Option<u32>,
    pub black_elo: Option<u32>,
    pub result: String,
    pub event: String,
    pub date: String,
    pub eco: String,
    pub ply_count: u32,
}

#[derive(uniffi::Record)]
pub struct ImportStats {
    pub imported: u32,
    pub skipped: u32,
    pub millis: u64,
}

#[derive(uniffi::Record)]
pub struct TreeMove {
    pub san: String,
    pub games: u32,
    pub white_wins: u32,
    pub draws: u32,
    pub black_wins: u32,
}

#[derive(uniffi::Enum)]
pub enum GameSort {
    Date,
    White,
    Black,
    Event,
    Eco,
    WhiteElo,
}

#[derive(uniffi::Object)]
pub struct Database {
    conn: Mutex<Connection>,
}

fn db_err(e: impl std::fmt::Display) -> ChessError {
    ChessError::Database {
        reason: format!("{e}"),
    }
}

#[uniffi::export]
impl Database {
    /// Opens (creating if needed) a database file.
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Self, ChessError> {
        let conn = Connection::open(&path).map_err(db_err)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             CREATE TABLE IF NOT EXISTS games (
                 id INTEGER PRIMARY KEY,
                 white TEXT NOT NULL DEFAULT '',
                 black TEXT NOT NULL DEFAULT '',
                 white_elo INTEGER,
                 black_elo INTEGER,
                 result TEXT NOT NULL DEFAULT '*',
                 event TEXT NOT NULL DEFAULT '',
                 site TEXT NOT NULL DEFAULT '',
                 date TEXT NOT NULL DEFAULT '',
                 round TEXT NOT NULL DEFAULT '',
                 eco TEXT NOT NULL DEFAULT '',
                 ply_count INTEGER NOT NULL DEFAULT 0,
                 pgn TEXT NOT NULL
             );
             CREATE TABLE IF NOT EXISTS positions (
                 zobrist INTEGER NOT NULL,
                 game_id INTEGER NOT NULL,
                 move TEXT NOT NULL,
                 result INTEGER NOT NULL
             );
             CREATE INDEX IF NOT EXISTS idx_positions_zobrist ON positions(zobrist);",
        )
        .map_err(db_err)?;
        Ok(Database {
            conn: Mutex::new(conn),
        })
    }

    /// Streams every game of a PGN file into the database.
    /// Unparsable games are skipped, not fatal.
    pub fn import_pgn_file(&self, path: String) -> Result<ImportStats, ChessError> {
        let started = Instant::now();
        let file = std::fs::File::open(&path).map_err(db_err)?;
        let mut reader = BufferedReader::new(file);
        let mut builder = GameBuilder::default();
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction().map_err(db_err)?;
        let mut imported = 0u32;
        let mut skipped = 0u32;
        loop {
            match reader.read_game(&mut builder) {
                Ok(Some(game)) => match insert_game(&tx, &game) {
                    Ok(()) => imported += 1,
                    Err(_) => skipped += 1,
                },
                Ok(None) => break,
                Err(_) => {
                    skipped += 1;
                    break; // stream is unrecoverable after a hard read error
                }
            }
        }
        tx.commit().map_err(db_err)?;
        Ok(ImportStats {
            imported,
            skipped,
            millis: started.elapsed().as_millis() as u64,
        })
    }

    pub fn game_count(&self) -> Result<u64, ChessError> {
        let conn = self.conn.lock().unwrap();
        conn.query_row("SELECT count(*) FROM games", [], |r| r.get::<_, i64>(0))
            .map(|n| n as u64)
            .map_err(db_err)
    }

    /// One page of the game list. `sort` maps to a fixed ORDER BY clause.
    pub fn list_games(
        &self,
        offset: u64,
        limit: u32,
        sort: GameSort,
        ascending: bool,
    ) -> Result<Vec<GameSummary>, ChessError> {
        let order = match sort {
            GameSort::Date => "date",
            GameSort::White => "white",
            GameSort::Black => "black",
            GameSort::Event => "event",
            GameSort::Eco => "eco",
            GameSort::WhiteElo => "white_elo",
        };
        let dir = if ascending { "ASC" } else { "DESC" };
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(&format!(
                "SELECT id, white, black, white_elo, black_elo, result, event, date, eco, ply_count
                 FROM games ORDER BY {order} {dir}, id LIMIT ?1 OFFSET ?2"
            ))
            .map_err(db_err)?;
        let rows = stmt
            .query_map(params![limit, offset as i64], |r| {
                Ok(GameSummary {
                    id: r.get(0)?,
                    white: r.get(1)?,
                    black: r.get(2)?,
                    white_elo: r.get(3)?,
                    black_elo: r.get(4)?,
                    result: r.get(5)?,
                    event: r.get(6)?,
                    date: r.get(7)?,
                    eco: r.get(8)?,
                    ply_count: r.get::<_, i64>(9)? as u32,
                })
            })
            .map_err(db_err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(db_err)
    }

    /// Canonical PGN of one stored game (feed to `Game::from_pgn`).
    pub fn game_pgn(&self, id: i64) -> Result<String, ChessError> {
        let conn = self.conn.lock().unwrap();
        conn.query_row("SELECT pgn FROM games WHERE id = ?1", [id], |r| r.get(0))
            .map_err(db_err)
    }

    /// Opening tree: moves played from `fen` across the database,
    /// with per-move W/D/L stats, most-played first.
    pub fn opening_tree(&self, fen: String) -> Result<Vec<TreeMove>, ChessError> {
        let zobrist = zobrist_of_fen(&fen)?;
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT move, result, count(*) FROM positions
                 WHERE zobrist = ?1 GROUP BY move, result",
            )
            .map_err(db_err)?;
        let mut moves: Vec<TreeMove> = Vec::new();
        let rows = stmt
            .query_map([zobrist], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?))
            })
            .map_err(db_err)?;
        for row in rows {
            let (san, result, count) = row.map_err(db_err)?;
            let entry = match moves.iter_mut().find(|m| m.san == san) {
                Some(e) => e,
                None => {
                    moves.push(TreeMove {
                        san,
                        games: 0,
                        white_wins: 0,
                        draws: 0,
                        black_wins: 0,
                    });
                    moves.last_mut().unwrap()
                }
            };
            let count = count as u32;
            entry.games += count;
            match result {
                RESULT_WHITE => entry.white_wins += count,
                RESULT_DRAW => entry.draws += count,
                RESULT_BLACK => entry.black_wins += count,
                _ => {}
            }
        }
        moves.sort_by(|a, b| b.games.cmp(&a.games));
        Ok(moves)
    }
}

fn zobrist_of_fen(fen: &str) -> Result<i64, ChessError> {
    let fen: Fen = fen.parse().map_err(|e| ChessError::InvalidFen {
        reason: format!("{e}"),
    })?;
    let pos: Chess = fen
        .into_position(CastlingMode::Standard)
        .map_err(|e| ChessError::InvalidFen {
            reason: format!("{e}"),
        })?;
    Ok(zobrist_of(&pos))
}

fn zobrist_of(pos: &Chess) -> i64 {
    let h: Zobrist64 = pos.zobrist_hash(EnPassantMode::Legal);
    h.0 as i64
}

fn result_code(result: &str) -> i64 {
    match result {
        "1-0" => RESULT_WHITE,
        "1/2-1/2" => RESULT_DRAW,
        "0-1" => RESULT_BLACK,
        _ => RESULT_UNKNOWN,
    }
}

fn insert_game(tx: &rusqlite::Transaction, game: &crate::game::GameInner) -> Result<(), ChessError> {
    let h = |key: &str| -> String {
        game.headers
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.clone())
            .unwrap_or_default()
    };
    let elo = |key: &str| -> Option<u32> { h(key).parse().ok() };
    let mainline = game.mainline_sans();
    let result = h("Result");
    tx.execute(
        "INSERT INTO games (white, black, white_elo, black_elo, result, event, site, date, round, eco, ply_count, pgn)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
        params![
            h("White"),
            h("Black"),
            elo("WhiteElo"),
            elo("BlackElo"),
            if result.is_empty() { "*".into() } else { result.clone() },
            h("Event"),
            h("Site"),
            h("Date"),
            h("Round"),
            h("ECO"),
            mainline.len() as i64,
            game.write_pgn(),
        ],
    )
    .map_err(db_err)?;
    let game_id = tx.last_insert_rowid();

    // opening-tree index: only games from the standard starting position
    if game.root_fen != START_FEN {
        return Ok(());
    }
    let rcode = result_code(&result);
    let mut pos = Chess::default();
    let mut stmt = tx
        .prepare_cached("INSERT INTO positions (zobrist, game_id, move, result) VALUES (?1, ?2, ?3, ?4)")
        .map_err(db_err)?;
    for san in mainline.iter().take(TREE_MAX_PLY) {
        let parsed: San = match san.parse() {
            Ok(s) => s,
            Err(_) => break,
        };
        let m = match parsed.to_move(&pos) {
            Ok(m) => m,
            Err(_) => break, // corrupt movetext: keep the game, stop indexing
        };
        stmt.execute(params![zobrist_of(&pos), game_id, san, rcode])
            .map_err(db_err)?;
        pos.play_unchecked(&m);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const TWO_GAMES: &str = "\
[Event \"A\"]\n[White \"Alice\"]\n[Black \"Bob\"]\n[Result \"1-0\"]\n[WhiteElo \"1500\"]\n\n1. e4 e5 2. Nf3 Nc6 1-0\n\n\
[Event \"B\"]\n[White \"Carol\"]\n[Black \"Dan\"]\n[Result \"0-1\"]\n\n1. e4 c5 2. Nf3 d6 0-1\n\n\
[Event \"C\"]\n[White \"Erin\"]\n[Black \"Frank\"]\n[Result \"1/2-1/2\"]\n\n1. d4 d5 1/2-1/2\n";

    fn unique() -> u32 {
        use std::sync::atomic::{AtomicU32, Ordering};
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        COUNTER.fetch_add(1, Ordering::Relaxed)
    }

    fn temp_db() -> (Database, std::path::PathBuf) {
        let path = std::env::temp_dir().join(format!(
            "macbase-test-{}-{}.db",
            std::process::id(),
            unique()
        ));
        let _ = std::fs::remove_file(&path);
        (Database::open(path.to_string_lossy().into()).unwrap(), path)
    }

    fn import_str(db: &Database, pgn: &str) -> ImportStats {
        let path = std::env::temp_dir().join(format!(
            "macbase-test-{}-{}.pgn",
            std::process::id(),
            unique()
        ));
        std::fs::write(&path, pgn).unwrap();
        let stats = db.import_pgn_file(path.to_string_lossy().into()).unwrap();
        let _ = std::fs::remove_file(&path);
        stats
    }

    #[test]
    fn imports_lists_and_reloads() {
        let (db, path) = temp_db();
        let stats = import_str(&db, TWO_GAMES);
        assert_eq!((stats.imported, stats.skipped), (3, 0));
        assert_eq!(db.game_count().unwrap(), 3);

        let games = db.list_games(0, 10, GameSort::White, true).unwrap();
        assert_eq!(games.len(), 3);
        assert_eq!(games[0].white, "Alice");
        assert_eq!(games[0].white_elo, Some(1500));
        assert_eq!(games[0].ply_count, 4);

        // stored canonical PGN parses back into the same game
        let pgn = db.game_pgn(games[0].id).unwrap();
        let game = crate::Game::from_pgn(pgn).unwrap();
        assert_eq!(game.mainline().len(), 4);
        assert_eq!(game.header("Result".into()).as_deref(), Some("1-0"));

        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn opening_tree_aggregates() {
        let (db, path) = temp_db();
        import_str(&db, TWO_GAMES);

        let tree = db.opening_tree(START_FEN.into()).unwrap();
        assert_eq!(tree.len(), 2);
        assert_eq!(tree[0].san, "e4");
        assert_eq!(tree[0].games, 2);
        assert_eq!(tree[0].white_wins, 1);
        assert_eq!(tree[0].black_wins, 1);
        assert_eq!(tree[1].san, "d4");
        assert_eq!(tree[1].draws, 1);

        // after 1. e4: one e5, one c5
        let after_e4 = crate::apply_san(START_FEN.into(), "e4".into()).unwrap();
        let tree = db.opening_tree(after_e4).unwrap();
        let sans: Vec<&str> = tree.iter().map(|m| m.san.as_str()).collect();
        assert_eq!(sans.len(), 2);
        assert!(sans.contains(&"e5") && sans.contains(&"c5"));

        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn fixture_file_imports() {
        let (db, path) = temp_db();
        let stats = db
            .import_pgn_file(
                concat!(env!("CARGO_MANIFEST_DIR"), "/../fixtures/repertoire_sample.pgn").into(),
            )
            .unwrap();
        assert!(stats.imported >= 1);
        assert_eq!(stats.skipped, 0);
        let _ = std::fs::remove_file(path);
    }
}
