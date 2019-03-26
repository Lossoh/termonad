# This file pins the version of nixpkgs to a known good version. The nixpkgs is
# imported with an overlay adding Termonad. It is imported from various other
# files.

{ compiler ? null, nixpkgs ? null }:

let
  nixpkgsSrc =
    if isNull nixpkgs
      then
        builtins.fetchTarball {
          # Recent version of nixpkgs-19.03 as of 2019-03-02.
          url = "https://github.com/NixOS/nixpkgs/archive/07e2b59812de95deeedde95fb6ba22d581d12fbc.tar.gz";
          sha256 = "1yxmv04v2dywk0a5lxvi9a2rrfq29nw8qsm33nc856impgxadpgf";
        }
      else
        nixpkgs;

  compilerVersion = if isNull compiler then "ghc863" else compiler;

  # The termonad derivation is generated automatically with `cabal2nix`.
  termonadOverride =
    stdenvLib: gnome3: callCabal2nix: overrideCabal:
      let
        src =
          builtins.filterSource
            (path: type: with stdenvLib;
              ! elem (baseNameOf path) [ ".git" "result" ".stack-work" ".nix-helpers" ] &&
              ! any (flip hasPrefix (baseNameOf path)) [ "dist" ".ghc" ]
            )
            ./..;
        termonad = callCabal2nix "termonad" src {
          inherit (gnome3) gtk3;
          vte_291 = gnome3.vte;
        };
      in
      overrideCabal termonad (oldAttrs: {
        # For some reason the doctests fail when running with nix.
        # https://github.com/cdepillabout/termonad/issues/15
        #doCheck = false;
        checkPhase = ''
          ./dist/build/doctests/doctests
        '';
      });

  haskellPackagesOverlay = self: super: with super.haskell.lib; {
    haskellPackages = super.haskell.packages.${compilerVersion}.override {
      overrides = hself: hsuper: {
        termonad =
          termonadOverride
            self.stdenv.lib
            self.gnome3
            hself.callCabal2nix
            self.haskell.lib.overrideCabal;

        # https://github.com/NixOS/nixpkgs/pull/53682
        # genvalidity-hspec = dontCheck hsuper.genvalidity-hspec;
      };
    };
  };

in import nixpkgsSrc { overlays = [ haskellPackagesOverlay ]; }
