//! Protocol definitions for alumiini-git

use serde::{Deserialize, Serialize, ser::SerializeMap};

/// Request from Elixir to Rust
#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "lowercase")]
pub enum Request {
    /// Clone or fetch a repository
    Sync {
        url: String,
        branch: String,
        path: String,
        #[serde(default = "default_depth")]
        depth: u32,
    },

    /// List files in a directory
    Files {
        path: String,
        #[serde(default)]
        subpath: Option<String>,
    },

    /// Read a file (returns base64)
    Read { path: String, file: String },
}

fn default_depth() -> u32 {
    1
}

/// Response from Rust to Elixir
#[derive(Debug)]
pub enum Response {
    /// Success with string result (commit SHA or base64 content)
    Ok(String),

    /// Success with file list
    OkFiles(Vec<String>),

    /// Error
    Err(String),
}

// Custom serialization to match expected format: {"ok": ...} or {"err": ...}
impl Serialize for Response {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        let mut map = serializer.serialize_map(Some(1))?;
        match self {
            Response::Ok(s) => map.serialize_entry("ok", s)?,
            Response::OkFiles(files) => map.serialize_entry("ok", files)?,
            Response::Err(e) => map.serialize_entry("err", e)?,
        }
        map.end()
    }
}
