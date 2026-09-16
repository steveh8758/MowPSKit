# MowTools Architecture & Build Specification

**Version:** 1.0  
**Target Runtime:** Windows PowerShell 5.1+ / PowerShell 7.x  
**Primary Language:** PowerShell  
**Status:** Architecture specification

---

# Implementation Quick Start

Local Source Mode reads the modular source tree directly:

```powershell
.\mow_funcs.ps1
```

Build the self-contained artifact before publishing it. `ArtifactUrl` is saved
inside the artifact so `mow.reload` knows the one URL it should fetch:

```powershell
.\build.ps1 -ArtifactUrl 'https://example.com/mow_funcs.ps1'
```

The generated `dist/mow_funcs.ps1` also works as a normal local script:

```powershell
.\dist\mow_funcs.ps1
```

Upload that generated file, then Cloud Mode can load it with one request:

```powershell
irm 'https://example.com/mow_funcs.ps1' | iex
```

The builder writes the artifact as UTF-8 without a BOM. This keeps
`irm | iex` compatible with Windows PowerShell 5.1 even when a basic HTTP
server does not send an explicit UTF-8 charset.

Use `mow.reload` to reload the current local source tree or the configured
compiled artifact. Use `mow.unload` to remove the complete runtime.

---

# 1. Purpose

MowTools is a modular PowerShell utility framework designed around the following principles:

1. Source code must remain modular and easy to maintain.
2. Runtime must expose only explicitly public commands to the user's PowerShell session.
3. Individual source files must support file-private functions without name collisions across files.
4. Selected functions may be shared internally across MowTools without becoming public commands.
5. The complete project must be compilable into a single self-contained `.ps1` file.
6. Local development and compiled/cloud execution must have equivalent behavior.
7. `mow_funcs.ps1` and `loader.ps1` should require little or no modification when adding normal features.
8. No manually maintained dependency manifest is required.
9. All runtime behavior must remain compatible with Windows PowerShell 5.1.

The source architecture and the distribution architecture are intentionally separate.

---

# 2. Repository Layout

The expected PowerShell package structure is:

```text
ps1/
│
├─ mow_funcs.ps1
│
└─ mow_funcs/
   │
   ├─ loader.ps1
   │
   ├─ core/
   │  └─ ...
   │
   ├─ internal/
   │  └─ ...
   │
   ├─ functions/
   │  └─ ...
   │
   └─ resources/
      └─ ...
```

Example:

```text
ps1/
├─ mow_funcs.ps1
│
└─ mow_funcs/
   ├─ loader.ps1
   │
   ├─ core/
   │  └─ console/
   │     └─ text.ps1
   │
   ├─ internal/
   │  └─ console/
   │     └─ log.ps1
   │
   ├─ functions/
   │  ├─ port.ps1
   │  └─ network/
   │     └─ dns.ps1
   │
   └─ resources/
      ├─ config.json
      └─ template.txt
```

The directories `core`, `internal`, `functions`, and `resources` are architectural categories.

Their names MUST NOT become part of a public command namespace.

---

# 3. High-Level Architecture

MowTools uses three visibility levels:

```text
File Private
    ↓
MowTools Internal
    ↓
User Public
```

These levels MUST remain distinct.

A function being public does not automatically mean it is shared internally.

A function being shared internally does not automatically mean it is public.

A function MAY intentionally be both MowTools Internal and User Public.

---

# 4. Source Unit

Every `.ps1` under:

```text
internal/**
functions/**
```

is treated as an independent **Source Unit**.

Each Source Unit MUST have an isolated scope.

Example:

```text
internal/log.ps1

function Get-Path {}
```

and:

```text
functions/mkfolder.ps1

function Get-Path {}
```

are valid simultaneously.

They represent:

```text
log.ps1::Get-Path
mkfolder.ps1::Get-Path
```

and MUST NOT overwrite each other.

Therefore, implementations MUST NOT simply dot-source every `internal/*.ps1` and `functions/*.ps1` into one common scope.

---

# 5. File-Private Functions

A normal function defined inside an `internal` or `functions` Source Unit is File Private unless promoted through metadata.

Example:

```powershell
function Get-Path {
    ...
}

function Format-Message {
    ...
}
```

If neither function is referenced by `$MowInternal` nor `$MowExports`, both remain private to that Source Unit.

They MUST remain usable by other functions in the same file.

They MUST NOT appear in the user's PowerShell session.

They MUST NOT automatically become visible to other MowTools Source Units.

