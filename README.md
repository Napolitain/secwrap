# secwrap

`secwrap` is a small Linux command launcher that installs a seccomp filter and
then `exec`s another command.

It is intended for interactive shell defaults such as:

```sh
secwrap --profile local-cli -- eza -la
secwrap --profile monitor -- btop
```

For NixOS systems, `secwrap` also exports a wrapper generator for creating
recursion-safe command shims. A shim can run AppArmor first, then install the
seccomp filter, then `exec` the real command by absolute path.

## Profiles

- `local-cli`: deny IPv4, IPv6, and netlink socket creation, plus risky
  administration/introspection syscalls.
- `monitor`: same as `local-cli`, but allows netlink so tools such as `btop`
  can read interface statistics.
- `broken-ls` / `strict-test`: deny `getdents64`, which should break directory
  listing tools. This profile exists to prove that the wrapper is active.

The filter is default-allow in v1. This keeps ordinary utilities compatible
while denying selected syscall families that should not be needed.

`secwrap` is not a filesystem sandbox. Use AppArmor or another LSM for path and
device policy such as blocking `~/.ssh`, `~/Repos`, camera, or microphone
access.

## Usage

```sh
secwrap --profile local-cli -- rg needle
secwrap --profile monitor -- btop
secwrap --profile broken-ls -- ls .
secwrap --profile local-cli --target /run/current-system/sw/bin/ls --argv0 ls -- -la
secwrap --profile local-cli --deny-syscall ptrace -- eza -la
```

The command fails closed: if argument parsing, `no_new_privs`, or seccomp filter
installation fails, the target command is not executed.

`--target` must be an absolute path and uses `execv`, so generated shims do not
look up the target through `PATH`. `--argv0` is useful for multicall packages
such as GNU Coreutils where the invoked name selects behavior.

## Nix wrapper helper

The flake exports `lib.x86_64-linux.makeSecwrapWrappers`. Example:

```nix
let
  secwrap = inputs.secwrap;
  wrappers = secwrap.lib.x86_64-linux.makeSecwrapWrappers {
    tools = [
      {
        name = "ls";
        profile = "local-cli";
        target = "${pkgs.coreutils-full}/bin/ls";
        argv0 = "ls";
        apparmorProfile = "coreutils-ls";
      }
      {
        name = "broken-ls";
        profile = "broken-ls";
        target = "${pkgs.coreutils-full}/bin/ls";
        argv0 = "ls";
      }
    ];
  };
in
{
  environment.systemPackages = [
    (lib.hiPrio wrappers)
  ];
}
```

When `apparmorProfile` is set, the generated shim runs:

```sh
aa-exec -p <profile> -- secwrap --profile <secwrap-profile> --target <target> --argv0 <argv0> -- "$@"
```

Without `apparmorProfile`, it runs `secwrap` directly.

## Build

```sh
nix build
nix develop
zig build test
```
