# nix-aerie

Plug-and-play container image for devcontainers, CI pipelines, and coding agent sandboxes — ships [Nix](https://nixos.org/), [direnv](https://direnv.net/), and pre-cached development shells on a minimal [Wolfi](https://wolfi.dev/) base.

## How It Works

### Distroless base

Instead of starting from a full Linux distribution, the image uses a minimal [Wolfi](https://wolfi.dev/) base (~15 MB, by Chainguard) that carries almost nothing — just the filesystem layout (`/lib64`, `/usr/bin/env`) and glibc. That's enough for tools like VS Code Server to find what they expect, while keeping the attack surface minimal — Wolfi ships almost no packages and is rebuilt daily with security patches.

### Nix for everything

All actual developer tools — bash, git, direnv, curl, jq, and language toolchains — are managed and installed via Nix through a single `flake.nix` with one `flake.lock`. No distribution packages are used beyond the Wolfi base.

### Layered variants

Each language toolchain is a separate content-addressed layer on top of the shared base. Variants compose only the layers they need:

```
  ┌────────┬────────┬────────┬────────┐
  │ Python │   Go   │  Java  │  K8s   │  variant layers
  ├────────┴────────┴────────┴────────┤
  │  Nix tools · bash · git · direnv  │  shared base
  ├───────────────────────────────────┤
  │  Wolfi (~15 MB) · FHS + glibc    │
  └───────────────────────────────────┘
```

| Tag       | Added on top of base       | Size    |
|-----------|----------------------------|---------|
| `:base`   | —                          | ~500 MB |
| `:python` | Python, uv                 | ~1.3 GB |
| `:go`     | Go, gopls, golangci-lint   | ~1.1 GB |
| `:java`   | JDK 25, Maven, Gradle      | ~1.7 GB |
| `:k8s`    | kubectl, Helm              | ~800 MB |
| `:full`   | All of the above           | ~3.5 GB |

## Details

- **nix2container** builds the image without Docker — content-addressed layers mean daily security updates push only the store paths that changed, not the full image
- **Single-user Nix** — the container standard; no daemon or systemd required
- **No `USER` directive** in the image — devcontainers use `remoteUser: dev`, CI runs as root naturally
- **One `flake.lock`** pins all shells to the same nixpkgs revision, guaranteeing store-path deduplication across variants
- **Multi-arch** — native matrix builds on `amd64` and `arm64`

## License

[Apache-2.0](LICENSE)