File-private functions in different Source Units MAY use identical names.

---

# 6. `$MowInternal`

`$MowInternal` controls which functions defined by an `internal` or `functions` Source Unit become shared MowTools Internal APIs.

Example:

```powershell
$MowInternal = @(
    'Write-Status'
    'Write-KeyValue'
)
```

These functions become callable by other MowTools Source Units but MUST NOT automatically become public commands.

## 6.1 Supported values

### Empty / undefined

```powershell
$MowInternal = @()
```

or:

```powershell
$MowInternal = $null
```

or no `$MowInternal` variable at all.

Meaning:

```text
Expose nothing as MowTools Internal.
```

All functions remain File Private unless affected by `$MowExports`.

### `all`

```powershell
$MowInternal = 'all'
```

Meaning:

```text
All functions defined by this Source Unit become MowTools Internal.
```

`all` MUST be case-insensitive.

Therefore these are equivalent:

```text
all
ALL
All
```

### Selected functions

```powershell
$MowInternal = @(
    'Write-Status'
    'Write-KeyValue'
)
```

Only the listed functions become MowTools Internal.

A single string SHOULD also be accepted:

```powershell
$MowInternal = 'Write-Status'
```

---

# 7. `$MowExports`

`$MowExports` controls which functions become User Public APIs.

Its syntax MUST be identical to `$MowInternal`.

## 7.1 Empty / undefined

```powershell
$MowExports = @()
```

or:

```powershell
$MowExports = $null
```

or no variable.

Meaning:

```text
Export nothing.
```

## 7.2 Export all

```powershell
$MowExports = 'all'
```

Meaning:

```text
Export every function defined by this Source Unit.
```

`all` MUST be case-insensitive.

## 7.3 Selected exports

```powershell
$MowExports = @(
    'fp'
    'kp'
)
```

Only those functions become User Public APIs.

---

# 8. `$MowInternal` and `$MowExports` May Overlap

A function MAY appear in both variables.

Example:

```powershell
$MowInternal = @(
    'Write-Log'
)

$MowExports = @(
    'Write-Log'
)
```

This means:

```text
Write-Log
├─ callable by other MowTools Source Units
└─ callable by the user through its generated public command name
```

This is valid and MUST NOT produce an error.

---

# 9. Core Directory

`core/**` has special behavior.

Every function defined under `core/**` is automatically considered:

```text
MowTools Internal
```

Therefore every MowTools Source Unit may use core functions.

Example:

```text
core/console/text.ps1
```

```powershell
function Get-DisplayWidth {
    ...
}

function Write-Text {
    ...
}
```

Both functions are automatically available internally.

No `$MowInternal` declaration is necessary.

`$MowInternal` SHOULD NOT be used inside `core/**`.

However, Core functions are NOT automatically User Public.

Public visibility is still controlled exclusively by `$MowExports`.

Example:

```powershell
$MowExports = @(
    'Write-Text'
)

function Get-DisplayWidth {
    ...
}

function Write-Text {
    ...
}
```

Result:

```text
Get-DisplayWidth
    MowTools Internal only

Write-Text
    MowTools Internal
    +
    User Public
```

Therefore:

> `core` controls internal availability.  
> `$MowExports` controls public availability.

---

# 10. Visibility Summary

| Function type | Same Source Unit | Other MowTools Source Units | User Session |
|---|:---:|:---:|:---:|
| Normal function in `internal/functions` | Yes | No | No |
| `$MowInternal` function | Yes | Yes | No |
| `$MowExports` only | Yes | No | Yes |
| `$MowInternal` + `$MowExports` | Yes | Yes | Yes |
| Normal `core` function | Yes | Yes | No |
| `core` + `$MowExports` | Yes | Yes | Yes |

---

# 11. Collision Rules

PowerShell names are effectively case-insensitive for the purposes of collision checking.

The loader/compiler MUST validate collisions before replacing the currently running MowTools module.

## 11.1 File Private ↔ File Private

Allowed.

Example:

```text
internal/log.ps1       → Get-Path
functions/folder.ps1   → Get-Path
```

No error.

These functions live in independent Source Units.

## 11.2 Core ↔ Core

Forbidden.

Example:

```text
core/a.ps1 → Get-Path
core/b.ps1 → Get-Path
```

Must produce an error and abort loading.

Example error:

```text
MowTools internal function collision: Get-Path
```

## 11.3 `$MowInternal` ↔ `$MowInternal`

Forbidden.

Example:

