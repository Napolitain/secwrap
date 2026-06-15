{
  description = "Small seccomp command wrapper";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      packages.${system}.default = pkgs.stdenv.mkDerivation {
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
          license = pkgs.lib.licenses.mit;
          mainProgram = "secwrap";
          platforms = pkgs.lib.platforms.linux;
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
