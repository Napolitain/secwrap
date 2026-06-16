{
  description = "Small seccomp command wrapper";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      inherit (pkgs) lib;

      secwrapPackage = pkgs.stdenv.mkDerivation {
        pname = "secwrap";
        version = "0.1.0";
        src = ./.;

        nativeBuildInputs = [
          pkgs.pkg-config
          pkgs.zig
        ];

        buildInputs = [
          pkgs.libseccomp
        ];

        dontConfigure = true;

        buildPhase = ''
          runHook preBuild
          export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
          zig build -Doptimize=ReleaseSafe --prefix "$out"
          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          runHook postInstall
        '';

        doCheck = true;
        checkPhase = ''
          runHook preCheck
          export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
          zig build test
          runHook postCheck
        '';

        meta = {
          description = "Small seccomp command wrapper";
          homepage = "https://github.com/Napolitain/secwrap";
          license = lib.licenses.mit;
          mainProgram = "secwrap";
          platforms = lib.platforms.linux;
        };
      };

      makeSecwrapWrappers =
        {
          name ? "secwrap-wrappers",
          secwrap ? secwrapPackage,
          tools,
        }:
        pkgs.runCommand name { } (
          ''
            mkdir -p "$out/bin"
          ''
          + lib.concatMapStringsSep "\n" (
            tool:
            let
              outputName = tool.outputName or tool.name;
              argv0 = tool.argv0 or tool.name;
              extraArgs = tool.extraSecwrapArgs or [ ];
              apparmorPrefix =
                if tool ? apparmorProfile then
                  "${pkgs.apparmor-bin-utils}/bin/aa-exec -p ${lib.escapeShellArg tool.apparmorProfile} -- "
                else
                  "";
              secwrapArgs =
                [
                  "--profile"
                  tool.profile
                ]
                ++ extraArgs
                ++ [
                  "--target"
                  tool.target
                  "--argv0"
                  argv0
                  "--"
                ];
            in
            ''
              cat > "$out/bin/${outputName}" <<'EOF'
              #!${pkgs.runtimeShell}
              exec ${apparmorPrefix}${secwrap}/bin/secwrap ${lib.escapeShellArgs secwrapArgs} "$@"
              EOF
              chmod +x "$out/bin/${outputName}"
            ''
          ) tools
        );
    in
    {
      lib.${system} = {
        inherit makeSecwrapWrappers;
      };

      packages.${system} = {
        default = secwrapPackage;

        example-wrappers = makeSecwrapWrappers {
          name = "secwrap-example-wrappers";
          tools = [
            {
              name = "broken-ls";
              profile = "broken-ls";
              target = "${pkgs.coreutils-full}/bin/ls";
              argv0 = "ls";
            }
            {
              name = "protected-ls";
              profile = "local-cli";
              target = "${pkgs.coreutils-full}/bin/ls";
              argv0 = "ls";
            }
          ];
        };
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.libseccomp
          pkgs.pkg-config
          pkgs.zig
        ];
      };
    };
}