```text
internal/log.ps1
    $MowInternal = Get-Path

functions/folder.ps1
    $MowInternal = Get-Path
```

Must produce an error and abort loading.

## 11.4 Core ↔ `$MowInternal`

Forbidden.

If a Core function already exposes:

```text
Get-Path
```

another Source Unit MUST NOT register:

```powershell
$MowInternal = 'Get-Path'
```

The loader MUST report the collision and stop.

## 11.5 Public command ↔ Public command

The final generated public command names MUST be unique.

Any collision MUST produce an error and stop loading.

Silent overriding is forbidden.

## 11.6 Reserved management commands

The following final command names are permanently reserved:

```text
mow.ver
mow.reload
mow.unload
```

No source file may create a public command with these final names.

## 11.7 Duplicate declarations within one Source Unit

A Source Unit MUST NOT define the same function name more than once.

This SHOULD be detected and treated as an error.

---

# 12. Private Name Shadowing

File-private functions MAY share a name with functions that exist outside their Source Unit.

A local File Private function takes precedence when referenced from functions belonging to that same Source Unit.

Example:

```text
Shared Core:
    Get-Path

internal/log.ps1:
    private Get-Path
```

Inside `log.ps1`, calls to:

```powershell
Get-Path
```

refer to the Source Unit's private implementation.

Other Source Units continue to see the shared Core implementation.

This behavior MUST remain deterministic in both Source and Compiled modes.

---

# 13. Namespace Generation

Public APIs are namespace-based.

The category directories:

```text
core
internal
functions
```

MUST NOT appear in the public namespace.

Everything below the category root contributes to the namespace.

The filename without `.ps1` is also part of the namespace.

## Example 1

Source:

```text
functions/port.ps1
```

Export:

```powershell
$MowExports = @(
    'fp'
    'kp'
)
```

Namespace:

```text
port
```

Commands with `Prefix = mt`, `Separator = .`:

```text
mt.port.fp
mt.port.kp
```

## Example 2

Source:

```text
functions/network/port.ps1
```

Namespace:

```text
network.port
```

Commands:

```text
mt.network.port.fp
mt.network.port.kp
```

## Example 3

Source:

```text
internal/console/log.ps1
```

Export:

```powershell
$MowExports = 'Write-Log'
```

Public command:

```text
mt.console.log.Write-Log
```

NOT:

```text
mt.internal.console.log.Write-Log
```

## Example 4

Source:

```text
core/console/text.ps1
```

Export:

```powershell
$MowExports = 'Write-Text'
```

Public command:

```text
mt.console.text.Write-Text
```

NOT:

```text
mt.core.console.text.Write-Text
```

---

# 14. Prefix and Separator

Normal public command naming follows:

```text
[Prefix + Separator] + Namespace + "." + Function
```

The namespace-to-function separator is always:

```text
.
```

`Separator` applies only between the optional Prefix and the namespace.

## Examples

### Prefix

```text
Prefix    = mt
Separator = .
```

Result:

```text
mt.port.fp
```

### Different separator

```text
Prefix    = mt
Separator = -
```

Result:

```text
mt-port.fp
```

### Prefix with empty separator

```text
Prefix    = mt
Separator = ""
```

Result:

```text
mtport.fp
```

### No Prefix

```text
Prefix    = ""
Separator = "."
```

Result:

```text
port.fp
```

### No Prefix but Separator supplied

```text
Prefix    = ""
Separator = "-"
```

Result:

```text
port.fp
```

If Prefix is empty, Separator MUST be ignored.

### Neither configured

```text
Prefix    = ""
Separator = ""
```

Result:

```text
port.fp
```

The namespace MUST always remain present.

A public function MUST NOT collapse to only:

```text
fp
```

---

# 15. Management Commands

MowTools has exactly these built-in management commands:

```text
mow.ver
mow.reload
mow.unload
```

These names are FIXED.

They MUST NOT be affected by:

```text
Prefix
Separator
Namespace
```

For example, even when:

```text
Prefix    = mt
Separator = -
```

normal commands may look like:

```text
mt-port.fp
```

but management commands remain:

```text
mow.ver
mow.reload
mow.unload
```

Never:

```text
mt-ver
mt.reload
ver
reload
unload
```

---

# 16. Management Command Semantics

## `mow.ver`

Displays at minimum:

```text
MowTools
Loader version
Functions/build version when available
Configured Prefix
Configured Separator
```

## `mow.reload`

Reload behavior depends on runtime mode.

