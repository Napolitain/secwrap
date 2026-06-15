# secwrap

`secwrap` is a small Linux command launcher that installs a seccomp filter and
then `exec`s another command.

It is intended for interactive shell defaults such as:

```sh
alias ls='secwrap --profile local-cli -- eza'
alias btop='secwrap --profile monitor -- btop'
```

## Profiles

- `local-cli`: deny IPv4, IPv6, and netlink socket creation, plus risky
  administration/introspection syscalls.
- `monitor`: same as `local-cli`, but allows netlink so tools such as `btop`
  can read interface statistics.
- `strict-test`: deny `getdents64`, which should break directory listing tools.
  This profile exists to prove that the wrapper is active.

The filter is default-allow in v1. This keeps ordinary utilities compatible
while denying selected syscall families that should not be needed.

`secwrap` is not a filesystem sandbox. Use AppArmor or another LSM for path and
device policy such as blocking `~/.ssh`, `~/Repos`, camera, or microphone
access.

## Usage

```sh
secwrap --profile local-cli -- rg needle
secwrap --profile monitor -- btop
secwrap --profile local-cli --deny-syscall ptrace -- eza -la
```

The command fails closed: if argument parsing, `no_new_privs`, or seccomp filter
installation fails, the target command is not executed.

## Build

```sh
nix build
nix develop
zig build test
```
