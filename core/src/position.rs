use shakmaty::fen::Fen;
use shakmaty::san::{San, SanPlus};
use shakmaty::{CastlingMode, Chess, EnPassantMode, Position};

use crate::ChessError;

pub const START_FEN: &str = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";

fn parse_fen(fen: &str) -> Result<Chess, ChessError> {
    let fen: Fen = fen.parse().map_err(|e| ChessError::InvalidFen {
        reason: format!("{e}"),
    })?;
    fen.into_position(CastlingMode::Standard)
        .map_err(|e| ChessError::InvalidFen {
            reason: format!("{e}"),
        })
}

fn to_fen(pos: &Chess) -> String {
    Fen::from_position(pos.clone(), EnPassantMode::Legal).to_string()
}

/// All legal moves in the given position, in SAN (with check/mate suffixes).
#[uniffi::export]
pub fn legal_moves_san(fen: String) -> Result<Vec<String>, ChessError> {
    let pos = parse_fen(&fen)?;
    Ok(pos
        .legal_moves()
        .iter()
        .map(|m| SanPlus::from_move(pos.clone(), m).to_string())
        .collect())
}

/// Play one SAN move on the given position; returns the resulting FEN.
#[uniffi::export]
pub fn apply_san(fen: String, san: String) -> Result<String, ChessError> {
    let pos = parse_fen(&fen)?;
    let san: San = san.parse().map_err(|e| ChessError::InvalidMove {
        reason: format!("{e}"),
    })?;
    let m = san.to_move(&pos).map_err(|e| ChessError::InvalidMove {
        reason: format!("{e}"),
    })?;
    let pos = pos.play(&m).map_err(|e| ChessError::InvalidMove {
        reason: format!("{e}"),
    })?;
    Ok(to_fen(&pos))
}

#[uniffi::export]
pub fn start_fen() -> String {
    START_FEN.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn start_position_has_20_moves() {
        let moves = legal_moves_san(START_FEN.into()).unwrap();
        assert_eq!(moves.len(), 20);
        assert!(moves.contains(&"e4".to_string()));
        assert!(moves.contains(&"Nf3".to_string()));
    }

    #[test]
    fn apply_san_round_trips() {
        let fen = apply_san(START_FEN.into(), "e4".into()).unwrap();
        assert!(fen.starts_with("rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq"));
    }

    #[test]
    fn illegal_move_is_rejected() {
        assert!(apply_san(START_FEN.into(), "Ke2".into()).is_err());
    }

    // perft node counts from the classic reference positions
    // (https://www.chessprogramming.org/Perft_Results)
    fn perft(pos: &Chess, depth: u32) -> u64 {
        if depth == 0 {
            return 1;
        }
        pos.legal_moves()
            .iter()
            .map(|m| {
                let mut next = pos.clone();
                next.play_unchecked(m);
                perft(&next, depth - 1)
            })
            .sum()
    }

    #[test]
    fn perft_startpos() {
        let pos = parse_fen(START_FEN).unwrap();
        assert_eq!(perft(&pos, 4), 197_281);
    }

    #[test]
    fn perft_kiwipete() {
        let pos =
            parse_fen("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1")
                .unwrap();
        assert_eq!(perft(&pos, 3), 97_862);
    }
}
