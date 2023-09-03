let
    pkgs = import <nixpkgs> { };
in
{
    zig-master = pkgs.callPackage ./zig-master.nix { };
}