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

    # token definitions are the only source files allowed to carry literal colors
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

def main [--qml-only] {
  let root = (repo-root)
  let failures = if $qml_only {
    qml-check $root
  } else {
    architecture-check $root
  }

  if ($failures | is-not-empty) {
    $failures | each {|failure| print --stderr $failure }
    exit 1
  }
}
