#!/usr/bin/env nu

def main [message_file: path] {
  let subject = (open --raw $message_file | lines | first | str trim)
  let pattern = '^[a-z0-9][a-z0-9._/-]*(\([a-z0-9._/-]+\))?!?: [a-z0-9].{1,71}$'
  if not ($subject =~ $pattern) {
    print --stderr "commit subject must be lowercase and use file: message form"
    exit 1
  }
}
