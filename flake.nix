{
  description = "camlink-fix - a virtual camera that keeps the Elgato Cam Link 4K working through resets";

  # The app is built and signed outside Nix (mac/bundle.sh), so the flake
  # only carries the nix-darwin module that runs it.
  outputs =
    { self }:
    {
      darwinModules.default = import ./nix/module.nix self;
    };
}
