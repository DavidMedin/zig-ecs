# Zig ECS

This is an Entity Component System (ECS) written in Zig. Primarily made for the Playdate (https://play.date).

## Oh no, I don't have Zig!
Well I hope you have Nix, otherwise you'll have to figure it out on your own.\
To build with Zig with Nix, run `nix-build -A zig-master`. Then, `nix-shell`!


## Future note to developer
If you want to update the version of Zig being built with Nix, get the hash of the branch by:
https://github.com/NixOS/nixpkgs/issues/191128#issuecomment-1246030466
```bash
git clone https://github.com/ziglang/zig.git
rm -rf zig/.git
nix --extra-experimental-features nix-command hash path zig # this will output the hash
rm -rf zig
```