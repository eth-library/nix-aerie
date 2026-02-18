{
  description = "nix-aerie: Pre-baked OCI images with Nix + direnv for ETH Library Zurich";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    nix2container = {
      url = "github:nlewo/nix2container/bb6801be998ba857a62c002cb77ece66b0a57298";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, nix2container, flake-utils }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        n2c = nix2container.packages.${system}.nix2container;
        lib = pkgs.lib;

        # --- Shell definitions (plain Nix functions, not flakes) ---
        pythonShell = import ./shells/python.nix { inherit pkgs; };
        goShell = import ./shells/go.nix { inherit pkgs; };
        javaShell = import ./shells/java.nix { inherit pkgs; };
        k8sShell = import ./shells/k8s.nix { inherit pkgs; };

        # --- Dotfiles (manual derivation)
        dotfiles = import ./home.nix { inherit pkgs; };

        # --- User environment ---
        userPackages = with pkgs; [
          bash
          coreutils
          git
          nix
          direnv
          nix-direnv
          curl
          jq
          less
          gnutar
          gzip
          gnugrep
          gnused
          findutils
          xz
        ];

        userEnv = pkgs.buildEnv {
          name = "user-env";
          paths = userPackages;
          pathsToLink = [ "/bin" "/etc" "/lib" "/share" ];
        };

        # --- System files: /etc/passwd, /etc/group, directories ---
        systemFiles = pkgs.runCommand "system-files" {} ''
          mkdir -p $out/etc
          mkdir -p $out/home/dev
          mkdir -p $out/workspaces
          mkdir -p $out/tmp

          cat > $out/etc/passwd << 'EOF'
          root:x:0:0:root:/root:/bin/bash
          nobody:x:65534:65534:Nobody:/nonexistent:/usr/sbin/nologin
          dev:x:1000:1000::/home/dev:/bin/bash
          EOF

          cat > $out/etc/group << 'EOF'
          root:x:0:
          nobody:x:65534:
          dev:x:1000:
          EOF
        '';

        # --- Nix profile symlink ---
        nixProfile = pkgs.runCommand "nix-profile" {} ''
          mkdir -p $out/nix/var/nix/profiles
          mkdir -p $out/nix/var/nix/gcroots/profiles
          ln -s ${userEnv} $out/nix/var/nix/profiles/default
        '';

        # --- Wolfi base image (per-architecture digests) ---
        wolfiDigests = {
          "x86_64-linux" = {
            imageDigest = "sha256:a557cd88f9807c3632d2f7978f57b6dcab4ef2358b88aa7b0ae3d2706a44860e";
            sha256 = lib.fakeHash;
          };
          "aarch64-linux" = {
            imageDigest = "sha256:bd736af9ca3fa53ba61622dd50481bd8409e7e8ce57e59fd38e985b7673becde";
            sha256 = "sha256-4rmr+BySon8J/4iLhuXmjXsjROKOSgkReRe2OQBN84Q=";
          };
        };

        wolfiBase = n2c.pullImage {
          imageName = "cgr.dev/chainguard/wolfi-base";
          inherit (wolfiDigests.${system}) imageDigest sha256;
        };

        # --- Shared layers (all variants include these) ---

        # Layer: system files (/etc/passwd, /etc/group, /home/dev, /workspaces)
        systemLayer = n2c.buildLayer {
          copyToRoot = [ systemFiles ];
          perms = [
            {
              path = systemFiles;
              regex = "home/dev";
              mode = "0755";
              uid = 1000;
              gid = 1000;
            }
            {
              path = systemFiles;
              regex = "workspaces";
              mode = "0755";
              uid = 1000;
              gid = 1000;
            }
            {
              path = systemFiles;
              regex = "tmp";
              mode = "1777";
            }
          ];
        };

        # Layer: user packages (nix, bash, git, direnv, etc.)
        userPkgsLayer = n2c.buildLayer {
          deps = [ userEnv ];
        };

        # Layer: Nix profile (symlink tree)
        nixProfileLayer = n2c.buildLayer {
          copyToRoot = [ nixProfile ];
        };

        # Layer: dotfiles (.bashrc, nix.conf)
        dotfilesLayer = n2c.buildLayer {
          copyToRoot = [ dotfiles ];
        };

        baseLayers = [
          systemLayer
          userPkgsLayer
          nixProfileLayer
          dotfilesLayer
        ];

        # --- Shell-specific layers ---
        pythonLayer = n2c.buildLayer { deps = [ pythonShell ]; };
        goLayer = n2c.buildLayer { deps = [ goShell ]; };
        javaLayer = n2c.buildLayer { deps = [ javaShell ]; };
        k8sLayer = n2c.buildLayer { deps = [ k8sShell ]; };

        # --- Image configuration (no User!) ---
        imageConfig = {
          Env = [
            "PATH=/nix/var/nix/profiles/default/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            "NIX_PROFILES=/nix/var/nix/profiles/default"
            "HOME=/home/dev"
          ];
          WorkingDir = "/workspaces";
          Cmd = [ "/nix/var/nix/profiles/default/bin/bash" "-l" ];
        };

        # --- Variant builder ---
        mkVariant = { name, extraLayers ? [] }:
          n2c.buildImage {
            inherit name;
            fromImage = wolfiBase;
            layers = baseLayers ++ extraLayers;
            config = imageConfig;
            initializeNixDatabase = true;
            nixUid = 1000;
            nixGid = 1000;
          };

      in {
        packages = {
          default = mkVariant {
            name = "nix-aerie";
            extraLayers = [ pythonLayer goLayer javaLayer k8sLayer ];
          };
          base = mkVariant {
            name = "nix-aerie-base";
          };
          python = mkVariant {
            name = "nix-aerie-python";
            extraLayers = [ pythonLayer ];
          };
          go = mkVariant {
            name = "nix-aerie-go";
            extraLayers = [ goLayer ];
          };
          java = mkVariant {
            name = "nix-aerie-java";
            extraLayers = [ javaLayer ];
          };
          k8s = mkVariant {
            name = "nix-aerie-k8s";
            extraLayers = [ k8sLayer ];
          };
        };

        devShells = {
          python = pythonShell;
          go = goShell;
          java = javaShell;
          k8s = k8sShell;
        };
      }
    );
}
