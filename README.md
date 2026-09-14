# build

A GitHub Action for building projects with [coalaura/builder](https://github.com/coalaura/builder).

The action runs the published Builder image directly, so it does not build another Docker image and does not require `actions/setup-go`. Builder versions can be selected independently from the Action version.

## Usage

```yaml
- uses: actions/checkout@v7

- uses: coalaura/build@v1
  with:
    os: linux
    arch: amd64
    output: build/example
```

Builder `latest` is used by default.

## Matrix builds

`os` and `arch` are regular Action inputs, so they can be fed directly from a GitHub Actions matrix:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest

    strategy:
      fail-fast: false
      matrix:
        goos: [windows, linux, darwin]
        goarch: [amd64, arm64]

    steps:
      - name: Checkout
        uses: actions/checkout@v7

      - name: Build ${{ matrix.goos }}_${{ matrix.goarch }}
        id: build
        uses: coalaura/build@v1
        with:
          os: ${{ matrix.goos }}
          arch: ${{ matrix.goarch }}
          output: build/mksvc_${{ github.ref_name }}_${{ matrix.goos }}_${{ matrix.goarch }}${{ matrix.goos == 'windows' && '.exe' || '' }}
          go-flags: |
            -ldflags=-X main.Version=${{ github.ref_name }}

      - name: Upload artifact
        uses: actions/upload-artifact@v7
        with:
          name: mksvc_${{ github.ref_name }}_${{ matrix.goos }}_${{ matrix.goarch }}
          path: ${{ steps.build.outputs.path }}
```

The output directory is created automatically when `output` is set. The resolved output file is available as `steps.<id>.outputs.path` and its basename as `steps.<id>.outputs.filename`.

## Inputs

| Input          | Default         | Description                                                   |
| -------------- | --------------- | ------------------------------------------------------------- |
| `version`      | `latest`        | Builder version to use                                        |
| `os`           | Builder default | `linux`, `windows` or `darwin`                                |
| `arch`         | Builder default | Go target architecture, such as `amd64` or `arm64`            |
| `cgo`          | `false`         | Enable CGO                                                    |
| `link`         | `static`        | `static` or `dynamic`; dynamic requires CGO                   |
| `optimization` | `optimize`      | `optimize` or `compatible`                                    |
| `minify`       | `false`         | Compress the result with UPX                                  |
| `generate`     | `true`          | Run `go generate ./...`                                       |
| `gui`          | `false`         | Use the Windows GUI subsystem for Go builds                   |
| `package`      |                 | Go package to build                                           |
| `output`       |                 | Go build output name or path                                  |
| `target`       |                 | Project or build target                                       |
| `debug`        | `false`         | Print commands without executing them                         |
| `pre`          |                 | Shell script used to extend the Builder image before building |
| `go-flags`     |                 | Additional Go build flags, one argument per line              |
| `arguments`    |                 | Arguments passed after `--`, one argument per line            |

Signing is intentionally not exposed. Use `coalaura/sign` separately when signing is required.

### Pre-build image setup

`pre` can extend the Builder image with additional build dependencies before the project is built. The script runs as root while preparing a temporary image, before the project workspace is mounted.

For example, a project that requires CMake, Ninja and pkg-config can install them without adding those packages to the base Builder image:

```yaml
- uses: coalaura/build@v1
  with:
    cgo: true
    pre: |
      apk add --no-cache cmake ninja pkgconf
```

The selected Builder image remains the base for the temporary image. Darwin CGO builds therefore retain the macOS SDK while also receiving any packages installed by `pre`.

`pre` is intended for image setup such as installing packages and system tools. Commands that operate on the checked-out project should instead be run as a separate workflow step.

## Version

The Action and Builder are versioned independently:

```yaml
- uses: coalaura/build@v1
  with:
    version: v0.4.5
```

The Action selects the corresponding `coalaura/builder` image automatically. Darwin CGO builds use the macOS SDK variant of the same Builder version.

Changing the Builder version does not require changing the Action version.

### Go flags

Each non-empty line of `go-flags` is passed to Builder as one argument. Joined Go flags are convenient for values containing spaces:

```yaml
- uses: coalaura/build@v1
  with:
    os: windows
    arch: amd64
    output: build/example.exe
    go-flags: |
      -tags=netgo,release
      -ldflags=-X main.Version=${{ github.ref_name }} -X main.Commit=${{ github.sha }}
      -trimpath
```

Builder merges `-ldflags` and `-tags` with its generated values.

### Forwarded arguments

Each non-empty line of `arguments` is passed literally after Builder's `--` separator:

```yaml
- uses: coalaura/build@v1
  with:
    arguments: |
      -mod=readonly
```

## CGO

Builder uses Zig for supported CGO cross-compilation. For example:

```yaml
- uses: coalaura/build@v1
  with:
    os: linux
    arch: arm64
    cgo: true
    link: static
    output: build/example_linux_arm64
```

Dynamic linking requires `cgo: true`.

## Outputs

| Output | Description |
| --- | --- |
| `path` | Absolute path to the built file when `output` is set |
| `filename` | Basename of the built file when `output` is set |
| `image` | Builder Docker image used for the build |

## Runner

`coalaura/build` requires a Linux runner with Docker available. The target operating system and architecture refer to the produced binary, not the GitHub Actions runner.

Paths are evaluated relative to `GITHUB_WORKSPACE`. Explicit output paths must remain inside the workspace so the resulting file persists after the Builder container exits.

## License

GPL-3.0
