{ pkgs }:
let
  bashrc = pkgs.writeText "bashrc" ''
    # Source Nix profile
    if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix.sh ]; then
      . /nix/var/nix/profiles/default/etc/profile.d/nix.sh
    fi

    # Enable direnv
    eval "$(direnv hook bash)"
  '';

  nixConf = pkgs.writeText "nix.conf" ''
    experimental-features = nix-command flakes
    sandbox = false
  '';
in
pkgs.runCommand "dotfiles" {} ''
  mkdir -p $out/home/dev
  mkdir -p $out/etc/nix
  cp ${bashrc} $out/home/dev/.bashrc
  cp ${nixConf} $out/etc/nix/nix.conf
''