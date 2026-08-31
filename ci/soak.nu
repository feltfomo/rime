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

def run-checked [command: string, args: list<string>] {
  let result = (run-external $command ...$args | complete)
  if $result.exit_code != 0 {
    print --stderr $result.stderr
    exit $result.exit_code
  }
  $result.stdout | str trim
}

def main [--nested] {
  if $nested {
    print --stderr "nested verification is unavailable until SP1 adds the supervised view"
    exit 1
  }

  let root = (repo-root)
  let log_dir = ($root | path join "soak-logs")
  mkdir $log_dir

  let daemon = (run-checked "cargo" ["run" "--quiet" "-p" "rimed"])
  let control = (run-checked "cargo" ["run" "--quiet" "-p" "rimectl"])
  let report = {
    registered_surfaces: 0
    cycles: 0
    daemon: $daemon
    control: $control
  }
  $report | to json | save --force ($log_dir | path join "sp0.json")

  # zero cycles is honest until a surface registry exists
  if $report.registered_surfaces != 0 or $report.cycles != 0 {
    print --stderr "the zero-surface gate reported impossible state"
    exit 1
  }
  print "zero registered surfaces; zero lifecycle cycles"
}
