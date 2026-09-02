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

def relative [root: path, file: path] {
  $file | path relative-to $root
}

def qml-check [root: path] {
  let files = (glob ($root | path join "**/*.qml") --no-dir)
  mut failures = []
  for file in $files {
    let result = (^qmllint $file | complete)
    if $result.exit_code != 0 {
      $failures = ($failures | append $"(relative $root $file)
($result.stderr)")
    }
  }
  $failures
}

def architecture-check [root: path] {
  let files = (glob ($root | path join "**/*") --no-dir | where {|path|
    let rel = (relative $root $path)
    let ignored = ([
      ($rel starts-with ".git/")
      ($rel starts-with ".devenv/")
      ($rel starts-with ".direnv/")
      ($rel starts-with "target/")
    ] | any {|candidate| $candidate })
    not $ignored
  })
  mut failures = []

  for file in $files {
    let rel = (relative $root $file)
    let text = (open --raw $file)

    if ($rel ends-with ".qml") {
      for banned in ["layer.enabled" "MultiEffect" "Canvas" "Shape"] {
        if ($text | str contains $banned) {
          $failures = ($failures | append $"($rel) uses banned rendering construct ($banned)")
        }
      }
      if ($text | str contains "Quickshell.env") and $rel != "shell/safe.qml" {
        $failures = ($failures | append $"($rel) reads process environment outside the safe view")
      }
    }

    if $rel == "shell/safe.qml" {
      for banned in ["Rectangle" "QtQuick.Controls" "Process" "FileView" "Socket" "DBus"] {
        if ($text | str contains $banned) {
          $failures = ($failures | append $"($rel) uses prohibited bootstrap construct ($banned)")
        }
      }
      if not ($text | str contains 'Quickshell.env("RIME_CRASH_REASON")') {
        $failures = ($failures | append "shell/safe.qml does not display the supervisor crash reason")
      }
      if not ($text | str contains "Qt.quit()") {
        $failures = ($failures | append "shell/safe.qml does not expose the reload exit action")
      }
    }

    if ($rel starts-with "crates/rime-protocol/") or ($rel starts-with "crates/rime-ipc/") or ($rel starts-with "shell/proto/") {
      $failures = ($failures | append $"($rel) introduces protocol work before its owning phase")
    }

    if ($rel starts-with "shell/surfaces/") {
      for banned in ["Process" "FileView" "Socket" "DBus" "XmlListModel"] {
        if ($text | str contains $banned) {
          $failures = ($failures | append $"($rel) imports or uses io construct ($banned)")
        }
      }
      if (($text | lines | length) > 300) {
        $failures = ($failures | append $"($rel) exceeds the 300-line surface budget")
      }
    }

    # hexadecimal colors belong in token definitions rather than other source files
    if not ($rel starts-with "shell/tokens/") and ($text =~ '(?i)#[0-9a-f]{3,8}\b') {
      $failures = ($failures | append $"($rel) contains a hex color outside the token layer")
    }

    if ($rel ends-with ".rs") and ($text =~ '\bunsafe\b') {
      $failures = ($failures | append $"($rel) contains unsafe rust outside the empty allowlist")
    }

    # plugin code cannot exist until the escalation record is part of the source tree
    if ($rel starts-with "plugin/") {
      $failures = ($failures | append $"($rel) exists without a recorded plugin escalation")
    }
  }
  $failures
}

def protocol-prefix-probe [] {
  let root = (^mktemp --directory | str trim)
  let expected = [
    "crates/rime-protocol/src/lib.rs"
    "crates/rime-ipc/src/lib.rs"
    "shell/proto/generated.qml"
  ]
  for rel in $expected {
    let file = ($root | path join $rel)
    mkdir ($file | path dirname)
    "probe" | save $file
  }
  let detected = (architecture-check $root)
  rm --recursive --force $root

  mut failures = []
  for rel in $expected {
    if not ($detected | any {|failure| $failure | str starts-with $"($rel) introduces protocol work" }) {
      $failures = ($failures | append $"protocol prefix probe missed ($rel)")
    }
  }
  $failures
}

def main [--qml-only, --protocol-probe] {
  let root = (repo-root)
  let failures = if $qml_only {
    qml-check $root
  } else if $protocol_probe {
    protocol-prefix-probe
  } else {
    (architecture-check $root) | append (protocol-prefix-probe)
  }

  if ($failures | is-not-empty) {
    $failures | each {|failure| print --stderr $failure }
    exit 1
  }
  if $protocol_probe {
    print "protocol prefix probe rejected crates/rime-protocol/src/lib.rs"
    print "protocol prefix probe rejected crates/rime-ipc/src/lib.rs"
    print "protocol prefix probe rejected shell/proto/generated.qml"
  }
}
