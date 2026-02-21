# nix-aerie

Plug-and-play container image for devcontainers, CI pipelines, and coding agent sandboxes — ships [Nix](https://nixos.org/), [direnv](https://direnv.net/), and pre-cached development shells on an [Ubuntu 24.04](https://ubuntu.com/) base.

## How It Works

### Ubuntu base

The image uses an Ubuntu 24.04 base that provides the filesystem layout, glibc, and `apt-get` — required by devcontainer features for package installation.

### Nix for everything

All actual developer tools — bash, git, direnv, curl, jq, and language toolchains — are managed and installed via Nix through a single `flake.nix` with one `flake.lock`. Ubuntu provides only the base filesystem; all developer tooling comes from Nix.

### Layered variants

Each language toolchain is a separate content-addressed layer on top of the shared base. Variants compose only the layers they need:

```
  ┌─────────────────────────────────┐
  │  Python · Go · Java · K8s · …   │  variant layers
  ├─────────────────────────────────┤
  │  Nix tools · bash · git · direnv│  shared base
  ├─────────────────────────────────┤
  │  Ubuntu · FHS + glibc + apt      │
  └─────────────────────────────────┘
```


## Details

- **nix2container** builds the image without Docker — content-addressed layers mean daily security updates push only the store paths that changed, not the full image
- **Single-user Nix** — the container standard; no daemon or systemd required
- **No `USER` directive** in the image — devcontainers use `remoteUser: dev`, CI runs as root naturally
- **One `flake.lock`** pins all shells to the same nixpkgs revision, guaranteeing store-path deduplication across variants
- **Architecture** — `linux/amd64` for CI and Codespaces; `linux/arm64` available in `flake.nix` for local testing on Apple Silicon

## License

[Apache-2.0](LICENSE)