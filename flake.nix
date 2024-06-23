{
  description = "Nix hash collection infra";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    colmena = {
      url = "github:zhaofengli/colmena";
      inputs = {
        flake-utils.follows = "flake-utils";
        nixpkgs.follows = "nixpkgs";
        stable.follows = "nixpkgs";
      };
    };
    flake-utils.url = "github:numtide/flake-utils";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix.url = "github:ryantm/agenix";
    proxmox-nixos-update.url = "github:SaumonNet/proxmox-nixos-update";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      colmena,
      disko,
      agenix,
      proxmox-nixos-update,
      ...
    }@inputs:
    let
      lib = nixpkgs.lib;
    in
    {

      nixosConfigurations = builtins.mapAttrs (
        name: value:
        nixpkgs.lib.nixosSystem {
          lib = lib;
          system = "x86_64-linux";
          specialArgs = {
            inherit inputs;
            proxmox-nixos-update = proxmox-nixos-update.packages.x86_64-linux.default;
          };
          modules = [
            value
            disko.nixosModules.disko
            agenix.nixosModules.default
          ];
          extraModules = [ inputs.colmena.nixosModules.deploymentOptions ];
        }
      ) { proxmox-nixos-infra = import ./configuration.nix; };

      colmena = {
        meta = {
          nixpkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
          nodeSpecialArgs = builtins.mapAttrs (_: v: v._module.specialArgs) self.nixosConfigurations;
          specialArgs.lib = lib;
        };
      } // builtins.mapAttrs (_: v: { imports = v._module.args.modules; }) self.nixosConfigurations;
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShell = pkgs.mkShell {
          buildInputs = with pkgs; [
            colmena.packages.${system}.colmena
            agenix.packages.${system}.default
          ];
        };
      }
    );
}
