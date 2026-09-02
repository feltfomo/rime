#![forbid(unsafe_code)]

// pure decisions keep timing and transition tests deterministic without real process waits
use std::{
    collections::VecDeque,
    fs::{self, File, OpenOptions},
    future::{Future, poll_fn},
    io,
    os::unix::{
        fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
        process::ExitStatusExt,
    },
    path::{Path, PathBuf},
    process::ExitStatus,
    task::Poll,
    time::Duration,
};

use fs2::FileExt;
use nix::{
    sys::signal::{Signal, kill},
    unistd::{Pid, geteuid},
};
use tokio::{
    process::{Child, Command},
    signal::unix::{SignalKind, signal},
    time::{Instant, timeout},
};

pub const CRASH_WINDOW: Duration = Duration::from_secs(20);
pub const CLEAN_UPTIME: Duration = Duration::from_secs(30);
pub const SHUTDOWN_GRACE: Duration = Duration::from_secs(2);
const CRASH_THRESHOLD: usize = 5;
const BACKOFF: [Duration; 5] = [
    Duration::from_millis(100),
    Duration::from_millis(200),
    Duration::from_millis(400),
    Duration::from_millis(800),
    Duration::from_secs(1),
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ViewKind {
    Normal,
    Safe,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Effect {
    Start(ViewKind),
    Wait(Duration),
}

#[derive(Debug)]
pub struct Policy {
    kind: ViewKind,
    normal_failures: VecDeque<Duration>,
    normal_backoff: usize,
    safe_backoff: usize,
    latest_normal_reason: Option<String>,
}

impl Default for Policy {
    fn default() -> Self {
        Self {
            kind: ViewKind::Normal,
            normal_failures: VecDeque::new(),
            normal_backoff: 0,
            safe_backoff: 0,
            latest_normal_reason: None,
        }
    }
}

impl Policy {
    #[must_use]
    pub fn kind(&self) -> ViewKind {
        self.kind
    }

    #[must_use]
    pub fn latest_normal_reason(&self) -> Option<&str> {
        self.latest_normal_reason.as_deref()
    }

    pub fn child_exited(
        &mut self,
        started_at: Duration,
        exited_at: Duration,
        successful: bool,
        reason: String,
    ) -> Vec<Effect> {
        match self.kind {
            ViewKind::Normal => self.normal_exited(started_at, exited_at, reason),
            ViewKind::Safe if successful => {
                // a clean safe exit is the only reload signal before the control protocol exists
                self.kind = ViewKind::Normal;
                self.normal_failures.clear();
                self.normal_backoff = 0;
                self.safe_backoff = 0;
                vec![Effect::Start(ViewKind::Normal)]
            }
            ViewKind::Safe => {
                let delay = backoff(self.safe_backoff);
                self.safe_backoff = self.safe_backoff.saturating_add(1);
                vec![Effect::Wait(delay), Effect::Start(ViewKind::Safe)]
            }
        }
    }

    fn normal_exited(
        &mut self,
        started_at: Duration,
        exited_at: Duration,
        reason: String,
    ) -> Vec<Effect> {
        if exited_at.saturating_sub(started_at) >= CLEAN_UPTIME {
            // this exit becomes the first failure in a fresh crash history
            self.normal_failures.clear();
            self.normal_backoff = 0;
        }

        while self
            .normal_failures
            .front()
            .is_some_and(|at| exited_at.saturating_sub(*at) >= CRASH_WINDOW)
        {
            self.normal_failures.pop_front();
        }
        self.normal_failures.push_back(exited_at);
        self.latest_normal_reason = Some(reason);

        if self.normal_failures.len() >= CRASH_THRESHOLD {
            self.kind = ViewKind::Safe;
            self.safe_backoff = 0;
            vec![Effect::Start(ViewKind::Safe)]
        } else {
            let delay = backoff(self.normal_backoff);
            self.normal_backoff = self.normal_backoff.saturating_add(1);
            vec![Effect::Wait(delay), Effect::Start(ViewKind::Normal)]
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ShutdownEvent {
    Requested,
    Reaped,
    Deadline,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ShutdownEffect {
    Terminate,
    WaitForReap(Duration),
    Kill,
    Reap,
    Exit,
}

#[derive(Debug, Default)]
struct ShutdownPolicy {
    requested: bool,
    forced: bool,
}

impl ShutdownPolicy {
    fn transition(&mut self, event: ShutdownEvent) -> Vec<ShutdownEffect> {
        match event {
            ShutdownEvent::Requested if !self.requested => {
                self.requested = true;
                vec![
                    ShutdownEffect::Terminate,
                    ShutdownEffect::WaitForReap(SHUTDOWN_GRACE),
                ]
            }
            ShutdownEvent::Deadline if self.requested && !self.forced => {
                self.forced = true;
                vec![ShutdownEffect::Kill, ShutdownEffect::Reap]
            }
            ShutdownEvent::Reaped if self.requested => vec![ShutdownEffect::Exit],
            ShutdownEvent::Requested | ShutdownEvent::Reaped | ShutdownEvent::Deadline => {
                Vec::new()
            }
        }
    }

    fn forced(&self) -> bool {
        self.forced
    }
}

fn backoff(attempt: usize) -> Duration {
    BACKOFF[attempt.min(BACKOFF.len() - 1)]
}

#[derive(Debug)]
pub struct SupervisorConfig {
    pub quickshell: PathBuf,
    pub shell_root: PathBuf,
    pub runtime_dir: PathBuf,
}

struct InstanceGuard {
    _file: File,
}

impl InstanceGuard {
    fn acquire(runtime_root: &Path) -> Result<Self, String> {
        let directory = runtime_root.join("rime");
        match fs::create_dir(&directory) {
            Ok(()) => fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))
                .map_err(|error| format!("could not secure {}: {error}", directory.display()))?,
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => {
                return Err(format!("could not create {}: {error}", directory.display()));
            }
        }
        validate_owned_directory(&directory)?;

        let lock_path = directory.join("rimed.lock");
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(&lock_path)
            .map_err(|error| format!("could not open {}: {error}", lock_path.display()))?;
        validate_owned_file(&lock_path, &file)?;
        // the open kernel lock is authoritative while the pathname may remain after exit
        file.try_lock_exclusive().map_err(|error| {
            format!(
                "rimed is already running; lock held at {}: {error}",
                lock_path.display()
            )
        })?;
        Ok(Self { _file: file })
    }
}

fn validate_owned_directory(path: &Path) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("could not inspect {}: {error}", path.display()))?;
    if !metadata.file_type().is_dir() {
        return Err(format!(
            "runtime path is not a directory: {}",
            path.display()
        ));
    }
    validate_owner_and_mode(path, &metadata, 0o077)
}

fn validate_owned_file(path: &Path, file: &File) -> Result<(), String> {
    let metadata = file
        .metadata()
        .map_err(|error| format!("could not inspect {}: {error}", path.display()))?;
    if !metadata.file_type().is_file() {
        return Err(format!(
            "lock path is not a regular file: {}",
            path.display()
        ));
    }
    validate_owner_and_mode(path, &metadata, 0o177)
}

fn validate_owner_and_mode(
    path: &Path,
    metadata: &fs::Metadata,
    forbidden_mode: u32,
) -> Result<(), String> {
    if metadata.uid() != geteuid().as_raw() {
        return Err(format!(
            "runtime path is not owned by this user: {}",
            path.display()
        ));
    }
    if metadata.mode() & forbidden_mode != 0 {
        return Err(format!(
            "runtime path permissions are too broad: {}",
            path.display()
        ));
    }
    Ok(())
}

#[allow(clippy::missing_errors_doc)]
pub async fn run(config: SupervisorConfig) -> Result<(), String> {
    let _instance = InstanceGuard::acquire(&config.runtime_dir)?;
    let mut policy = Policy::default();
    let origin = Instant::now();
    println!("rime-event daemon-start pid={}", std::process::id());

    loop {
        let kind = policy.kind();
        let entry = match kind {
            ViewKind::Normal => config.shell_root.join("shell.qml"),
            ViewKind::Safe => config.shell_root.join("safe.qml"),
        };
        let mut command = Command::new(&config.quickshell);
        command.arg("--path").arg(&entry).kill_on_drop(true);
        if kind == ViewKind::Safe {
            command.env(
                "RIME_CRASH_REASON",
                policy
                    .latest_normal_reason()
                    .unwrap_or("normal view failed"),
            );
        } else {
            command.env_remove("RIME_CRASH_REASON");
        }
        let child = command.spawn().map_err(|error| {
            format!(
                "could not launch {} --path {}: {error}",
                config.quickshell.display(),
                entry.display()
            )
        })?;
        let pid = child
            .id()
            .ok_or_else(|| "spawned view has no process id".to_owned())?;
        let started_at = origin.elapsed();
        println!(
            "rime-event child-start kind={} pid={pid} path={}",
            kind_name(kind),
            entry.display()
        );

        let status = match wait_for_child_or_signal(child, pid).await? {
            WaitOutcome::Exited(status) => status,
            WaitOutcome::Terminated => {
                println!("rime-event daemon-stop reason=sigterm");
                return Ok(());
            }
        };

        let reason = exit_reason(kind, status);
        println!(
            "rime-event child-exit kind={} pid={pid} success={} reason={}",
            kind_name(kind),
            status.success(),
            reason.replace(['\n', '\r'], " ")
        );
        let effects = policy.child_exited(started_at, origin.elapsed(), status.success(), reason);
        for effect in effects {
            match effect {
                Effect::Wait(delay) => {
                    let mut terminate = signal(SignalKind::terminate())
                        .map_err(|error| format!("could not install SIGTERM handler: {error}"))?;
                    if let Ok(received) = timeout(delay, terminate.recv()).await {
                        if received.is_none() {
                            return Err("SIGTERM handler closed unexpectedly".to_owned());
                        }
                        println!("rime-event daemon-stop reason=sigterm-during-backoff");
                        return Ok(());
                    }
                }
                Effect::Start(next) => {
                    println!("rime-event transition next={}", kind_name(next));
                }
            }
        }
    }
}

enum ChildEvent {
    Exited(io::Result<ExitStatus>),
    Terminate(Option<()>),
}

enum WaitOutcome {
    Exited(ExitStatus),
    Terminated,
}

async fn wait_for_child_or_signal(mut child: Child, child_pid: u32) -> Result<WaitOutcome, String> {
    let mut terminate = signal(SignalKind::terminate())
        .map_err(|error| format!("could not install SIGTERM handler: {error}"))?;
    match wait_for_child_or_termination(&mut child, terminate.recv()).await {
        ChildEvent::Exited(result) => {
            let status = validate_wait_result(child_pid, result)?;
            Ok(WaitOutcome::Exited(status))
        }
        ChildEvent::Terminate(Some(())) => {
            let result = terminate_and_reap(child_pid, &mut child).await?;
            println!(
                "rime-event child-stop pid={child_pid} forced={} wait={}",
                result.forced,
                wait_result_name(result.status)
            );
            Ok(WaitOutcome::Terminated)
        }
        ChildEvent::Terminate(None) => Err("SIGTERM handler closed unexpectedly".to_owned()),
    }
}

async fn wait_for_child_or_termination<F>(child: &mut Child, termination: F) -> ChildEvent
where
    F: Future<Output = Option<()>>,
{
    // one task retains the child handle so a reaped pid can never be signalled
    let mut child_wait = Box::pin(child.wait());
    let mut termination = Box::pin(termination);
    poll_fn(|context| {
        if let Poll::Ready(result) = child_wait.as_mut().poll(context) {
            return Poll::Ready(ChildEvent::Exited(result));
        }
        if let Poll::Ready(result) = termination.as_mut().poll(context) {
            return Poll::Ready(ChildEvent::Terminate(result));
        }
        Poll::Pending
    })
    .await
}

#[derive(Debug)]
struct ShutdownResult {
    forced: bool,
    status: ExitStatus,
}

async fn terminate_and_reap(child_pid: u32, child: &mut Child) -> Result<ShutdownResult, String> {
    let raw_pid = i32::try_from(child_pid).map_err(|_| format!("invalid child pid {child_pid}"))?;
    let pid = Pid::from_raw(raw_pid);
    let mut policy = ShutdownPolicy::default();
    let mut effects = VecDeque::from(policy.transition(ShutdownEvent::Requested));
    let mut observed_status = None;

    loop {
        let effect = effects
            .pop_front()
            .ok_or_else(|| "shutdown policy stopped before exit".to_owned())?;
        match effect {
            ShutdownEffect::Terminate => kill(pid, Signal::SIGTERM)
                .map_err(|error| format!("could not terminate view {child_pid}: {error}"))?,
            ShutdownEffect::WaitForReap(grace) => match timeout(grace, child.wait()).await {
                Ok(result) => {
                    observed_status = Some(validate_wait_result(child_pid, result)?);
                    effects.extend(policy.transition(ShutdownEvent::Reaped));
                }
                Err(_) => effects.extend(policy.transition(ShutdownEvent::Deadline)),
            },
            ShutdownEffect::Kill => child
                .start_kill()
                .map_err(|error| format!("could not kill view {child_pid}: {error}"))?,
            ShutdownEffect::Reap => {
                // the same child handle supplies the forced wait result before shutdown can exit
                observed_status = Some(validate_wait_result(child_pid, child.wait().await)?);
                effects.extend(policy.transition(ShutdownEvent::Reaped));
            }
            ShutdownEffect::Exit => {
                let status = observed_status
                    .ok_or_else(|| "shutdown exited without a child wait result".to_owned())?;
                return Ok(ShutdownResult {
                    forced: policy.forced(),
                    status,
                });
            }
        }
    }
}

fn validate_wait_result(
    child_pid: u32,
    result: io::Result<ExitStatus>,
) -> Result<ExitStatus, String> {
    result.map_err(|error| format!("could not reap view {child_pid}: {error}"))
}

fn wait_result_name(status: ExitStatus) -> String {
    if let Some(code) = status.code() {
        format!("exit-{code}")
    } else if let Some(signal) = status.signal() {
        format!("signal-{signal}")
    } else {
        "unknown".to_owned()
    }
}

fn exit_reason(kind: ViewKind, status: ExitStatus) -> String {
    let label = match kind {
        ViewKind::Normal => "normal view",
        ViewKind::Safe => "safe view",
    };
    if let Some(code) = status.code() {
        format!("{label} exited with code {code}")
    } else if let Some(signal) = status.signal() {
        format!("{label} terminated by signal {signal}")
    } else {
        format!("{label} exited without a status")
    }
}

fn kind_name(kind: ViewKind) -> &'static str {
    match kind {
        ViewKind::Normal => "normal",
        ViewKind::Safe => "safe",
    }
}

#[must_use]
pub fn cpu_percent(delta_ticks: u32, ticks_per_second: u32, elapsed: Duration) -> f64 {
    if ticks_per_second == 0 || elapsed.is_zero() {
        return f64::INFINITY;
    }
    f64::from(delta_ticks) / f64::from(ticks_per_second) / elapsed.as_secs_f64() * 100.0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn crash(policy: &mut Policy, started: u64, exited_ms: u64, reason: &str) -> Vec<Effect> {
        policy.child_exited(
            Duration::from_millis(started),
            Duration::from_millis(exited_ms),
            false,
            reason.to_owned(),
        )
    }

    #[test]
    fn five_failures_inside_window_enter_safe_mode() {
        let mut policy = Policy::default();
        for at in [0, 4_000, 8_000, 12_000] {
            let _ = crash(&mut policy, at, at, "failed");
        }
        let effects = crash(&mut policy, 19_999, 19_999, "last failure");
        assert_eq!(effects, vec![Effect::Start(ViewKind::Safe)]);
        assert_eq!(policy.kind(), ViewKind::Safe);
        assert_eq!(policy.latest_normal_reason(), Some("last failure"));
    }

    #[test]
    fn failure_at_window_boundary_drops_oldest() {
        let mut policy = Policy::default();
        for at in [0, 4_000, 8_000, 12_000] {
            let _ = crash(&mut policy, at, at, "failed");
        }
        let effects = crash(&mut policy, 20_000, 20_000, "boundary");
        assert_eq!(effects.last(), Some(&Effect::Start(ViewKind::Normal)));
        assert_eq!(policy.kind(), ViewKind::Normal);
    }

    #[test]
    fn backoff_is_bounded() {
        let mut policy = Policy::default();
        for (index, expected) in BACKOFF.into_iter().enumerate() {
            let at = u64::try_from(index).unwrap() * 20_000;
            let effects = crash(&mut policy, at, at, "failed");
            assert_eq!(effects[0], Effect::Wait(expected));
        }
        let effects = crash(&mut policy, 100_000, 100_000, "failed");
        assert_eq!(effects[0], Effect::Wait(Duration::from_secs(1)));
    }

    #[test]
    fn clean_uptime_resets_backoff_at_exact_boundary() {
        let mut policy = Policy::default();
        let _ = crash(&mut policy, 0, 0, "first");
        let effects = crash(&mut policy, 1_000, 31_000, "after clean uptime");
        assert_eq!(effects[0], Effect::Wait(Duration::from_millis(100)));
    }

    #[test]
    fn one_millisecond_short_of_clean_uptime_does_not_reset() {
        let mut policy = Policy::default();
        let _ = crash(&mut policy, 0, 0, "first");
        let effects = crash(&mut policy, 1_000, 30_999, "still dirty");
        assert_eq!(effects[0], Effect::Wait(Duration::from_millis(200)));
    }

    #[test]
    fn safe_failures_preserve_normal_reason_and_mode() {
        let mut policy = Policy::default();
        for at in [0, 1, 2, 3, 4] {
            let _ = crash(&mut policy, at, at, "normal reason");
        }
        let effects = policy.child_exited(
            Duration::from_millis(5),
            Duration::from_millis(6),
            false,
            "safe reason".to_owned(),
        );
        assert_eq!(effects.last(), Some(&Effect::Start(ViewKind::Safe)));
        assert_eq!(policy.latest_normal_reason(), Some("normal reason"));
    }

    #[test]
    fn clean_safe_exit_reloads_normal_immediately() {
        let mut policy = Policy::default();
        for at in [0, 1, 2, 3, 4] {
            let _ = crash(&mut policy, at, at, "failed");
        }
        let effects = policy.child_exited(
            Duration::from_millis(5),
            Duration::from_millis(6),
            true,
            "safe exit".to_owned(),
        );
        assert_eq!(effects, vec![Effect::Start(ViewKind::Normal)]);
        assert_eq!(policy.kind(), ViewKind::Normal);
    }

    #[test]
    fn shutdown_before_deadline_exits_without_kill() {
        let mut policy = ShutdownPolicy::default();
        assert_eq!(
            policy.transition(ShutdownEvent::Requested),
            vec![
                ShutdownEffect::Terminate,
                ShutdownEffect::WaitForReap(SHUTDOWN_GRACE),
            ]
        );
        assert_eq!(
            policy.transition(ShutdownEvent::Reaped),
            vec![ShutdownEffect::Exit]
        );
        assert!(!policy.forced());
    }

    #[test]
    fn shutdown_deadline_forces_kill_then_reap() {
        let mut policy = ShutdownPolicy::default();
        let _ = policy.transition(ShutdownEvent::Requested);
        assert_eq!(
            policy.transition(ShutdownEvent::Deadline),
            vec![ShutdownEffect::Kill, ShutdownEffect::Reap]
        );
        assert_eq!(
            policy.transition(ShutdownEvent::Reaped),
            vec![ShutdownEffect::Exit]
        );
        assert!(policy.forced());
    }

    #[test]
    fn exited_child_wins_ready_termination_without_pid_race() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async {
            let mut child = Command::new("sh").arg("-c").arg("exit 23").spawn().unwrap();
            let child_pid = child.id().unwrap();
            let proc_path = PathBuf::from(format!("/proc/{child_pid}"));

            for _ in 0..100 {
                let is_zombie = fs::read_to_string(proc_path.join("stat"))
                    .is_ok_and(|stat| stat.contains(") Z "));
                if is_zombie {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            assert!(
                fs::read_to_string(proc_path.join("stat")).is_ok_and(|stat| stat.contains(") Z "))
            );

            let event = timeout(
                Duration::from_secs(1),
                wait_for_child_or_termination(&mut child, std::future::ready(Some(()))),
            )
            .await
            .expect("child and termination selection hung");
            let status = match event {
                ChildEvent::Exited(result) => result.expect("child wait result was lost"),
                ChildEvent::Terminate(_) => panic!("termination won after the child had exited"),
            };
            eprintln!(
                "exit-signal race result wait={} termination_selected=false reaped={}",
                wait_result_name(status),
                !proc_path.exists()
            );
            assert_eq!(status.code(), Some(23));
            assert!(!proc_path.exists());
            assert_eq!(child.wait().await.unwrap().code(), Some(23));
        });
    }

    #[test]
    fn forced_kill_reaps_sigterm_ignoring_child() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async {
            let nonce = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos();
            let marker = std::env::temp_dir().join(format!(
                "rime-supervise-ignore-term-{}-{nonce}",
                std::process::id()
            ));
            let mut command = Command::new("sh");
            command
                .arg("-c")
                .arg("trap '' TERM; : > \"$1\"; exec sleep 3600")
                .arg("sh")
                .arg(&marker)
                .kill_on_drop(true);
            let mut child = command.spawn().unwrap();
            let child_pid = child.id().unwrap();

            for _ in 0..100 {
                if marker.exists() {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            assert!(marker.exists());

            let result = terminate_and_reap(child_pid, &mut child).await.unwrap();
            let wait_result = wait_result_name(result.status);
            eprintln!(
                "forced-kill wait result forced={} wait={wait_result}",
                result.forced
            );
            assert!(result.forced);
            assert_eq!(result.status.signal(), Some(9));
            assert!(!PathBuf::from(format!("/proc/{child_pid}")).exists());
            let _ = fs::remove_file(marker);
        });
    }

    #[test]
    fn cpu_calculation_has_a_red_path() {
        assert!((cpu_percent(5, 100, Duration::from_secs(10)) - 0.5).abs() < f64::EPSILON);
        assert!(cpu_percent(6, 100, Duration::from_secs(10)) > 0.5);
    }
}
