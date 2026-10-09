## What this project is

Quay is a native macOS SSH connection manager (macOS 15+, Apple Silicon) built on top of `libghostty` — the core of the Ghostty terminal — without shipping Ghostty's full UI. Think Tabby-style connection manager UX on a Ghostty-speed terminal engine.

A tab is not always ssh. `TerminalSessionKind` is `.ssh` or `.sftp`, and an sftp
tab runs one of three clients (`SFTPClient`: macOS built-in `sftp`, Homebrew
OpenSSH `sftp`, or `lftp`) chosen by the user in Settings. Both enums live in
`Quay/PTY/SSHCommandBuilder.swift`. The kind decides the command line; the
*client* is what the session machinery has to care about, because the three
behave differently once connected — see "Client behaviour lives with the
client" below.
