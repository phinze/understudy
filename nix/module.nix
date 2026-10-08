self:
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;
let
  cfg = config.services.camlink-fix;
in
{
  options.services.camlink-fix = {
    enable = mkEnableOption "Cam Link 4K auto-fix daemon";

    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = literalExpression "camlink-fix.packages.\${system}.default";
      description = "The camlink-fix package to use.";
    };

    deviceName = mkOption {
      type = types.str;
      default = "Cam Link 4K";
      description = "Name of the camera device as it appears in system_profiler.";
    };

    user = mkOption {
      type = types.str;
      default = "phinze";
      description = "User account that will run the daemon.";
    };

    notify = mkOption {
      type = types.bool;
      default = true;
      description = "Show macOS notifications when fixing the camera.";
    };

    wakeDelay = mkOption {
      type = types.int;
      default = 5;
      description = "Seconds to wait after wake before checking the camera.";
    };

    retryDelay = mkOption {
      type = types.int;
      default = 30;
      description = "Seconds between retries after a failed health check.";
    };

    maxRetries = mkOption {
      type = types.int;
      default = 10;
      description = "Maximum number of retries after a failed health check.";
    };

    virtualCamera = {
      enable = mkEnableOption ''
        the virtual camera agent in place of the probe-and-reset daemon. Apps
        open "Cam Link (camlink-fix)", the agent is the real Cam Link's only
        client, and it power-cycles the Cam Link when its own frames stop.
        The Go daemon is turned off, since its ffmpeg probes would be a second
        client on the device. CamLinkFix.app is built and signed outside Nix
        (mac/bundle.sh --install); this only runs the installed copy
      '';

      appPath = mkOption {
        type = types.str;
        default = "/Applications/CamLinkFix.app";
        description = "Where CamLinkFix.app is installed. sysextd requires /Applications.";
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      environment.systemPackages = [ pkgs.uhubctl ];

      # Sudoers rule for passwordless uhubctl
      security.sudo.extraConfig = ''
        ${cfg.user} ALL=(ALL) NOPASSWD: ${pkgs.uhubctl}/bin/uhubctl
      '';
    }

    (mkIf (!cfg.virtualCamera.enable) {
      environment.systemPackages = [
        pkgs.ffmpeg
        cfg.package
      ];

      # Launchd user agent running the Go daemon
      launchd.user.agents.camlink-fix = {
        path = [ "/usr/bin" "/bin" "/usr/sbin" "/sbin" ];
        serviceConfig = {
          ProgramArguments = [
            "${cfg.package}/bin/camlink-fix"
            "--uhubctl-path" "${pkgs.uhubctl}/bin/uhubctl"
            "--ffmpeg-path" "${pkgs.ffmpeg}/bin/ffmpeg"
            "--device-name" cfg.deviceName
            "--wake-delay" "${toString cfg.wakeDelay}s"
            "--notify=${boolToString cfg.notify}"
            "--retry-delay" "${toString cfg.retryDelay}s"
            "--max-retries" "${toString cfg.maxRetries}"
          ];
          KeepAlive = true;
          RunAtLoad = true;
          StandardOutPath = "/tmp/camlink-fix.log";
          StandardErrorPath = "/tmp/camlink-fix.log";
        };
      };
    })

    (mkIf cfg.virtualCamera.enable (
      let
        host = "${cfg.virtualCamera.appPath}/Contents/MacOS/camlink-host";
      in
      {
        environment.systemPackages = [
          # The replacement for `camlink-fix --kick`: reset the Cam Link now.
          (pkgs.writeShellScriptBin "camlink-kick" ''exec ${host} kick'')
        ];

        launchd.user.agents.camlink-host = {
          serviceConfig = {
            ProgramArguments = [ host "run" ];
            EnvironmentVariables = {
              CAMLINK_DEVICE_NAME = cfg.deviceName;
              CAMLINK_UHUBCTL = "${pkgs.uhubctl}/bin/uhubctl";
              CAMLINK_NOTIFY = if cfg.notify then "1" else "0";
              # Nix can't build the signed app, so the agent compares this
              # with the revision bundle.sh stamped into it and complains
              # when the installed copy is behind.
              CAMLINK_EXPECTED_REV = self.rev or self.dirtyRev or "unknown";
            };
            # Run only while the app is installed, rather than crash-looping
            # on a machine where bundle.sh hasn't been run yet.
            KeepAlive.PathState.${host} = true;
            RunAtLoad = true;
            ProcessType = "Interactive";
          };
        };
      }
    ))
  ]);
}
