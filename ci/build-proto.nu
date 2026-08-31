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

def main [] {
  let root = (repo-root)
  let sources = ($root | path join "crates/rime-protocol")
  if not ($sources | path exists) {
    print "protocol sources absent; generated protocol output remains empty"
    return
  }

  # a present source tree without its generator must fail instead of leaving stale output
  let result = (^cargo run --quiet -p rime-protocol --bin gen | complete)
  if $result.exit_code != 0 {
    print --stderr $result.stderr
    exit $result.exit_code
  }
}