{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";
  };

  outputs = { self, nixpkgs, systems }:
    let
      perSystem = callback: nixpkgs.lib.genAttrs (import systems) (system: callback (initPkgs system));
      initPkgs = system: nixpkgs.legacyPackages.${system};
    in
    {
      packages = perSystem (pkgs: rec {
        # Run ilia in the project repo with:
        #
        #     $ nix run
        #
        # or run without cloning the repo with:
        #
        #     $ nix run github:regolith-linux/ilia
        #
        default = ilia;
        ilia = pkgs.callPackage ./nix/ilia.nix { source = ./.; };
      });
    };
}
