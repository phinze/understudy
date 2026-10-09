self:
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;
let
  cfg = config.services.understudy;
  host = "${cfg.appPath}/Contents/MacOS/understudy";
in
{
  options.services.understudy = {
    enable = mkEnableOption ''
      the Understudy virtual camera agent. Apps open "Understudy", the
      agent is the real camera's only client, and it power-cycles the
      camera when its own frames stop. Understudy.app is built and signed
      outside Nix (mac/bundle.sh --install); this only runs the installed copy
    '';

    deviceName = mkOption {
      type = types.str;
      default = "Cam Link 4K";
      description = ''
        Name of the real camera as AVFoundation reports it. uhubctl's
        description of its port has to contain this too ("Elgato Cam Link 4K"
        does).
      '';
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
      default = "/Applications/Understudy.app";
      description = "Where Understudy.app is installed. sysextd requires /Applications.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [
      pkgs.uhubctl
      # The agent's own CLI on PATH: `understudy kick`, `understudy
      # dump-frames DIR`, and so on.
      (pkgs.writeShellScriptBin "understudy" ''exec ${host} "$@"'')
    ];

    # Sudoers rule for passwordless uhubctl
    security.sudo.extraConfig = ''
      ${cfg.user} ALL=(ALL) NOPASSWD: ${pkgs.uhubctl}/bin/uhubctl
    '';

    launchd.user.agents.understudy = {
      serviceConfig = {
        ProgramArguments = [ host "run" ];
        EnvironmentVariables = {
          UNDERSTUDY_DEVICE_NAME = cfg.deviceName;
          UNDERSTUDY_UHUBCTL = "${pkgs.uhubctl}/bin/uhubctl";
          UNDERSTUDY_NOTIFY = if cfg.notify then "1" else "0";
          # Nix can't build the signed app, so the agent compares this
          # with the revision bundle.sh stamped into it and complains
          # when the installed copy is behind.
          UNDERSTUDY_EXPECTED_REV = self.rev or self.dirtyRev or "unknown";
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
