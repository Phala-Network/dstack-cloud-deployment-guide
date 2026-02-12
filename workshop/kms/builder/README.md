# dstack-kms + helios Builder

Builds a single Docker image containing both **dstack-kms** and **helios** (Ethereum light client with base-sepolia support).

## Prerequisites

- Docker with BuildKit support (v20.10.0+)

## Build

```bash
./build-image.sh <image-name>[:<tag>]
```

Example:

```bash
./build-image.sh cr.kvin.wang/dstack-kms:latest
```

## Override Source Revisions

Source revisions are pinned in `build-image.sh` for reproducibility. Override via environment:

```bash
DSTACK_REV=<commit-sha> HELIOS_REV=<commit-sha> ./build-image.sh cr.kvin.wang/dstack-kms:latest
```

## What's Included

| Binary | Source | Purpose |
|--------|--------|---------|
| `dstack-kms` | [dstack-cloud](https://github.com/Phala-Network/dstack-cloud) | KMS service |
| `helios` | [helios](https://github.com/a16z/helios) | Ethereum light client (base-sepolia) |

Both are statically linked (musl) and placed in `/usr/local/bin/`.

## Why Not Use Helios GitHub Releases?

Helios release builds (v0.11.0) only support mainnet networks. Support for `base-sepolia` was added after the release, so we build from a pinned git commit.
