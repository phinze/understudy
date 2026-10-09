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
  host = "${cfg.appPath}/Contents/MacOS/camlink-host";
in
{
  options.services.camlink-fix = {
    enable = mkEnableOption ''
      the camlink-fix virtual camera agent. Apps open "Cam Link (camlink-fix)",
      the agent is the real Cam Link's only client, and it power-cycles the
      Cam Link when its own frames stop. CamLinkFix.app is built and signed
      outside Nix (mac/bundle.sh --install); this only runs the installed copy
    '';

    deviceName = mkOption {
      type = types.str;
      default = "Cam Link 4K";
      description = "Name of the real camera, as AVFoundation and uhubctl report it.";
    };

    user = mkOption {
      type = types.str;
      default = "phinze";
      description = "User account allowed to run uhubctl without a password.";
    };

    notify = mkOption {
      type = types.bool;
      default = true;
      description = "Show macOS notifications when resets fail or the app is out of date.";
    };

    appPath = mkOption {
      type = types.str;
      default = "/Applications/CamLinkFix.app";
      description = "Where CamLinkFix.app is installed. sysextd requires /Applications.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [
      pkgs.uhubctl
      # The replacement for `camlink-fix --kick`: reset the Cam Link now.
      (pkgs.writeShellScriptBin "camlink-kick" ''exec ${host} kick'')
    ];

    # Sudoers rule for passwordless uhubctl
    security.sudo.extraConfig = ''
      ${cfg.user} ALL=(ALL) NOPASSWD: ${pkgs.uhubctl}/bin/uhubctl
    '';

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
  };
}
