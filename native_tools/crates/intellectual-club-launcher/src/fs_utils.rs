use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{anyhow, Context, Result};
use chrono::{DateTime, SecondsFormat, Utc};

#[derive(Clone, Debug)]
pub struct BackupEntry {
    pub path: PathBuf,
    pub name: String,
    pub size_bytes: u64,
    pub modified_at: Option<String>,
}

pub fn timestamp() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}

pub fn open_log_file(path: &Path) -> Result<File> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .with_context(|| format!("failed to open {}", path.display()))
}

pub fn remove_file_if_exists(path: &Path) -> Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error).with_context(|| format!("failed to remove {}", path.display())),
    }
}

pub fn is_empty_dir(path: &Path) -> Result<bool> {
    if !path.is_dir() {
        return Ok(false);
    }
    Ok(fs::read_dir(path)
        .with_context(|| format!("failed to read {}", path.display()))?
        .next()
        .is_none())
}

pub fn copy_dir_all(source: &Path, target: &Path) -> Result<()> {
    let source_metadata = fs::metadata(source)
        .with_context(|| format!("failed to read metadata for {}", source.display()))?;
    fs::create_dir_all(target).with_context(|| format!("failed to create {}", target.display()))?;
    fs::set_permissions(target, source_metadata.permissions())
        .with_context(|| format!("failed to set permissions for {}", target.display()))?;

    for entry in
        fs::read_dir(source).with_context(|| format!("failed to read {}", source.display()))?
    {
        let entry = entry?;
        let entry_source = entry.path();
        let entry_target = target.join(entry.file_name());
        let file_type = entry.file_type()?;
        if file_type.is_dir() {
            copy_dir_all(&entry_source, &entry_target)?;
        } else if file_type.is_file() {
            fs::copy(&entry_source, &entry_target).with_context(|| {
                format!(
                    "failed to copy {} to {}",
                    entry_source.display(),
                    entry_target.display()
                )
            })?;
            fs::set_permissions(&entry_target, entry.metadata()?.permissions()).with_context(
                || format!("failed to set permissions for {}", entry_target.display()),
            )?;
        }
    }
    Ok(())
}

pub fn tail_file(path: &Path, lines: usize) -> Result<String> {
    if !path.exists() {
        return Ok(String::new());
    }
    let text =
        fs::read_to_string(path).with_context(|| format!("failed to read {}", path.display()))?;
    Ok(text
        .lines()
        .rev()
        .take(lines)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect::<Vec<_>>()
        .join("\n"))
}

pub fn list_backups(backups_dir: &Path) -> Result<Vec<BackupEntry>> {
    if !backups_dir.exists() {
        return Ok(Vec::new());
    }

    let mut entries = Vec::new();
    for entry in fs::read_dir(backups_dir)
        .with_context(|| format!("failed to read {}", backups_dir.display()))?
    {
        let entry = entry?;
        let path = entry.path();
        if path.extension().and_then(|extension| extension.to_str()) != Some("dump") {
            continue;
        }
        let metadata = entry.metadata()?;
        if !metadata.is_file() {
            continue;
        }
        let modified_at = metadata
            .modified()
            .ok()
            .map(DateTime::<Utc>::from)
            .map(|time| time.to_rfc3339_opts(SecondsFormat::Secs, true));
        entries.push(BackupEntry {
            name: entry.file_name().to_string_lossy().into_owned(),
            path,
            size_bytes: metadata.len(),
            modified_at,
        });
    }

    entries.sort_by(|left, right| right.modified_at.cmp(&left.modified_at));
    Ok(entries)
}

pub fn open_url(url: &str) -> Result<()> {
    webbrowser::open(url).with_context(|| format!("failed to open {url}"))?;
    Ok(())
}

pub fn open_path(path: &Path) -> Result<()> {
    let target = if path.exists() {
        path.to_path_buf()
    } else if let Some(parent) = path.parent() {
        parent.to_path_buf()
    } else {
        path.to_path_buf()
    };

    #[cfg(target_os = "macos")]
    {
        let mut command = Command::new("open");
        if target.is_file() {
            command.arg("-R");
        }
        let status = command
            .arg(&target)
            .status()
            .with_context(|| format!("failed to open {}", target.display()))?;
        if status.success() {
            return Ok(());
        }
        return Err(anyhow!("failed to open {}", target.display()));
    }

    #[cfg(target_os = "windows")]
    {
        let status = if target.is_file() {
            Command::new("explorer")
                .arg(format!("/select,{}", target.display()))
                .status()
        } else {
            Command::new("explorer").arg(&target).status()
        }
        .with_context(|| format!("failed to open {}", target.display()))?;
        if status.success() {
            return Ok(());
        }
        return Err(anyhow!("failed to open {}", target.display()));
    }

    #[cfg(all(not(target_os = "macos"), not(target_os = "windows")))]
    {
        let open_target = if target.is_file() {
            target.parent().unwrap_or(&target)
        } else {
            target.as_path()
        };
        let status = Command::new("xdg-open")
            .arg(open_target)
            .status()
            .with_context(|| format!("failed to open {}", open_target.display()))?;
        if status.success() {
            return Ok(());
        }
        Err(anyhow!("failed to open {}", open_target.display()))
    }
}

pub fn append_log_line(path: &Path, line: &str) -> Result<()> {
    let mut file = open_log_file(path)?;
    writeln!(file, "{line}")?;
    Ok(())
}