### Local Source Mode

Reload current source files from the local MowTools source tree and rebuild the MowTools runtime.

Typical development workflow:

```text
edit functions/port.ps1
        ↓
mow.reload
        ↓
new implementation becomes active
```

### Cloud / Compiled Mode

Fetch the newest compiled MowTools artifact and rebuild/replace the current MowTools runtime.

Cloud reload MUST NOT individually download:

```text
core/**
internal/**
functions/**
resources/**
```

## `mow.unload`

Unload the entire MowTools runtime.

Conceptually:

```powershell
Remove-Module MowTools -Force
```

All public APIs and internal implementation state belonging to MowTools SHOULD disappear together.

---

# 17. Atomic Reload

Reload MUST be atomic from the user's perspective.

The existing working MowTools runtime SHOULD remain active until the replacement runtime has successfully:

1. downloaded/read its source,
2. passed syntax validation,
3. passed metadata validation,
4. passed collision validation,
5. created the replacement runtime successfully.

Only after the new runtime is known to be valid should the old MowTools runtime be removed.

If replacement creation fails, the previous working runtime SHOULD remain available.

---

# 18. Successful Load Output

After a successful load or reload, the loader MUST display that MowTools loaded successfully.

It MUST also display the fixed management commands.

Recommended output:

```text
✓ MowTools loaded.
  Prefix     : mt.
  Management : mow.ver  mow.reload  mow.unload
```

Without a Prefix:

```text
✓ MowTools loaded.
  Prefix     : <none>
  Management : mow.ver  mow.reload  mow.unload
```

The loader SHOULD NOT print every public command during normal startup.

---

# 19. Load Order

The logical loading order is:

```text
1. core/**
2. internal/**
3. functions/**
4. management commands
5. public API registration
```

Within a category, discovery MUST be deterministic.

A suitable rule is sorting by relative path.

However, source code SHOULD NOT rely on alphabetical filenames for logical dependency order.

For example, architecture SHOULD NOT depend on:

```text
01_base.ps1
02_helper.ps1
03_function.ps1
```

to function correctly.

Dependencies should instead be expressed through the Core/Internal visibility model.

---

# 20. Top-Level Source Rules

Files under:

```text
core/**
internal/**
functions/**
```

SHOULD primarily contain:

```text
function definitions
class definitions when necessary
metadata variables
safe module-state initialization
constants/configuration initialization
```

They SHOULD NOT perform operational side effects merely because MowTools is being loaded.

Avoid top-level operations such as:

```powershell
Remove-Item ...
Stop-Process ...
Start-Process ...
Invoke-WebRequest ...
```

unless the operation is strictly required for safe initialization.

Importing/loading MowTools should not itself perform unrelated system modifications.

---

# 21. Metadata Validation

For every Source Unit, the loader/compiler MUST validate `$MowInternal` and `$MowExports`.

Example invalid source:

```powershell
$MowExports = 'Write-Lgo'

function Write-Log {
    ...
}
```

The loader MUST NOT silently ignore the typo.

It MUST fail with an error similar to:

```text
Exported function 'Write-Lgo' was not defined by internal/log.ps1.
```

The same validation applies to `$MowInternal`.

A Source Unit may only register functions that it actually defines.

It MUST NOT use `$MowExports` or `$MowInternal` to alter ownership of a function defined by another Source Unit.

Duplicate names inside metadata arrays SHOULD be de-duplicated or rejected consistently.

---

# 22. Source Discovery

Normal feature development MUST NOT require editing `loader.ps1`.

The loader/compiler discovers source files recursively using directory convention.

Conceptually:

```text
core/**/*.ps1
internal/**/*.ps1
functions/**/*.ps1
resources/**/*
```

Adding:

```text
functions/docker.ps1
```

or:

```text
functions/windows/service.ps1
```

must not require registering that filename in:

```text
mow_funcs.ps1
loader.ps1
manifest.json
```

No manually maintained source manifest is required.

---

# 23. Resources

`resources/**` contains non-executable package assets.

Examples:

```text
JSON
XML
TXT
templates
configuration data
binary assets
```

Resources MUST NOT be automatically executed.

All resources MUST be capable of being embedded into the compiled single-file artifact.

Text resources may be embedded directly.

Binary resources may be encoded, for example using Base64.

The compiled Cloud artifact MUST NOT require the original repository resource files at runtime.

---

# 24. Local Source Mode

Local development uses the modular source tree directly.

Conceptually:

