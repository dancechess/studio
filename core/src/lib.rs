mod game;
mod position;

pub use game::*;
pub use position::*;

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum ChessError {
    #[error("invalid FEN: {reason}")]
    InvalidFen { reason: String },
    #[error("illegal or unparsable move: {reason}")]
    InvalidMove { reason: String },
}
