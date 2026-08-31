{ lib, rustPlatform }:
let
  # both consumers call this file so package behaviour has one owner
  mkRimePackage =
    pname:
    rustPlatform.buildRustPackage {
      inherit pname;
      version = "0.1.0";
      src = lib.cleanSource ./.;
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
  rimed = mkRimePackage "rimed";
  rimectl = mkRimePackage "rimectl";
}