```text
mow_funcs.ps1
      ↓
loader.ps1
      ↓
core/**
internal/**
functions/**
resources/**
      ↓
MowTools runtime
```

Local Source Mode exists primarily for:

```text
development
debugging
testing
rapid reload
```

Developers SHOULD NOT need to compile a bundle after every edit.

---

# 25. Cloud / Distribution Mode

Cloud execution uses a precompiled single-file artifact.

Runtime MUST NOT perform individual downloads for:

```text
core/**
internal/**
functions/**
resources/**
```

Conceptually:

```text
GitHub source tree
        ↓
Compiler
        ↓
single compiled .ps1
        ↓
Cloud bootstrap / irm | iex
        ↓
MowTools runtime
```

The compiled artifact is a build product, not the source of truth.

---

# 26. Bootstrap

`ps1/mow_funcs.ps1` is the stable bootstrap layer.

It SHOULD contain as little feature-specific knowledge as possible.

It MUST NOT need modification merely because a new file is added under:

```text
core/
internal/
functions/
resources/
```

Its responsibilities should be limited to locating/loading the appropriate MowTools runtime entry point or compiled artifact.

The bootstrap is not responsible for individual feature dependencies.

---

# 27. Loader

`loader.ps1` defines runtime assembly behavior.

It is responsible for:

```text
source discovery
Source Unit creation
scope isolation
Core/Internal registration
metadata handling
collision validation
namespace generation
public command generation
management commands
atomic replacement
load status output
```

It SHOULD NOT contain normal user utility functions.

Adding ordinary functionality should normally require changing only source files under:

```text
core/
internal/
functions/
resources/
```

---

# 28. Compiler / Bundle

MowTools must retain the ability to compile the entire modular source tree into one `.ps1`.

The compiler may be implemented as:

```text
build.ps1
Build-MowTools
CI workflow
```

or equivalent.

The exact compiler implementation is not prescribed by this specification.

The compiler MUST preserve runtime semantics.

---

# 29. Critical Build Invariant

This is one of the most important requirements in the entire architecture:

> **Source Mode and Compiled Mode MUST produce equivalent visibility, namespace, collision, and scope behavior.**

If:

```text
internal/log.ps1::Get-Path
```

and:

```text
functions/mkfolder.ps1::Get-Path
```

are isolated in Source Mode, they MUST remain isolated after compilation.

The compiler MUST NOT flatten Source Units in a way that causes private helpers to collide.

Likewise:

```text
$MowInternal
$MowExports
core shared functions
public namespace
```

must behave identically in both modes.

A compiler that merely concatenates every file into one flat PowerShell scope violates this specification.

---

# 30. Runtime Module

Although the source is split across many files, the user's runtime should conceptually behave as one product:

```text
MowTools
```

The user's Global Session should contain only generated Public APIs plus:

```text
mow.ver
mow.reload
mow.unload
```

Implementation helpers must remain hidden from the Global Session.

The runtime may internally create additional private implementation scopes/modules if necessary to implement Source Unit isolation.

Those implementation details MUST NOT become user-facing APIs.

---

# 31. Minimum Runtime

Minimum supported runtime:

```text
Windows PowerShell 5.1
```

The implementation must also support modern:

```text
PowerShell 7.x
```

Code generation, loader logic, scope isolation, resource embedding, and public command creation MUST NOT depend exclusively on PowerShell 7 features.

When choosing between equivalent implementations, prefer the implementation compatible with PowerShell 5.1.

---

# 32. Example: Complete Source Unit

File:

```text
functions/port.ps1
```

```powershell
$MowInternal = @(
    'Get-PortInfo'
)

$MowExports = @(
    'fp'
    'kp'
)


function Get-ProcessName {
    param(
        [int]$ProcessId
    )

    # File-private helper.
}


function Get-PortInfo {
    param(
        [int]$Port
    )

    # Shared MowTools Internal API.
}


function fp {
    param(
        [int]$Port
    )

    # Public command.
}


function kp {
    param(
        [int]$Port
    )

    # Public command.
}
```

Given:

```text
Prefix    = mt
Separator = .
```

visibility becomes:

```text
Get-ProcessName
    File Private

Get-PortInfo
    MowTools Internal

fp
    User Public → mt.port.fp

kp
    User Public → mt.port.kp
```

Management remains:

```text
mow.ver
mow.reload
mow.unload
```

---

# 33. Example: Internal Logger

File:

```text
internal/console/log.ps1
```

