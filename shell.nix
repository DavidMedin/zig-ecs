let
    pkgs = import <nixpkgs> {};
    zig-master = pkgs.callPackage ./zig-master.nix { };
in
    pkgs.mkShell {
        packages = [
            zig-master
        ];
    }