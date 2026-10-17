//! Per-command process identity inside a shared task container.
//!
//! Docker has no API to signal an exec, and disconnecting from it leaves its process tree
//! running. Every command is therefore started through a tiny wrapper shell and tagged with
//! a unique environment value, so a separate helper exec can stop exactly that command
//! (including daemonized descendants) without touching concurrent work or workspace files.

use anyhow::{bail, Result};
use uuid::Uuid;

/// Environment variable carrying the runner-issued exec id. Reserved for the runner.
pub const EXEC_ID_ENV: &str = "OUTLET_EXEC_ID";

// The wrapper stays alive as the exec's session leader (no `exec`), so the stop helper can
// always find the session even if the command clears its environment.
const WRAPPER: &str = r#""$@"; exit $?"#;
const STOP_SCRIPT: &str = include_str!("stop_exec.sh");

pub fn new_exec_id() -> String {
    Uuid::new_v4().simple().to_string()
}

/// Run `argv` under the session-leader wrapper; arguments are passed through verbatim.
pub fn wrap_command(argv: Vec<String>) -> Vec<String> {
    let mut command = vec![
        "/bin/sh".to_string(),
        "-c".to_string(),
        WRAPPER.to_string(),
        "outlet-exec".to_string(),
    ];
    command.extend(argv);
    command
}

/// Helper command that stops all processes of the given execs and exits 0 once none remain.
pub fn stop_command(exec_ids: &[String]) -> Result<Vec<String>> {
    if exec_ids.is_empty() {
        bail!("no exec ids to stop");
    }
    if exec_ids.iter().any(|id| {
        id.is_empty()
            || !id
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    }) {
        bail!("invalid exec id");
    }
    let mut command = vec![
        "/bin/sh".to_string(),
        "-c".to_string(),
        STOP_SCRIPT.to_string(),
        "outlet-stop".to_string(),
    ];
    command.extend(exec_ids.iter().cloned());
    Ok(command)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wrapper_preserves_arguments_and_stop_rejects_unsafe_ids() {
        let id = new_exec_id();
        assert_eq!(id.len(), 32);
        let wrapped = wrap_command(vec!["printf".into(), String::new(), "a b".into()]);
        assert_eq!(&wrapped[..2], ["/bin/sh", "-c"]);
        assert_eq!(&wrapped[4..], ["printf", "", "a b"]);
        let stop = stop_command(std::slice::from_ref(&id)).unwrap();
        assert_eq!(stop.last(), Some(&id));
        assert!(stop_command(&[]).is_err());
        assert!(stop_command(&["abc;rm".into()]).is_err());
        assert!(stop_command(&["ABC".into()]).is_err());
    }
}
