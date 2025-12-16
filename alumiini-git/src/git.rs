//! Git operations using git2-rs

use std::path::Path;

use base64::Engine;
use git2::{
    build::RepoBuilder, Cred, FetchOptions, RemoteCallbacks, Repository, ResetType,
};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum GitError {
    #[error("git error: {0}")]
    Git(#[from] git2::Error),

    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("repository not found at {0}")]
    RepoNotFound(String),

    #[error("branch '{0}' not found")]
    BranchNotFound(String),

    #[error("file not found: {0}")]
    FileNotFound(String),
}

/// Sync a repository: clone if not exists, fetch+reset if exists.
/// Returns the HEAD commit SHA.
pub fn sync(url: &str, branch: &str, path: &str, depth: u32) -> Result<String, GitError> {
    let repo_path = Path::new(path);

    let repo = if repo_path.join(".git").exists() {
        // Fetch and reset
        fetch_and_reset(repo_path, branch)?
    } else {
        // Clone
        clone(url, branch, repo_path, depth)?
    };

    // Get HEAD commit SHA
    let head = repo.head()?;
    let commit = head.peel_to_commit()?;
    Ok(commit.id().to_string())
}

/// Clone a repository with shallow depth
fn clone(url: &str, branch: &str, path: &Path, depth: u32) -> Result<Repository, GitError> {
    // Ensure parent directory exists
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let mut callbacks = RemoteCallbacks::new();
    callbacks.credentials(|_url, username_from_url, _allowed_types| {
        // Try SSH agent first, then default credentials
        if let Some(username) = username_from_url {
            Cred::ssh_key_from_agent(username)
        } else {
            Cred::default()
        }
    });

    let mut fetch_options = FetchOptions::new();
    fetch_options.remote_callbacks(callbacks);
    fetch_options.depth(depth as i32);

    let repo = RepoBuilder::new()
        .branch(branch)
        .fetch_options(fetch_options)
        .clone(url, path)?;

    Ok(repo)
}

/// Fetch latest and reset to remote branch
fn fetch_and_reset(path: &Path, branch: &str) -> Result<Repository, GitError> {
    let repo = Repository::open(path)?;

    // Fetch from origin in a scope to drop remote before returning repo
    {
        let mut remote = repo.find_remote("origin")?;

        let mut callbacks = RemoteCallbacks::new();
        callbacks.credentials(|_url, username_from_url, _allowed_types| {
            if let Some(username) = username_from_url {
                Cred::ssh_key_from_agent(username)
            } else {
                Cred::default()
            }
        });

        let mut fetch_options = FetchOptions::new();
        fetch_options.remote_callbacks(callbacks);

        let refspec = format!("refs/heads/{}", branch);
        remote.fetch(&[&refspec], Some(&mut fetch_options), None)?;
    }

    // Get the fetched commit and reset in a scope
    {
        let fetch_head = repo.find_reference(&format!("refs/remotes/origin/{}", branch))?;
        let commit = fetch_head.peel_to_commit()?;

        // Hard reset to fetched commit
        repo.reset(commit.as_object(), ResetType::Hard, None)?;
    }

    Ok(repo)
}

/// List YAML files in a directory
pub fn list_files(repo_path: &str, subpath: Option<&str>) -> Result<Vec<String>, GitError> {
    let base = Path::new(repo_path);
    let dir = match subpath {
        Some(sub) => base.join(sub),
        None => base.to_path_buf(),
    };

    if !dir.exists() {
        return Err(GitError::FileNotFound(dir.display().to_string()));
    }

    let mut files = Vec::new();

    for entry in std::fs::read_dir(&dir)? {
        let entry = entry?;
        let path = entry.path();

        if path.is_file() {
            if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                // Skip hidden files
                if name.starts_with('.') {
                    continue;
                }

                // Only include YAML files
                if name.ends_with(".yaml") || name.ends_with(".yml") {
                    files.push(name.to_string());
                }
            }
        }
    }

    // Sort alphabetically
    files.sort();

    Ok(files)
}

/// Read a file and return base64-encoded content
pub fn read_file(repo_path: &str, file: &str) -> Result<String, GitError> {
    let path = Path::new(repo_path).join(file);

    if !path.exists() {
        return Err(GitError::FileNotFound(path.display().to_string()));
    }

    let content = std::fs::read(&path)?;
    let encoded = base64::engine::general_purpose::STANDARD.encode(&content);

    Ok(encoded)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    #[test]
    fn test_list_files_filters_yaml() {
        let temp = TempDir::new().unwrap();
        let dir = temp.path();

        // Create test files
        fs::write(dir.join("deploy.yaml"), "apiVersion: v1").unwrap();
        fs::write(dir.join("config.yml"), "data: {}").unwrap();
        fs::write(dir.join("readme.md"), "# Readme").unwrap();
        fs::write(dir.join(".hidden.yaml"), "secret: true").unwrap();

        let files = list_files(dir.to_str().unwrap(), None).unwrap();

        assert_eq!(files.len(), 2);
        assert!(files.contains(&"config.yml".to_string()));
        assert!(files.contains(&"deploy.yaml".to_string()));
        assert!(!files.contains(&"readme.md".to_string()));
        assert!(!files.contains(&".hidden.yaml".to_string()));
    }

    #[test]
    fn test_read_file_returns_base64() {
        let temp = TempDir::new().unwrap();
        let dir = temp.path();

        let content = "apiVersion: v1\nkind: ConfigMap";
        fs::write(dir.join("test.yaml"), content).unwrap();

        let encoded = read_file(dir.to_str().unwrap(), "test.yaml").unwrap();
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(&encoded)
            .unwrap();
        let decoded_str = String::from_utf8(decoded).unwrap();

        assert_eq!(decoded_str, content);
    }

    #[test]
    fn test_read_file_not_found() {
        let temp = TempDir::new().unwrap();
        let result = read_file(temp.path().to_str().unwrap(), "nonexistent.yaml");
        assert!(matches!(result, Err(GitError::FileNotFound(_))));
    }
}