```powershell
$MowInternal = @(
    'Write-LogInternal'
)

$MowExports = @(
    'Write-Log'
)


function Get-Path {
    # File private.
}


function Format-Log {
    # File private.
}


function Write-LogInternal {
    # Shared by MowTools source.
}


function Write-Log {
    # Public API.
}
```

Given:

```text
Prefix    = mt
Separator = .
```

the user sees:

```text
mt.console.log.Write-Log
```

Other MowTools Source Units may call:

```text
Write-LogInternal
```

but the user does not see it.

`Get-Path` and `Format-Log` remain private to `log.ps1`.

---

# 34. Example: Core

File:

```text
core/console/text.ps1
```

```powershell
$MowExports = @(
    'Write-Text'
)


function Get-DisplayWidth {
    ...
}


function Resolve-ConsoleStyle {
    ...
}


function Write-Text {
    ...
}
```

All three functions are available to every MowTools Source Unit because they are Core functions.

Only:

```text
Write-Text
```

is User Public.

With:

```text
Prefix    = mt
Separator = .
```

the user command becomes:

```text
mt.console.text.Write-Text
```

---

# 35. Architectural Rules for AI Implementers

When modifying MowTools, an AI or developer MUST NOT:

```text
• flatten all Source Units into one shared function scope
• expose File Private functions globally
• infer public visibility from directory name
• automatically export everything under functions/
• make core/internal/functions part of the user namespace
• allow Core or MowInternal shared-name collisions
• silently override public commands
• rename mow.ver / mow.reload / mow.unload based on Prefix
• require manual manifest updates when adding ordinary source files
• make Cloud runtime download each source file individually
• make compiled execution depend on external resources/
• use PowerShell 7-only syntax without a PowerShell 5.1-compatible alternative
```

An AI or developer MUST preserve:

```text
• File Private isolation
• MowTools Internal sharing
• explicit $MowExports visibility
• explicit $MowInternal visibility
• Core shared visibility
• namespace generation
• Prefix/Separator behavior
• fixed management commands
• atomic reload
• Source/Compiled behavioral equivalence
```

---

# 36. Design Philosophy

The architecture separates four independent concerns:

```text
Directory
    → responsibility

Source Unit scope
    → private ownership

$MowInternal / Core
    → internal sharing

$MowExports
    → public API

Compiler
    → distribution format
```

These concerns MUST remain separate.

In particular:

> **Directory location does not determine public visibility.**

> **Public visibility does not imply internal sharing.**

> **Internal sharing does not imply public visibility.**

> **Compilation must not weaken scope isolation.**

The desired end result is:

```text
Modular source
+
explicit API boundaries
+
clean PowerShell session
+
single-file distribution
+
minimal bootstrap/loader maintenance
```

---

# 37. Canonical Example

Source:

```text
mow_funcs/
├─ loader.ps1
│
├─ core/
│  └─ console/
│     └─ text.ps1
│
├─ internal/
│  └─ console/
│     └─ log.ps1
│
├─ functions/
│  ├─ port.ps1
│  └─ network/
│     └─ dns.ps1
│
└─ resources/
   └─ config.json
```

With:

```text
Prefix    = mt
Separator = .
```

the final user-facing session might contain:

```text
mt.console.text.Write-Text
mt.console.log.Write-Log

mt.port.fp
mt.port.kp

mt.network.dns.lookup

mow.ver
mow.reload
mow.unload
```

Internally MowTools may contain many more functions such as:

```text
Get-DisplayWidth
Resolve-ConsoleStyle
Write-LogInternal
Get-PortInfo
Get-Path
Format-Log
...
```

These MUST NOT pollute the user's PowerShell session unless explicitly listed through `$MowExports`.

---

# 38. Final Authority

When implementation details conflict with this specification, this specification takes precedence.

The most important invariants are:

```text
1. Private functions remain private to their Source Unit.
2. Core functions are shared internally by default.
3. $MowInternal explicitly promotes Source Unit functions to shared internal APIs.
4. $MowExports exclusively controls User Public APIs.
5. Shared internal names may not collide.
6. Public final command names may not collide.
7. Namespace excludes core/internal/functions category directories.
8. Namespace itself is always preserved.
9. Prefix and Separator affect only normal public APIs.
10. mow.ver / mow.reload / mow.unload are permanently fixed.
11. Cloud distribution uses one compiled artifact.
12. All resources are embeddable.
13. Source and Compiled modes must behave equivalently.
14. Windows PowerShell 5.1 is the minimum supported runtime.
