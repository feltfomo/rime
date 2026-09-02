#![forbid(unsafe_code)]

use std::{env, process::ExitCode};

const HELP: &str = "rimectl 0.1.0\n\nUsage: rimectl [--help|--version]\n\nDaemon control arrives with the control protocol.";

fn main() -> ExitCode {
    match env::args().nth(1).as_deref() {
        None | Some("--help" | "-h") => {
            println!("{HELP}");
            ExitCode::SUCCESS
        }
        Some("--version" | "-V") => {
            println!("rimectl {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        Some(command) => {
            eprintln!("rimectl: control protocol unavailable; cannot run {command}");
            ExitCode::FAILURE
        }
    }
}
