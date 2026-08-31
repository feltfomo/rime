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
  let shader_root = ($root | path join "shell/shaders")
  if not ($shader_root | path exists) {
    print "shader sources absent; generated shader output remains empty"
    return
  }

  let shaders = (glob ($shader_root | path join "**/*.{frag,vert,glsl}") --no-dir)
  if ($shaders | is-empty) {
    print "zero shader sources found"
    return
  }

  # source arrival without an explicit output contract is a hard failure
  print --stderr "shader sources exist but shader output mapping is not configured"
  exit 1
}