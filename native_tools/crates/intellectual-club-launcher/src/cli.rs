use std::fmt;
use std::path::PathBuf;

use clap::{Parser, Subcommand, ValueEnum};

#[derive(Debug, Parser)]
#[command(name = "intellectual-club-launcher")]
#[command(about = "Desktop launcher for Intellectual Club with embedded PostgreSQL")]
pub struct Args {
    #[command(subcommand)]
    pub command: Option<CommandKind>,

    #[arg(long, global = true, value_name = "DIR")]
    pub app_dir: Option<PathBuf>,

    #[arg(
        long,
        global = true,
        env = "IC_LAUNCHER_LOG_LEVEL",
        default_value = "info"
    )]
    pub log_level: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, ValueEnum)]
pub enum LogSource {
    All,
    App,
    Postgres,
    Launcher,
}

impl fmt::Display for LogSource {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::All => "all",
            Self::App => "app",
            Self::Postgres => "postgres",
            Self::Launcher => "launcher",
        })
    }
}

#[derive(Debug, Subcommand)]
pub enum CommandKind {
    Start {
        #[arg(long)]
        open: bool,
    },
    Stop,
    Restart {
        #[arg(long)]
        open: bool,
    },
    Status {
        #[arg(long)]
        json: bool,
    },
    Logs {
        #[arg(long, value_enum, default_value_t = LogSource::All)]
        source: LogSource,

        #[arg(long, default_value_t = 120)]
        lines: usize,
    },
    Open,
    Backup {
        #[arg(long, value_name = "PATH")]
        output: Option<PathBuf>,
    },
    Restore {
        #[arg(value_name = "PATH")]
        path: PathBuf,

        #[arg(long)]
        force: bool,
    },
    MoveData {
        #[arg(long, value_name = "PATH")]
        to: PathBuf,

        #[arg(long)]
        delete_source: bool,
    },
    Paths {
        #[arg(long)]
        json: bool,
    },
    Doctor,
    Daemon {
        #[arg(long)]
        open: bool,
    },
}
