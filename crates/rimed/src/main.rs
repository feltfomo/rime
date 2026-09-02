#![forbid(unsafe_code)]

use std::{env, path::PathBuf, process::ExitCode};

use rime_supervise::SupervisorConfig;

fn required_path(name: &str) -> Result<PathBuf, String> {
    let raw = env::var_os(name).ok_or_else(|| format!("{name} is not set"))?;
    let path = PathBuf::from(raw);
    if !path.is_absolute() {
        return Err(format!(
            "{name} must be an absolute path: {}",
            path.display()
        ));
    }
    if !path.exists() {
        return Err(format!("{name} does not exist: {}", path.display()));
    }
    Ok(path)
}

fn main() -> ExitCode {
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("rimed startup failed: could not build runtime: {error}");
            return ExitCode::FAILURE;
        }
    };
    runtime.block_on(run())
}

async fn run() -> ExitCode {
    let result = (|| {
        let quickshell = required_path("RIME_QUICKSHELL")?;
        if !quickshell.is_file() {
            return Err(format!(
                "RIME_QUICKSHELL is not a file: {}",
                quickshell.display()
            ));
        }
        let shell_root = required_path("RIME_SHELL_DIR")?;
        if !shell_root.is_dir() {
            return Err(format!(
                "RIME_SHELL_DIR is not a directory: {}",
                shell_root.display()
            ));
        }
        let runtime_dir = required_path("XDG_RUNTIME_DIR")?;
        Ok(SupervisorConfig {
            quickshell,
            shell_root,
            runtime_dir,
        })
    })();

    let config = match result {
        Ok(config) => config,
        Err(error) => {
            eprintln!("rimed startup failed: {error}");
            return ExitCode::FAILURE;
        }
    };

    match rime_supervise::run(config).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("rimed failed: {error}");
            ExitCode::FAILURE
        }
    }
}
