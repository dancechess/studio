mod db;
mod game;
mod notation;
mod position;

pub use db::*;
pub use game::*;
pub use notation::*;
pub use position::*;

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum ChessError {
    #[error("invalid FEN: {reason}")]
    InvalidFen { reason: String },
    #[error("illegal or unparsable move: {reason}")]
    InvalidMove { reason: String },
    #[error("database error: {reason}")]
    Database { reason: String },
}
