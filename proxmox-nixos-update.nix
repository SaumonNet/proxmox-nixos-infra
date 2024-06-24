{
  pkgs,
  config,
  proxmox-nixos-update,
  ...
}:
let
  proxmox-nixos-update-bin = "${proxmox-nixos-update}/bin/nixpkgs-update";

  proxmoxNixOSUpdateSystemDependencies = with pkgs; [
    nix # for nix-shell used by python packges to update fetchers
    git # used by update-scripts
    openssh # used by git
    gnugrep
    gnused
    curl
    getent # used by hub
    cachix
    apacheHttpd # for rotatelogs, used by worker script
    socat # used by worker script
    python3
    perl
  ];

  mkWorker = name: {
    after = [
      "network-online.target"
      "proxmox-nixos-update-supervisor.service"
    ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    description = "proxmox-nixos-update ${name} service";
    enable = true;
    restartIfChanged = true;
    path = proxmoxNixOSUpdateSystemDependencies;
    environment.XDG_CONFIG_HOME = "/var/lib/proxmox-nixos-update/worker";
    environment.XDG_CACHE_HOME = "/var/cache/proxmox-nixos-update/worker";
    environment.XDG_RUNTIME_DIR = "/run/proxmox-nixos-update"; # for nix-update update scripts
    environment.NIX_PATH = "nixpkgs=${pkgs.path}";

    serviceConfig = {
      Type = "simple";
      User = "proxmox-nixos-update";
      Group = "proxmox-nixos-update";
      Restart = "on-failure";
      RestartSec = "5s";
      WorkingDirectory = "/var/lib/proxmox-nixos-update/worker";
      StateDirectory = "proxmox-nixos-update/worker";
      StateDirectoryMode = "700";
      CacheDirectory = "proxmox-nixos-update/worker";
      CacheDirectoryMode = "700";
      LogsDirectory = "proxmox-nixos-update/";
      LogsDirectoryMode = "755";
      RuntimeDirectory = "proxmox-nixos-update-worker";
      RuntimeDirectoryMode = "700";
      StandardOutput = "journal";
    };

    script = ''
      mkdir -p "$LOGS_DIRECTORY/~workers/"
      # This is for public logs at proxmox-nixos-update-logs.nix-community.org/~workers
      exec  > >(rotatelogs -eD "$LOGS_DIRECTORY"'/~workers/%Y-%m-%d-${name}.stdout.log' 86400)
      exec 2> >(rotatelogs -eD "$LOGS_DIRECTORY"'/~workers/%Y-%m-%d-${name}.stderr.log' 86400 >&2)

      socket=/run/proxmox-nixos-update-supervisor/work.sock

      function run-proxmox-nixos-update {
        exit_code=0
        set -x
        timeout 6h ${proxmox-nixos-update-bin} update --pr "$attr_path $payload" || exit_code=$?
        set +x
        if [ $exit_code -eq 124 ]; then
          echo "Update was interrupted because it was taking too long."
        fi
        msg="DONE $attr_path $exit_code"
      }

      msg=READY
      while true; do
        response=$(echo "$msg" | socat -t5 UNIX-CONNECT:"$socket" - || true)
        case "$response" in
          "") # connection error; retry
            sleep 5
            ;;
          NOJOBS)
            msg=READY
            sleep 60
            ;;
          JOB\ *)
            read -r attr_path payload <<< "''${response#JOB }"
            # If one worker is initializing the proxmox-nixos clone, the other will
            # try to use the incomplete clone, consuming a bunch of jobs and
            # throwing them away. So we use a crude locking mechanism to
            # run only one worker when there isn't a proxmox-nixos directory yet.
            # Once the directory exists and this initial lock is released,
            # multiple workers can run concurrently.
            lockdir="$XDG_CACHE_HOME/.proxmox-nixos.lock"
            if [ ! -e "$XDG_CACHE_HOME/proxmox-nixos" ] && mkdir "$lockdir"; then
              trap 'rmdir "$lockdir"' EXIT
              run-proxmox-nixos-update
              rmdir "$lockdir"
              trap - EXIT
              continue
            fi
            while [ -e "$lockdir" ]; do
              sleep 10
            done
            run-proxmox-nixos-update
        esac
      done
    '';
  };

  mkFetcher = name: cmd: {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = proxmoxNixOSUpdateSystemDependencies ++ [
      (pkgs.python3.withPackages (
        p: with p; [
          requests
          dateutil
          libversion
          cachecontrol
          lockfile
          filelock
        ]
      ))
    ];
    environment.API_TOKEN_FILE = "${config.age.secrets.github-token.path}";
    environment.XDG_CACHE_HOME = "/var/cache/proxmox-nixos-update/fetcher/";

    serviceConfig = {
      Type = "simple";
      User = "proxmox-nixos-update";
      Group = "proxmox-nixos-update";
      Restart = "on-failure";
      RestartSec = "30m";
      LogsDirectory = "proxmox-nixos-update/";
      LogsDirectoryMode = "755";
      StateDirectory = "proxmox-nixos-update";
      StateDirectoryMode = "700";
      CacheDirectory = "proxmox-nixos-update/fetcher";
      CacheDirectoryMode = "700";
    };

    script = ''
      mkdir -p "$LOGS_DIRECTORY/~fetchers"
      cd "$LOGS_DIRECTORY/~fetchers"
      run_name="${name}.$(date +%s).txt"
      rm -f ${name}.*.txt.part
      ${cmd} > "$run_name.part"
      rm -f ${name}.*.txt
      mv "$run_name.part" "$run_name"
    '';
    startAt = "0/12:10"; # every 12 hours
  };

