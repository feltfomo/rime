{
  description = "rime packages";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          rimePackages = pkgs.callPackage ./package.nix { };
        in
        {
          default = rimePackages.rimed;
          inherit (rimePackages) rimed rimectl;
        }
      );

      homeManagerModules.rime = import ./nix/hm-module.nix;
      checks = forAllSystems (_: { });
      apps = forAllSystems (_: { });
    };
}
