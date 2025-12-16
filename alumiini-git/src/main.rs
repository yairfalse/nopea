//! alumiini-git: Git operations sidecar for ALUMIINI
//!
//! Communicates via length-prefixed msgpack over stdin/stdout.
//! Protocol: 4-byte big-endian length + msgpack payload

mod git;
mod protocol;

use std::io::{self, Read, Write};

use protocol::{Request, Response};

fn main() {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut stdin = stdin.lock();
    let mut stdout = stdout.lock();

    loop {
        match read_request(&mut stdin) {
            Ok(request) => {
                let response = handle_request(request);
                if let Err(e) = write_response(&mut stdout, &response) {
                    eprintln!("Failed to write response: {}", e);
                    break;
                }
            }
            Err(e) => {
                // EOF or read error - exit cleanly
                eprintln!("Read error (shutting down): {}", e);
                break;
            }
        }
    }
}

fn read_request<R: Read>(reader: &mut R) -> Result<Request, io::Error> {
    // Read 4-byte length prefix (big-endian)
    let mut len_buf = [0u8; 4];
    reader.read_exact(&mut len_buf)?;
    let len = u32::from_be_bytes(len_buf) as usize;

    // Read payload
    let mut payload = vec![0u8; len];
    reader.read_exact(&mut payload)?;

    // Deserialize msgpack
    rmp_serde::from_slice(&payload)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

fn write_response<W: Write>(writer: &mut W, response: &Response) -> Result<(), io::Error> {
    // Serialize to msgpack
    let payload = rmp_serde::to_vec(response)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;

    // Write 4-byte length prefix (big-endian)
    let len = payload.len() as u32;
    writer.write_all(&len.to_be_bytes())?;

    // Write payload
    writer.write_all(&payload)?;
    writer.flush()?;

    Ok(())
}

fn handle_request(request: Request) -> Response {
    match request {
        Request::Sync {
            url,
            branch,
            path,
            depth,
        } => match git::sync(&url, &branch, &path, depth) {
            Ok(commit) => Response::Ok(commit),
            Err(e) => Response::Err(e.to_string()),
        },

        Request::Files { path, subpath } => match git::list_files(&path, subpath.as_deref()) {
            Ok(files) => Response::OkFiles(files),
            Err(e) => Response::Err(e.to_string()),
        },

        Request::Read { path, file } => match git::read_file(&path, &file) {
            Ok(content) => Response::Ok(content),
            Err(e) => Response::Err(e.to_string()),
        },
    }
}
