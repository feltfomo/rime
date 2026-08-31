#!/usr/bin/env nu

def repo-root [] {
  mut current = ($env.PWD | path expand)
  loop {
    if (($current | path join "Cargo.toml") | path exists) {
      return $current
    }
    let parent = ($current | path dirname)
    if $parent == $current {
      error make {msg: "could not find repository root"}
    }
    $current = $parent
  }
}

def remove-temp [temp: path] {
  if ($temp | path exists) {
    rm --recursive --force $temp
  }
}

def main [] {
  let root = (repo-root)
  let created = (^mktemp --directory | complete)
  if $created.exit_code != 0 {
    print --stderr $created.stderr
    exit $created.exit_code
  }

  let temp = ($created.stdout | str trim)
  # format a temporary tracked-file tree so failed checks cannot rewrite source
  let outcome = (try {
    let listed = (^git -C $root ls-files -z | complete)
    if $listed.exit_code != 0 {
      error make {msg: $listed.stderr}
    }

    let paths = ($listed.stdout | split row (char nul) | where {|path| $path != "" })
    if ($paths | is-empty) {
      error make {msg: "git reported no tracked files"}
    }

    for rel in $paths {
      let source = ($root | path join $rel)
      if not ($source | path exists) {
        error make {msg: $"tracked file is missing ($rel)"}
      }
      let destination = ($temp | path join $rel)
      mkdir ($destination | path dirname)
      cp $source $destination
    }

    let formatted = (^treefmt --config-file ($temp | path join "treefmt.toml") --tree-root $temp --no-cache | complete)
    if $formatted.exit_code != 0 {
      {
        status: $formatted.exit_code
        formatter_failed: true
        stdout: $formatted.stdout
        stderr: $formatted.stderr
        changed: []
      }
    } else {
      mut changed = []
      for rel in $paths {
        let compared = (^cmp --silent ($root | path join $rel) ($temp | path join $rel) | complete)
        if $compared.exit_code == 1 {
          $changed = ($changed | append $rel)
        } else if $compared.exit_code != 0 {
          error make {msg: $"could not compare tracked file ($rel)"}
        }
      }
      {
        status: (if ($changed | is-empty) { 0 } else { 1 })
        formatter_failed: false
        stdout: $formatted.stdout
        stderr: $formatted.stderr
        changed: $changed
      }
    }
  } catch {|failure|
    {
      status: 1
      formatter_failed: true
      stdout: ""
      stderr: $failure.msg
      changed: []
    }
  })

  # the real tree stays untouched on every result path
  remove-temp $temp

  if ($outcome.stdout | str length) > 0 {
    print $outcome.stdout
  }
  if ($outcome.stderr | str length) > 0 {
    print --stderr $outcome.stderr
  }
  if ($outcome.changed | is-not-empty) {
    print --stderr "formatting differs"
    $outcome.changed | each {|path| print --stderr $path }
  }
  if $outcome.status != 0 {
    exit $outcome.status
  }
}