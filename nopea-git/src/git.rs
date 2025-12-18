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

/// Commit information returned by head()
#[derive(Debug, Clone, serde::Serialize)]
pub struct CommitInfo {
    pub sha: String,
    pub author: String,
    pub email: String,
    pub message: String,
    pub timestamp: i64,
}

/// Get HEAD commit information
pub fn head(path: &str) -> Result<CommitInfo, GitError> {
    let repo = Repository::open(path)?;
    let head = repo.head()?;
    let commit = head.peel_to_commit()?;
    let author = commit.author();

    Ok(CommitInfo {
        sha: commit.id().to_string(),
        author: author.name().unwrap_or("").to_string(),
        email: author.email().unwrap_or("").to_string(),
        message: commit.message().unwrap_or("").to_string(),
        timestamp: commit.time().seconds(),
    })
}

/// Checkout a specific commit by SHA (hard reset)
pub fn checkout(path: &str, sha: &str) -> Result<String, GitError> {
    let repo = Repository::open(path)?;
    let oid = git2::Oid::from_str(sha)?;
    let commit = repo.find_commit(oid)?;

    // Hard reset to the commit
    repo.reset(commit.as_object(), ResetType::Hard, None)?;

    Ok(sha.to_string())
}

/// Query remote for the latest commit SHA of a branch (without fetching)
pub fn ls_remote(url: &str, branch: &str) -> Result<String, GitError> {
    let mut remote = git2::Remote::create_detached(url)?;

    let mut callbacks = RemoteCallbacks::new();
    callbacks.credentials(|_url, username_from_url, _allowed_types| {
        if let Some(username) = username_from_url {
            Cred::ssh_key_from_agent(username)
        } else {
            Cred::default()
        }
    });

    // Connect and list refs
    remote.connect_auth(git2::Direction::Fetch, Some(callbacks), None)?;
    let refs = remote.list()?;

    // Find the branch ref
    let branch_ref = format!("refs/heads/{}", branch);
    for r in refs {
        if r.name() == branch_ref {
            return Ok(r.oid().to_string());
        }
    }

    Err(GitError::BranchNotFound(branch.to_string()))
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

    #[test]
    fn test_head_returns_commit_info() {
        let temp = TempDir::new().unwrap();
        let dir = temp.path();

        // Initialize a git repo with a commit
        let repo = Repository::init(dir).unwrap();

        // Configure user for commit
        let mut config = repo.config().unwrap();
        config.set_str("user.name", "Test User").unwrap();
        config.set_str("user.email", "test@example.com").unwrap();

        // Create a file and commit it
        let file_path = dir.join("test.txt");
        fs::write(&file_path, "hello").unwrap();

        let mut index = repo.index().unwrap();
        index.add_path(std::path::Path::new("test.txt")).unwrap();
        index.write().unwrap();

        let tree_id = index.write_tree().unwrap();
        let tree = repo.find_tree(tree_id).unwrap();
        let sig = repo.signature().unwrap();

        repo.commit(
            Some("HEAD"),
            &sig,
            &sig,
            "Initial commit\n\nThis is the body.",
            &tree,
            &[],
        ).unwrap();

        // Now test head()
        let info = head(dir.to_str().unwrap()).unwrap();

        assert_eq!(info.author, "Test User");
        assert_eq!(info.email, "test@example.com");
        assert_eq!(info.message, "Initial commit\n\nThis is the body.");
        assert!(!info.sha.is_empty());
        assert!(info.timestamp > 0);
    }

    #[test]
    fn test_checkout_resets_to_commit() {
        let temp = TempDir::new().unwrap();
        let dir = temp.path();

        // Initialize repo
        let repo = Repository::init(dir).unwrap();
        let mut config = repo.config().unwrap();
        config.set_str("user.name", "Test User").unwrap();
        config.set_str("user.email", "test@example.com").unwrap();

        let sig = repo.signature().unwrap();

        // First commit
        fs::write(dir.join("file.txt"), "version 1").unwrap();
        let mut index = repo.index().unwrap();
        index.add_path(std::path::Path::new("file.txt")).unwrap();
        index.write().unwrap();
        let tree_id = index.write_tree().unwrap();
        let tree = repo.find_tree(tree_id).unwrap();

        let first_commit_oid = repo.commit(
            Some("HEAD"),
            &sig,
            &sig,
            "First commit",
            &tree,
            &[],
        ).unwrap();
        let first_sha = first_commit_oid.to_string();

        // Second commit
        fs::write(dir.join("file.txt"), "version 2").unwrap();
        let mut index = repo.index().unwrap();
        index.add_path(std::path::Path::new("file.txt")).unwrap();
        index.write().unwrap();
        let tree_id = index.write_tree().unwrap();
        let tree = repo.find_tree(tree_id).unwrap();
        let first_commit = repo.find_commit(first_commit_oid).unwrap();

        repo.commit(
            Some("HEAD"),
            &sig,
            &sig,
            "Second commit",
            &tree,
            &[&first_commit],
        ).unwrap();

        // Verify we're at second commit
        let current = head(dir.to_str().unwrap()).unwrap();
        assert!(current.message.contains("Second commit"));

        // Checkout first commit
        let result = checkout(dir.to_str().unwrap(), &first_sha);
        assert!(result.is_ok());

        // Verify we're back at first commit
        let after_checkout = head(dir.to_str().unwrap()).unwrap();
        assert_eq!(after_checkout.sha, first_sha);
        assert!(after_checkout.message.contains("First commit"));

        // Verify file content is rolled back
        let content = fs::read_to_string(dir.join("file.txt")).unwrap();
        assert_eq!(content, "version 1");
    }

    #[test]
    fn test_ls_remote_returns_sha() {
        // Test against a known public repo
        let result = ls_remote(
            "https://github.com/octocat/Hello-World.git",
            "master",
        );

        assert!(result.is_ok());
        let sha = result.unwrap();
        // SHA-1 is 40 hex chars
        assert_eq!(sha.len(), 40);
        assert!(sha.chars().all(|c: char| c.is_ascii_hexdigit()));
    }
}
