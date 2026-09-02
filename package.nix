{
  lib,
  makeWrapper,
  quickshell,
  rustPlatform,
}:
let
  common = pname: {
    inherit pname;
    version = "0.1.0";
    # local path input includes unstaged files while excluding private tool state
    src = builtins.path {
      path = ./.;
      name = "rime-source";
      filter =
        path: _:
        !(builtins.elem (baseNameOf path) [
          ".git"
          ".notion-sync"
        ]);
    };
    cargoLock.lockFile = ./Cargo.lock;
    cargoBuildFlags = [
      "-p"
      pname
    ];
    cargoTestFlags = [
      "-p"
      pname
    ];
    meta = {
      description = "rime ${pname} binary";
      license = with lib.licenses; [
        mit
        asl20
      ];
      mainProgram = pname;
      platforms = lib.platforms.linux;
    };
  };
in
{
  rimectl = rustPlatform.buildRustPackage (common "rimectl");

  rimed = rustPlatform.buildRustPackage (
    (common "rimed")
    // {
      nativeBuildInputs = [ makeWrapper ];
      # the package owns runtime assets and the unit while home manager only exposes them
      postInstall = ''
        install -Dm644 shell/shell.qml "$out/share/rime/shell/shell.qml"
        install -Dm644 shell/safe.qml "$out/share/rime/shell/safe.qml"
        install -Dm644 nix/rime.service "$out/lib/systemd/user/rime.service"
        substituteInPlace "$out/lib/systemd/user/rime.service" \
          --replace-fail '@RIMED@' "$out"
        wrapProgram "$out/bin/rimed" \
          --set RIME_QUICKSHELL "${lib.getExe quickshell}" \
          --set RIME_SHELL_DIR "$out/share/rime/shell"
      '';
    }
  );
}
