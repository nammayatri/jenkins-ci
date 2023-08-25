{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixos-flake.url = "github:srid/nixos-flake";
    sops-nix.url = "github:juspay/sops-nix/json-nested"; # https://github.com/Mic92/sops-nix/pull/328

    deploy-rs.url = "github:serokell/deploy-rs";

    # Darwin
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    jenkins-nix-ci.url = "github:juspay/jenkins-nix-ci";
  };
  outputs = inputs@{ self, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = inputs.nixpkgs.lib.systems.flakeExposed;
      imports = [
        inputs.nixos-flake.flakeModule
        ./nix/deploy.nix
      ];

      flake.darwinConfigurations.biryani = self.nixos-flake.lib.mkARMMacosSystem ({ flake, pkgs, ... }: {
        imports = [
          flake.inputs.jenkins-nix-ci.darwinModules.default
          flake.inputs.jenkins-nix-ci.darwinModules.slave
          ./nix/darwin/configuration.nix
          ./nix/tailscale.nix
          ./nix/storage.nix
        ];
      });

      # System configuration
      flake.nixosConfigurations.jenkins-nix-ci = self.nixos-flake.lib.mkLinuxSystem ({ pkgs, config, ... }: {
        imports = [
          inputs.sops-nix.nixosModules.sops

          # Jenkins module usage
          inputs.jenkins-nix-ci.nixosModules.default
          ({
            jenkins-nix-ci = {
              # Tailscale funnel
              domain = "jenkins-nix-ci.betta-gray.ts.net";

              nodes = {
                containerSlaves = {
                  externalInterface = "enp7s0";
                  hostAddress = "192.168.10.176";
                  containers = {
                    jenkins-slave-nixos-1.hostIP = "192.168.100.11";
                    jenkins-slave-nixos-2.hostIP = "192.168.100.12";
                    jenkins-slave-nixos-3.hostIP = "192.168.100.13";
                    jenkins-slave-nixos-4.hostIP = "192.168.100.14";
                  };
                };
                sshSlaves = {
                  # Mac Studio in office.
                  biryani = {
                    hostIP = "100.97.32.60"; # Tailscale IP
                    numExecutors = 4;
                    labelString = "macos x86_64-darwin aarch64-darwin";
                  };
                };
              };

              # TODO: Some of these plugins are required by jenkins-nix-ci
              # features; as such, they must be part of a default list and
              # included even if not specified.
              plugins = [
                "github-api"
                "git"
                "github-branch-source"
                "workflow-aggregator"
                "ssh-slaves"
                "configuration-as-code"
                "pipeline-graph-view"
                "pipeline-utility-steps" # Used by 'nix' feature, for readJSON
              ];
              # This file can be updated by running:
              #   nix-prefetch-jenkins-plugins > nix/jenkins-plugins.nix
              #
              # It will fetch the latest version of plugins in the above list,
              # and write their pinned sources to the jenkins-plugins.nix file.
              plugins-file = "nix/jenkins-plugins.nix";

              features = {
                cachix.enable = true;
                docker.enable = true;
                githubApp.enable = true;
                nix.enable = true;
              };
            };
          })

          ./nix/nixos/configuration.nix
          ./nix/tailscale.nix
          ./nix/storage.nix
        ];
        sops.defaultSopsFile = ./secrets.json;
        sops.defaultSopsFormat = "json";
      });

      perSystem = { self', inputs', system, lib, config, pkgs, ... }: {
        _module.args.pkgs = import inputs.nixpkgs {
          inherit system;
          overlays = [
            inputs.jenkins-nix-ci.overlay
            (_: _: {
              deploy-rs = inputs.deploy-rs.packages.${system}.default;
            })
          ];
        };
        formatter = pkgs.nixpkgs-fmt;
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            nixpkgs-fmt
            deploy-rs
            sops
            (
              let nixosConfig = self.nixosConfigurations.jenkins-nix-ci;
              in nixosConfig.config.jenkins-nix-ci.nix-prefetch-jenkins-plugins pkgs
            )
          ];
        };
      };
    };
}
