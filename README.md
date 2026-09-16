# MowPSKit

**MowPSKit** is a lightweight PowerShell toolkit framework designed for modular development and single-file deployment.

During development, commands are separated into independent source files.  
GitHub Actions compiles them into `dist/MowPSKit.ps1`, making the toolkit easy to load on any Windows machine without installation.

## Features

- Modular PowerShell source structure
- Isolated source units
- Controlled public command exports
- Shared framework functions without polluting the global session
- Single-file compiled artifact
- Ephemeral and Installed runtime modes
- Source and Compiled build modes
- Runtime reload and unload
- Embedded resource support
- Deterministic builds
- UTF-8 without BOM
- Windows PowerShell 5.1 and PowerShell 7 compatible
- Automated testing and builds with GitHub Actions

## Quick Start

Load the latest build from `main` into the current session:

```powershell
irm https://raw.githubusercontent.com/steveh8758/MowPSKit/main/dist/MowPSKit.ps1 | iex
```

Install the latest build and add it to your PowerShell profile:

```powershell
irm https://raw.githubusercontent.com/steveh8758/MowPSKit/main/setup.ps1 | iex
```

If the effective execution policy is `Restricted` or `AllSigned`, setup asks
before changing only the `CurrentUser` policy to `RemoteSigned`. If Group Policy
enforces the blocking policy, setup stops before changing installation or
profile files.

After loading, use:

```powershell
mow.help
```

to see the available commands.

## Management Commands

| Command | Description |
| --- | --- |
| `mow.help` | Show available MowPSKit commands |
| `mow.ver` | Show version and runtime information |
| `mow.reload` | Reload from source, the installed file, or the remote artifact according to the current mode |
| `mow.install` | Ask to install MowPSKit, or fall back to the version-aware update flow when already installed |
| `mow.update` | In Installed mode, ask to update only when the remote version is newer |
| `mow.uninstall` | In Installed mode, remove MowPSKit using only local runtime logic |
| `mow.unload` | Remove MowPSKit from the current session |

These management commands always use the `mow.*` namespace and are not affected by command prefix settings. Install and persistent update delegate to the repository-root `setup.ps1`. Uninstall never downloads or invokes setup. Ephemeral `mow.update` and `mow.uninstall` only report that MowPSKit is not installed.

## How It Works

MowPSKit reports two independent properties:

- `Mode`: `Ephemeral` or `Installed`.
- `BuildMode`: `Source` or `Compiled`.

### Source Build Mode

Used during development.

```powershell
& .\src\loader.ps1
```

```text
src/
   ↓
loader.ps1
   ↓
MowPSKit runtime
```

Source files are loaded as isolated units and combined into one runtime module.

Direct execution of the Source build reports `Mode = Ephemeral` and
`BuildMode = Source`.

### Compiled Build Mode

Used for normal deployment.

```text
src/
   ↓
build.ps1
   ↓
dist/MowPSKit.ps1
   ↓
MowPSKit runtime
```

The build process packages the source units, loader, resources, and the version from `version.txt` into a single portable PowerShell script. Direct or `irm | iex` execution reports `Ephemeral / Compiled`; the copy installed by setup reports `Installed / Compiled`.

Both modes are designed to expose the same public command interface.

## Project Structure

```text
MowPSKit/
├─ .github/
│  └─ workflows/
├─ configs/
│  └─ mowpskit.psd1
├─ scripts/
│  ├─ build.ps1
│  └─ normalize-source.ps1
├─ src/
│  ├─ loader.ps1
│  ├─ core/
│  ├─ internal/
│  ├─ functions/
│  └─ resources/
├─ tests/
│  └─ Framework.Tests.ps1
├─ setup.ps1
├─ version.txt
└─ dist/
   └─ MowPSKit.ps1
```

Configuration is centralized in:

```text
configs/mowpskit.psd1
```

The single product version source is the one-line root `version.txt`.
`src/loader.ps1` keeps its own independently maintained loader version.

## Development

Normalize the source files:

```powershell
& .\scripts\normalize-source.ps1
```

Run the framework test suite:

```powershell
& .\tests\Framework.Tests.ps1
```

Build the compiled artifact:

```powershell
& .\scripts\build.ps1
```

The generated program file will be written to:

```text
dist/MowPSKit.ps1
```

`dist/` is committed because the raw GitHub URL uses it directly. After every
validation succeeds, GitHub Actions commits only `dist/MowPSKit.ps1` when its
contents changed. Root `setup.ps1` is not a generated artifact.

## CI

Every push to `main` runs:

```text
Normalize
    ↓
Framework Tests
    ↓
Build
    ↓
PowerShell 7 Validation
    ↓
Windows PowerShell 5.1 Validation
    ↓
Commit generated dist
```

The workflow does not create tags, releases, or pull requests. Its generated
commit uses `[skip ci]`, and pushes made with the workflow token do not start a
second workflow run.

### Manual versioning

Before publishing a new version, change only:

```text
version.txt
```

Commit and push the source normally. After tests pass, GitHub Actions updates
only `dist/MowPSKit.ps1`. Tags and GitHub Releases are
optional and entirely manual; runtime installation and updates always follow
the current `main/dist/MowPSKit.ps1` artifact.

## Requirements

- Windows PowerShell 5.1  
  or
- PowerShell 7+

Git is only required for development.  
The compiled `MowPSKit.ps1` itself does not require Git.

## License

See [LICENSE.md](LICENSE.md).
