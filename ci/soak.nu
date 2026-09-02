#!/usr/bin/env nu

def repo-root [] {
  mut current = ($env.PWD | path expand)
  loop {
    if (($current | path join "Cargo.toml") | path exists) { return $current }
    let parent = ($current | path dirname)
    if $parent == $current { error make {msg: "could not find repository root"} }
    $current = $parent
  }
}

def wait-for [path: path, needle: string] {
  for _ in 1..100 {
    if ($path | path exists) and ((open --raw $path) | str contains $needle) { return }
    sleep 100ms
  }
  error make {msg: $"timed out waiting for ($needle) in ($path)"}
}

def wait-count [path: path, needle: string, expected: int] {
  for _ in 1..100 {
    if ($path | path exists) {
      let count = (open --raw $path | lines | where {|line| $line | str contains $needle } | length)
      if $count >= $expected { return }
    }
    sleep 100ms
  }
  error make {msg: $"timed out waiting for ($expected) occurrences of ($needle) in ($path)"}
}

# structured daemon events identify this run's children without global name matching
def latest-pid [path: path, kind: string] {
  open --raw $path
  | lines
  | where {|line| ($line | str contains "child-start") and ($line | str contains $"kind=($kind)") }
  | last
  | parse --regex 'pid=(?<pid>[0-9]+)'
  | first
  | get pid
  | into int
}

def process-ticks [pid: int] {
  let fields = (open --raw $"/proc/($pid)/stat" | split row " ")
  (($fields | get 13 | into int) + ($fields | get 14 | into int))
}

def package-path [root: path, package: string] {
  # staged path input includes untracked source without private tool directories
  let source = (^mktemp --directory | str trim)
  for relative in ["Cargo.toml" "Cargo.lock" "flake.nix" "flake.lock" "package.nix" "crates" "shell" "nix"] {
    cp --recursive ($root | path join $relative) $source
  }
  let installable = $"path:($source)#($package)"
  let built = (^nix build $installable --print-out-paths --no-link | complete)
  rm --recursive --force $source
  if $built.exit_code != 0 { error make {msg: $built.stderr} }
  $built.stdout | lines | last | str trim
}

def verify-package [root: path] {
  let package = (package-path $root "rimed")
  for relative in ["bin/rimed" "share/rime/shell/shell.qml" "share/rime/shell/safe.qml" "lib/systemd/user/rime.service"] {
    let target = ($package | path join $relative)
    if not ($target | path exists) { error make {msg: $"packaged path is missing ($target)"} }
  }
  let unit = (open --raw ($package | path join "lib/systemd/user/rime.service"))
  for required in ["Type=simple" "PartOf=graphical-session.target" "WantedBy=graphical-session.target" "Restart=on-failure"] {
    if not ($unit | str contains $required) { error make {msg: $"packaged unit is missing ($required)"} }
  }
  $package
}

def build-packages [root: path] {
  for package in ["rimed" "rimectl"] {
    package-path $root $package | ignore
  }
}

def nested-environment [runtime: path] {
  {
    XDG_RUNTIME_DIR: ($runtime | into string)
    WLR_BACKENDS: "headless"
    WLR_HEADLESS_OUTPUTS: "2"
    WLR_LIBINPUT_NO_DEVICES: "1"
  }
}

def start-compositor [runtime: path, log: path, pid_file: path] {
  let variables = (nested-environment $runtime)
  job spawn --description rime-labwc {
    with-env $variables { ^sh -c 'echo "$$" > "$1"; exec labwc' sh $pid_file out+err> $log }
  }
}

def wayland-display [runtime: path] {
  for _ in 1..100 {
    let sockets = (glob ($runtime | path join "wayland-*") | where {|path| not (($path | into string) | str ends-with ".lock") })
    if ($sockets | is-not-empty) { return ($sockets | first | path basename) }
    sleep 100ms
  }
  error make {msg: "labwc did not create a wayland socket"}
}

def start-daemon [root: path, runtime: path, display: string, log: path, pid_file: path] {
  let variables = {
    XDG_RUNTIME_DIR: ($runtime | into string)
    WAYLAND_DISPLAY: $display
    RIME_QUICKSHELL: ($env.RIME_QUICKSHELL)
    RIME_SHELL_DIR: ($root | path join "shell" | into string)
  }
  let daemon = ($root | path join "target/debug/rimed")
  job spawn --description rime-daemon {
    with-env $variables { ^sh -c 'echo "$$" > "$1"; exec "$2"' sh $pid_file $daemon out+err> $log }
  }
}

