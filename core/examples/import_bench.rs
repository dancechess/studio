//! Import smoke benchmark:  cargo run --release --example import_bench -- <file.pgn>
use dancechess_core::Database;

fn main() {
    let pgn = std::env::args().nth(1).expect("usage: import_bench <file.pgn>");
    let db_path = std::env::temp_dir().join("dancechess-bench.db");
    let _ = std::fs::remove_file(&db_path);
    let db = Database::open(db_path.to_string_lossy().into()).unwrap();
    let stats = db.import_pgn_file(pgn).unwrap();
    println!(
        "imported {} games ({} skipped) in {:.1}s",
        stats.imported,
        stats.skipped,
        stats.millis as f64 / 1000.0
    );
    let tree = db.opening_tree(dancechess_core::start_fen()).unwrap();
    for m in tree.iter().take(5) {
        println!(
            "  {:6} {:7} games  +{} ={} -{}",
            m.san, m.games, m.white_wins, m.draws, m.black_wins
        );
    }
}