in
{
  users.groups.proxmox-nixos-update = { };
  users.users.proxmox-nixos-update = {
    useDefaultShell = true;
    isNormalUser = true; # The hub cli seems to really want stuff to be set up like a normal user
    extraGroups = [ "proxmox-nixos-update" ];
  };

  systemd.services.proxmox-nixos-update-delete-done = {
    startAt = "0/12:10"; # every 12 hours
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    description = "proxmox-nixos-update delete done branches";
    restartIfChanged = true;
    path = proxmoxNixOSUpdateSystemDependencies;
    environment.XDG_CONFIG_HOME = "/var/lib/proxmox-nixos-update/worker";
    environment.XDG_CACHE_HOME = "/var/cache/proxmox-nixos-update/worker";

    serviceConfig = {
      Type = "simple";
      User = "proxmox-nixos-update";
      Group = "proxmox-nixos-update";
      Restart = "on-abort";
      RestartSec = "5s";
      WorkingDirectory = "/var/lib/proxmox-nixos-update/worker";
      StateDirectory = "proxmox-nixos-update/worker";
      StateDirectoryMode = "700";
      CacheDirectoryMode = "700";
      LogsDirectory = "proxmox-nixos-update/";
      LogsDirectoryMode = "755";
      StandardOutput = "journal";
    };

    script = "${proxmox-nixos-update-bin} delete-done --delete";
  };

  systemd.services.proxmox-nixos-update-fetch-updatescript = mkFetcher "updatescript" "${pkgs.nix}/bin/nix eval --raw -f ${./packages-with-update-script.nix}";

  systemd.services.proxmox-nixos-update-worker1 = mkWorker "worker1";
  systemd.services.proxmox-nixos-update-worker2 = mkWorker "worker2";

  systemd.services.proxmox-nixos-update-supervisor = {
    wantedBy = [ "multi-user.target" ];
    description = "proxmox-nixos-update supervisor service";
    enable = true;
    restartIfChanged = true;
    path = with pkgs; [
      apacheHttpd
      (python3.withPackages (ps: [ ps.asyncinotify ]))
    ];

    serviceConfig = {
      Type = "simple";
      User = "proxmox-nixos-update";
      Group = "proxmox-nixos-update";
      Restart = "on-failure";
      RestartSec = "5s";
      LogsDirectory = "proxmox-nixos-update/";
      LogsDirectoryMode = "755";
      RuntimeDirectory = "proxmox-nixos-update-supervisor/";
      RuntimeDirectoryMode = "755";
      StandardOutput = "journal";
    };

    script = ''
      mkdir -p "$LOGS_DIRECTORY/~supervisor"
      # This is for public logs at proxmox-nixos-update-logs.nix-community.org/~supervisor
      exec  > >(rotatelogs -eD "$LOGS_DIRECTORY"'/~supervisor/%Y-%m-%d.stdout.log' 86400)
      exec 2> >(rotatelogs -eD "$LOGS_DIRECTORY"'/~supervisor/%Y-%m-%d.stderr.log' 86400 >&2)
      # Fetcher output is hosted at proxmox-nixos-update-logs.nix-community.org/~fetchers
      python3 ${./supervisor.py} "$LOGS_DIRECTORY/~supervisor/state.db" "$LOGS_DIRECTORY/~fetchers" "$RUNTIME_DIRECTORY/work.sock"
    '';
  };

  systemd.services.proxmox-nixos-update-delete-old-logs = {
    startAt = "daily";
    # delete logs older than 18 months, delete worker logs older than 3 months, delete empty directories
    script = ''
      ${pkgs.findutils}/bin/find /var/log/proxmox-nixos-update -type f -mtime +548 -delete
      ${pkgs.findutils}/bin/find /var/log/proxmox-nixos-update/~workers -type f -mtime +90 -delete
      ${pkgs.findutils}/bin/find /var/log/proxmox-nixos-update -type d -empty -delete
    '';
    serviceConfig.Type = "oneshot";
  };

  systemd.tmpfiles.rules = [
    "L+ /home/proxmox-nixos-update/.gitconfig - - - - ${./gitconfig.txt}"
    "d /home/proxmox-nixos-update/.ssh 700 proxmox-nixos-update proxmox-nixos-update - -"
    "e /var/cache/proxmox-nixos-update/worker/nixpkgs-review - - - 1d -"
  ];

  age.secrets.github-token = {
    path = "/var/lib/proxmox-nixos-update/worker/github_token.txt";
    owner = "proxmox-nixos-update";
    group = "proxmox-nixos-update";
    file = ./secrets/bot-github-token.age;
  };

  age.secrets.ssh-key = {
    path = "/home/proxmox-nixos-update/.ssh/id_ed25519";
    owner = "proxmox-nixos-update";
    group = "proxmox-nixos-update";
    file = ./secrets/ssh-bot-priv.age;

  };

  services.nginx.recommendedZstdSettings = false;

  services.nginx.virtualHosts."proxmox-nixos-update-logs.saumon.network" = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      alias = "/var/log/proxmox-nixos-update/";
      extraConfig = ''
        charset utf-8;
        autoindex on;
      '';
    };
  };

}
