{
  description = "Understudy - a virtual camera that steps in when the real one can't";

  # The app is built and signed outside Nix (mac/bundle.sh), so the flake
  # only carries the nix-darwin module that runs it.
  outputs =
    { self }:
    {
      darwinModules.default = import ./nix/module.nix self;
    };
}
