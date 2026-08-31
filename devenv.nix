{
  config,
  pkgs,
  ...
}:
let
  root = config.devenv.root;
  rimePackages = pkgs.callPackage ./package.nix { };
  runNu = file: "nu ${root}/${file}";
  # shell entry must not repair formatting before the check sees it
  treefmtCommand = "treefmt --config-file ${root}/treefmt.toml --tree-root ${root}";
in
{
  languages.rust = {
    enable = true;
    channel = "stable";
    components = [
      "rustc"
      "cargo"
      "clippy"
      "rustfmt"
      "rust-analyzer"
      "rust-src"
    ];
  };

  packages = with pkgs; [
    rimePackages.rimectl
    rimePackages.rimed
    qt6.qtdeclarative
    qt6.qtshadertools
    wayland-protocols
    wayland-scanner
    cargo-nextest
    cargo-machete
    wl-clipboard
    clang-tools
    cargo-about
    cargo-deny
    quickshell
    pkg-config
    wlr-randr
    prettier
    pipewire
    ripgrep
    nushell
    wayland
    treefmt
    nixfmt
    labwc
    taplo
    grim
    dbus
    jq
  ];

  env.QSG_RENDER_LOOP = "threaded";
  env.RIME_DEV = "1";

  scripts = {
    rime-run = {
      exec = "devenv tasks run dev:run";
      description = "build and run the available rime process";
    };
    rime-nest = {
      exec = "devenv tasks run dev:nested";
      description = "check nested verification availability";
    };
    rime-fmt = {
      exec = treefmtCommand;
      description = "format every repository language";
    };
    rime-check = {
      exec = "devenv tasks run check:all";
      description = "run the fast checks";
    };
    rime-gate = {
      exec = "devenv tasks run gate:all";
      description = "run the full gate used by CI";
    };
    rime-soak = {
      exec = "devenv tasks run gate:soak";
      description = "run the current zero-surface soak gate";
    };
  };

  # hooks stay on the fast path and leave soak work to the gate
  git-hooks.hooks = {
    formatting = {
      enable = true;
      entry = "devenv shell -- ${runNu "ci/fmt-check.nu"}";
      pass_filenames = false;
    };
    clippy = {
      enable = true;
      settings = {
        allFeatures = true;
        denyWarnings = true;
        extraArgs = "--workspace --all-targets";
      };
    };
    qml = {
      enable = true;
      entry = "${runNu "ci/arch-checks.nu"} --qml-only";
      pass_filenames = false;
    };
    architecture = {
      enable = true;
      entry = runNu "ci/arch-checks.nu";
      pass_filenames = false;
    };
    check-added-large-files = {
      enable = true;
      args = [ "--maxkb=1024" ];
    };
    commit-message = {
      enable = true;
      entry = runNu "ci/commit-msg-check.nu";
      stages = [ "commit-msg" ];
    };
  };

  tasks = {
    "dev:run" = {
      exec = "cargo run --quiet -p rimed";
      cwd = root;
    };
    "dev:nested" = {
      exec = "${runNu "ci/soak.nu"} --nested";
      cwd = root;
    };
    "check:fmt" = {
      exec = runNu "ci/fmt-check.nu";
      cwd = root;
    };
    "check:clippy" = {
      exec = "cargo clippy --workspace --all-targets --all-features -- -D warnings";
      cwd = root;
    };
    "check:qml" = {
      exec = "${runNu "ci/arch-checks.nu"} --qml-only";
      cwd = root;
    };
    "check:arch" = {
      exec = runNu "ci/arch-checks.nu";
      cwd = root;
    };
    "check:deps" = {
      exec = "cargo deny check && cargo machete";
      cwd = root;
    };
    "check:all".after = [
      "check:fmt"
      "check:clippy"
      "check:qml"
      "check:arch"
      "check:deps"
    ];
    "test:unit" = {
      exec = "cargo nextest run --workspace --no-tests pass";
      cwd = root;
    };
    "build:shaders" = {
      exec = runNu "ci/build-shaders.nu";
      cwd = root;
    };
    "build:proto" = {
      exec = runNu "ci/build-proto.nu";
      cwd = root;
    };
    "build:packages" = {
      exec = "nix build .#rimed .#rimectl --no-link";
      cwd = root;
    };
    "gate:soak" = {
      exec = runNu "ci/soak.nu";
      cwd = root;
    };
    "gate:all".after = [
      "check:all"
      "test:unit"
      "build:shaders"
      "build:proto"
      "build:packages"
      "gate:soak"
    ];
    "audit:scheduled" = {
      exec = "cargo deny check && cargo machete";
      cwd = root;
    };
  };

  enterShell = ''
    echo "rime dev shell. Commands: rime-run rime-nest rime-fmt rime-check rime-gate rime-soak"
  '';

  enterTest = ''
    devenv tasks run gate:all
  '';
}
