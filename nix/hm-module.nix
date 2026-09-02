{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.rime;
  defaultPackage = (pkgs.callPackage ../package.nix { }).rimed;
in
{
  options.programs.rime = {
    enable = lib.mkEnableOption "rime desktop shell";
    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      description = "The rime daemon package.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];
    xdg.configFile."systemd/user/rime.service".source = "${cfg.package}/lib/systemd/user/rime.service";
    xdg.configFile."systemd/user/graphical-session.target.wants/rime.service".source =
      "${cfg.package}/lib/systemd/user/rime.service";
  };
}