def stop-job [id: int] {
  try { job kill $id }
}

def stop-process [pid_file: path] {
  if not ($pid_file | path exists) { return }
  let pid = (open --raw $pid_file | str trim | into int)
  let proc_path = $"/proc/($pid)"
  if not ($proc_path | path exists) { return }
  do -i { ^kill -TERM $pid }
  for _ in 1..20 {
    if not ($proc_path | path exists) { return }
    sleep 50ms
  }
  do -i { ^kill -KILL $pid }
}

def process-exists [pid: int] {
  ($"/proc/($pid)" | path exists)
}

def wait-processes-gone [pids: list<int>] {
  for _ in 1..100 {
    if ($pids | all {|pid| not (process-exists $pid) }) { return }
    sleep 100ms
  }
  let live = ($pids | where {|pid| process-exists $pid })
  error make {msg: $"processes survived service cleanup ($live)"}
}

def service-state [] {
  for _ in 1..100 {
    let daemon_text = (^systemctl --user show rime.service --property MainPID --value | str trim)
    if $daemon_text != "" and $daemon_text != "0" {
      let daemon = ($daemon_text | into int)
      let children_file = $"/proc/($daemon)/task/($daemon)/children"
      if ($children_file | path exists) {
        let children = (open --raw $children_file | split row " " | where {|pid| ($pid | str trim) != "" } | each {|pid| $pid | into int })
        if ($children | length) == 1 and (process-exists ($children | first)) {
          return {daemon: $daemon, child: ($children | first)}
        }
        if ($children | length) > 1 {
          error make {msg: $"service daemon ($daemon) has multiple supervised children ($children)"}
        }
      }
    }
    sleep 100ms
  }
  error make {msg: "service did not reach one daemon and one supervised child"}
}

def systemd-test [root: path] {
  let package = (verify-package $root)
  let unit = ($package | path join "lib/systemd/user/rime.service")
  # the runtime link exercises the packaged unit without persistent user configuration
  let linked = (^systemctl --user link --runtime $unit | complete)
  if $linked.exit_code != 0 { error make {msg: $linked.stderr} }
  try {
    ^systemctl --user daemon-reload
    ^systemctl --user start rime.service
    let before = (service-state)
    print $"systemd before restart daemon=($before.daemon) child=($before.child)"

    ^systemctl --user restart rime.service
    wait-processes-gone [$before.daemon $before.child]
    let after = (service-state)
    if $before.daemon == $after.daemon or $before.child == $after.child {
      error make {msg: "systemd restart reused a recorded process identity"}
    }
    print $"systemd after restart daemon=($after.daemon) child=($after.child) old_gone=true"

    ^systemctl --user stop rime.service
    wait-processes-gone [$before.daemon $before.child $after.daemon $after.child]
    print $"systemd after stop old_daemon=gone old_child=gone new_daemon=gone new_child=gone"
  } catch {|failure|
    try { ^systemctl --user stop rime.service }
    try { ^systemctl --user disable --runtime rime.service }
    error make {msg: $failure.msg}
  }
  try { ^systemctl --user disable --runtime rime.service }
}

