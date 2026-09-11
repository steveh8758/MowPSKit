# MowPSKit

**MowPSKit** is a lightweight PowerShell toolkit framework designed for modular development and single-file deployment.

During development, commands are separated into independent source files.  
When released, they are compiled into a single `MowPSKit.ps1`, making the toolkit easy to load on any Windows machine without installation.

## Features

- Modular PowerShell source structure
- Isolated source units
- Controlled public command exports
- Shared framework functions without polluting the global session
- Single-file compiled artifact
- Source Mode and Compiled Mode
- Runtime reload and unload
- Embedded resource support
- Deterministic builds
- UTF-8 without BOM
- Windows PowerShell 5.1 and PowerShell 7 compatible
- Automated testing and builds with GitHub Actions

## Quick Start

Load the latest compiled version directly from GitHub:

```powershell
irm https://raw.githubusercontent.com/steveh8758/MowPSKit/main/dist/MowPSKit.ps1 | iex
```

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
| `mow.reload` | Reload MowPSKit |
| `mow.unload` | Remove MowPSKit from the current session |

These management commands always use the `mow.*` namespace and are not affected by command prefix settings.

## How It Works

MowPSKit has two runtime modes.

### Source Mode

Used during development.

```text
src/
   ↓
loader.ps1
   ↓
MowPSKit runtime
```

Source files are loaded as isolated units and combined into one runtime module.

### Compiled Mode

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

The build process packages the source units, loader, and resources into a single portable PowerShell script.

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
└─ dist/
   └─ MowPSKit.ps1
```

Configuration is centralized in:

```text
configs/mowpskit.psd1
```

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

The generated file will be written to:

```text
dist/MowPSKit.ps1
```

## CI

GitHub Actions automatically validates the project by:

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
Publish dist/MowPSKit.ps1
```

The compiled artifact is generated only after the framework passes validation.

## Requirements

- Windows PowerShell 5.1  
  or
- PowerShell 7+

Git is only required for development and version metadata.  
The compiled `MowPSKit.ps1` itself does not require Git.

## License

See [LICENSE.md](LICENSE.md).