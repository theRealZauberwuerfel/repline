# This file was auto-generated by cabal2nix. Please do NOT edit manually!

{ cabal, haskeline, mtl }:

cabal.mkDerivation (self: {
  pname = "repl";
  version = "0.1.0.0";
  sha256 = "37d125d63db4453f1c2a12a774aef22fa538a03e5a5a5c9f1bdc9c8e6cf985a4";
  buildDepends = [ haskeline mtl ];
  meta = {
    license = self.stdenv.lib.licenses.mit;
    platforms = self.ghc.meta.platforms;
  };
})