def run-nested [root: path, interactive: bool] {
  let build = (^cargo build --workspace | complete)
  if $build.exit_code != 0 { error make {msg: $build.stderr} }

  let runtime = (^mktemp --directory | str trim)
  chmod 700 $runtime
  let log_dir = ($root | path join "soak-logs")
  mkdir $log_dir
  let labwc_log = ($log_dir | path join "labwc.log")
  let daemon_log = ($log_dir | path join "rimed.log")
  let labwc_pid_file = ($runtime | path join "labwc.pid")
  let daemon_pid_file = ($runtime | path join "rimed.pid")
  let compositor_job = (start-compositor $runtime $labwc_log $labwc_pid_file)
  let setup = try {
    let display = (wayland-display $runtime)
    let variables = ((nested-environment $runtime) | merge {WAYLAND_DISPLAY: $display})
    let output_text = (with-env $variables { ^wlr-randr })
    let outputs = ($output_text | lines | where {|line| ($line | str trim) != "" and not ($line | str starts-with " ") } | length)
    if $outputs != 2 { error make {msg: $"nested compositor reported ($outputs) outputs"} }
    {display: $display, outputs: $outputs}
  } catch {|failure|
    stop-process $labwc_pid_file
    stop-job $compositor_job
    rm --recursive --force $runtime
    error make {msg: $failure.msg}
  }
  let display = $setup.display
  let outputs = $setup.outputs
  let daemon_job = (start-daemon $root $runtime $display $daemon_log $daemon_pid_file)

  try {
    wait-for $daemon_log "child-start kind=normal"

    if $interactive {
      input $"nested rime running on ($display); press Enter to stop"
      stop-process $daemon_pid_file
      stop-process $labwc_pid_file
      stop-job $daemon_job
      stop-job $compositor_job
      rm --recursive --force $runtime
      return
    }

    let daemon_pid = (open --raw $daemon_log | lines | where {|line| $line | str contains "daemon-start" } | first | parse --regex 'pid=(?<pid>[0-9]+)' | first | get pid | into int)
    let view_pid = (latest-pid $daemon_log "normal")
    sleep 2sec
    let daemon_before = (process-ticks $daemon_pid)
    let view_before = (process-ticks $view_pid)
    let timing = (timeit --output { sleep 10sec })
    let elapsed = $timing.time
    let elapsed_seconds = ($elapsed / 1sec)
    let daemon_after = (process-ticks $daemon_pid)
    let view_after = (process-ticks $view_pid)
    let delta = (($daemon_after - $daemon_before) + ($view_after - $view_before))
    let ticks_per_second = (^getconf CLK_TCK | str trim | into int)
    let cpu = (($delta | into float) / ($ticks_per_second | into float) / $elapsed_seconds * 100.0)
    if $cpu > 0.5 { error make {msg: $"idle cpu ($cpu)% exceeded 0.5%"} }

    for crash in 1..5 {
      let pid = (latest-pid $daemon_log "normal")
      ^kill -KILL $pid
      if $crash < 5 { wait-count $daemon_log "child-start kind=normal" ($crash + 1) }
    }
    wait-count $daemon_log "child-start kind=safe" 1
    let safe_pid = (latest-pid $daemon_log "safe")
    let normal_starts = (open --raw $daemon_log | lines | where {|line| $line | str contains "child-start kind=normal" } | length)
    with-env {XDG_RUNTIME_DIR: ($runtime | into string), WAYLAND_DISPLAY: $display} { ^quickshell kill --pid $safe_pid }
    wait-count $daemon_log "child-start kind=normal" ($normal_starts + 1)

    let duplicate = (with-env {XDG_RUNTIME_DIR: ($runtime | into string), WAYLAND_DISPLAY: $display, RIME_QUICKSHELL: $env.RIME_QUICKSHELL, RIME_SHELL_DIR: ($root | path join "shell" | into string)} { ^($root | path join "target/debug/rimed") | complete })
    if $duplicate.exit_code == 0 or not ($duplicate.stderr | str contains "rimed is already running") {
      error make {msg: "second daemon was not rejected by the advisory lock"}
    }

    ^kill -TERM $daemon_pid
    wait-for $daemon_log "daemon-stop"
    let package = (verify-package $root)
    {
      outputs: $outputs
      daemon_pid: $daemon_pid
      view_pid: $view_pid
      daemon_ticks: ($daemon_after - $daemon_before)
      view_ticks: ($view_after - $view_before)
      elapsed_seconds: $elapsed_seconds
      cpu_percent: $cpu
      cpu_threshold: 0.5
      packaged_rimed: ($package | path join "bin/rimed")
    } | to json | save --force ($log_dir | path join "sp1.json")
    print $"supervision soak passed; idle cpu ($cpu)%"
  } catch {|failure|
    stop-process $daemon_pid_file
    stop-process $labwc_pid_file
    stop-job $daemon_job
    stop-job $compositor_job
    rm --recursive --force $runtime
    error make {msg: $failure.msg}
  }

  stop-process $daemon_pid_file
  stop-process $labwc_pid_file
  stop-job $daemon_job
  stop-job $compositor_job
  rm --recursive --force $runtime
}

def main [--nested, --systemd, --packages] {
  let root = (repo-root)
  if $packages {
    build-packages $root
  } else if $systemd {
    systemd-test $root
  } else {
    run-nested $root $nested
  }
}
