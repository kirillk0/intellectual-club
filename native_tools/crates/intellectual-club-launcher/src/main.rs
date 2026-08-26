#![cfg_attr(windows, windows_subsystem = "windows")]

fn main() -> anyhow::Result<()> {
    #[cfg(windows)]
    return intellectual_club_launcher::run_gui_entry();

    #[cfg(not(windows))]
    intellectual_club_launcher::run()
}
