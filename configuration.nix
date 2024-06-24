{ lib, pkgs, ... }:

{
  imports = [
    ./hardware.nix
    ./proxmox-nixos-update.nix
  ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;

  networking.hostName = "promox-nixos-infra";

  disko.devices = import ./disko.nix;

  deployment.targetHost = "2a01:e0a:de4:a0e1:eb2:caa1::78";

  # Set your time zone.
  time.timeZone = "Europe/Paris";

  environment.systemPackages = with pkgs; [ neovim ];

  nix = {
    package = pkgs.lix;
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
    nixPath = [ "nixpkgs=${pkgs.path}" ];
    settings = {
      builders-use-substitutes = true;
      auto-optimise-store = true;
      substituters = [
        "https://cache.nixos.org"
        "https://cache.saumon.network/proxmox-nixos"
      ];
      trusted-public-keys = [ "proxmox-nixos:nveXDuVVhFDRFx8Dn19f1WDEaNRJjPrF2CPD2D+m1ys=" ];
    };
  };

  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIADCpuBL/kSZShtXD6p/Nq9ok4w1DnlSoxToYgdOvUqo julien@telecom"
  ];

  security.acme.acceptTerms = true;
  security.acme.defaults.email = "webmaster@nixos.org";

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
  networking.firewall.allowedUDPPorts = [ ];

  networking.useNetworkd = true;
  systemd.network.networks."10-wan" = {
    matchConfig.Name = "ens18";
    networkConfig = {
      DHCP = "ipv4";
      Address = "2a01:e0a:de4:a0e1:eb2:caa1::78";
    };
    # make routing on this interface a dependency for network-online.target
    linkConfig.RequiredForOnline = "routable";
  };

  system.stateVersion = "23.11";
}
