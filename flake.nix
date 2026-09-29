{
  description = "VGS, a desktop shell for Hyprland on Quickshell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # config/requirements.json is the core's one list of runtime commands;
      # each row names its nixpkgs attribute under packages.nix. A required
      # row without one fails evaluation; an optional row without one is not
      # wrapped. Quickshell is added because `vgsh run` checks it. Hyprland
      # is not: the session supplies hyprctl.
      requirements = builtins.fromJSON (builtins.readFile ./config/requirements.json);
      runtimePackages = pkgs:
        [ pkgs.quickshell ]
        ++ map
          (row: pkgs.${row.packages.nix or (throw "config/requirements.json: command ${row.command} names no nix package")})
          (builtins.filter (row: !row.optional || row.packages ? nix) requirements);
    in
    {
      packages = forAllSystems (pkgs: {
        default = pkgs.stdenvNoCC.mkDerivation {
          pname = "vgs";
          version = lib.fileContents ./VERSION;
          src = self;

          nativeBuildInputs = [ pkgs.makeWrapper pkgs.python3 ];
          # The interpreters fixup writes into the runtime tree's
          # `#!/usr/bin/env` and `#!/bin/bash` lines.
          buildInputs = [ pkgs.bash pkgs.nodejs pkgs.python3 ];

          dontConfigure = true;
          dontBuild = true;

          # The shared installer writes the same tree every channel ships;
          # the manifest check proves it before the command is wrapped.
          installPhase = ''
            runHook preInstall
            DESTDIR= PREFIX=$out bash packaging/install-system.sh
            bash scripts/check-install-tree.sh "" "$out"
            wrapProgram $out/bin/vgsh --prefix PATH : ${lib.makeBinPath (runtimePackages pkgs)}
            runHook postInstall
          '';

          meta = {
            description = "Desktop shell for Hyprland on Quickshell";
            homepage = "https://github.com/vanillagreencom/vgs";
            license = with lib.licenses; [ mit ofl isc ];
            platforms = systems;
            mainProgram = "vgsh";
          };
        };
      });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.default;
          meta.description = "Run the vgsh command";
        };
      });
    };
}
