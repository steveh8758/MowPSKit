$MowExports = 'all'


function bypass-all {
    <#
    .SYNOPSIS
    Sets the execution policy for the current PowerShell process to Bypass.

    .DESCRIPTION
    Calls Set-ExecutionPolicy with Process scope, Bypass execution policy, and -Force.

    The change applies only to the current PowerShell process. The function does not modify execution policy at user or machine scope.

    Errors from Set-ExecutionPolicy are not suppressed or caught and are handled by PowerShell according to the caller's error-handling configuration.

    .EXAMPLE
    bypass-all

    Sets the current PowerShell process execution policy to Bypass without prompting for confirmation.
    #>

    Set-ExecutionPolicy `
        -Scope Process `
        -ExecutionPolicy Bypass `
        -Force

    return
}


function unblock-all {
    <#
    .SYNOPSIS
    Unblocks all files under the current directory recursively.

    .DESCRIPTION
    Enumerates files beneath the current location with Get-ChildItem -Recurse -File and passes each resulting file to Unblock-File.

    The operation includes files in the current directory and its recursively discovered subdirectories. Directories themselves are not passed to Unblock-File.

    The function operates relative to the caller's current location and does not provide a path parameter.

    Errors from Get-ChildItem or Unblock-File are not explicitly suppressed or caught and are handled by PowerShell according to the caller's error-handling configuration.

    This function modifies the unblock state of the files processed by Unblock-File.

    .EXAMPLE
    unblock-all

    Recursively enumerates files from the current directory and attempts to unblock each one.
    #>

    Get-ChildItem -Recurse -File | Unblock-File
    return
}


function bypass-file(
    [string]$Path,
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$ArgumentList
) {
    <#
    .SYNOPSIS
    Runs a PowerShell script file in a new PowerShell process with execution policy bypassed.

    .DESCRIPTION
    Resolves the supplied script path with Resolve-Path and launches it in a separate PowerShell process with -NoProfile, -ExecutionPolicy Bypass, and -File.

    When running under PowerShell 6 or later, the function launches pwsh.exe. On earlier PowerShell versions, it launches powershell.exe.

    Any remaining arguments supplied after Path are collected into ArgumentList and forwarded to the launched script after its -File argument.

    Resolve-Path uses -ErrorAction Stop, so failure to resolve the supplied path produces a terminating error and prevents the child PowerShell process from being started.

    The resolved path is not explicitly validated as a file before being passed to the selected PowerShell executable.

    The execution-policy override applies to the newly launched PowerShell process through its command-line options; this function does not call Set-ExecutionPolicy.

    Errors from resolving the path are not caught by the function. Errors or output produced by the launched PowerShell process are not intercepted or transformed by the function.

    .PARAMETER Path
    Specifies the path to pass to the child PowerShell process as its script file.

    The value is resolved with Resolve-Path before execution. The parameter has no explicit validation attributes and, if omitted, receives the default value for String.

    .PARAMETER ArgumentList
    Specifies arguments to forward to the script being launched.

    This parameter accepts String array values and is marked with ValueFromRemainingArguments, allowing additional unbound command-line arguments after Path to be collected into this parameter.

    The collected values are expanded positionally after the resolved script path when invoking the child PowerShell process.

    .EXAMPLE
    bypass-file .\setup.ps1

    Resolves setup.ps1 and runs it in a new PowerShell process without loading a profile and with execution policy set to Bypass for that invocation.

    .EXAMPLE
    bypass-file .\build.ps1 -Configuration Release

    Collects -Configuration and Release as remaining arguments and forwards them to build.ps1.

    .EXAMPLE
    bypass-file ..\scripts\deploy.ps1 server01 -Force

    Resolves the script path and forwards server01 and -Force to the launched script. PowerShell 6 or later uses pwsh.exe; earlier versions use powershell.exe.
    #>
    $Path = (Resolve-Path $Path -ErrorAction Stop).Path

    $powershell = if ($PSVersionTable.PSVersion.Major -ge 6) {
        'pwsh.exe'
    }
    else {
        'powershell.exe'
    }

    & $powershell `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $Path `
        @ArgumentList

    return
}


function install-winget-all([Parameter(Mandatory = $true)][string]$Path) {
    <#
    .SYNOPSIS
    Installs missing WinGet packages listed in a text file.

    .DESCRIPTION
    Reads one WinGet package ID per line from the specified UTF-8 text file.
    Empty lines, lines beginning with # or ;, and duplicate IDs are ignored.

    Each package is checked with winget list before installation. Already
    installed packages are skipped without upgrading, and missing packages
    are installed silently with agreements accepted and prompts disabled.

    Processing continues after individual failures. The function displays
    progress and a final report of successful, skipped, and failed packages.

    This function requires WinGet and the MowTools console helpers.

    .PARAMETER Path
    Specifies the path to the UTF-8 package list.

    .EXAMPLE
    install-winget-all .\packages.txt

    Installs missing packages from packages.txt in the current directory.

    .EXAMPLE
    install-winget-all 'D:\Setup\packages.txt'

    Installs missing packages from the specified absolute path.
    #>

    $Path = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Not a file: $Path"
    }

    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw 'WinGet is not installed or is not available in PATH.'
    }

    # Keep IDs unique without changing their original order.
    $seen = @{}
    $packages = [System.Collections.Generic.List[string]]::new()

    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop)) {
        $id = $line.Trim()

        if (-not $id -or $id.StartsWith('#') -or $id.StartsWith(';')) {
            continue
        }

        if (-not $seen.ContainsKey($id)) {
            $seen[$id] = $true
            $packages.Add($id)
        }
    }

    if ($packages.Count -eq 0) {
        Write-Status -Type Warning -Message "No packages found in: $Path"
        return
    }

    $success = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()
    $failed = [System.Collections.Generic.List[string]]::new()

    # Exit codes from Microsoft WinGet's AppInstaller return-code table.
    $notFound = -1978335212
    $alreadyInstalled = @(
        -1978335135  # PACKAGE_ALREADY_INSTALLED
        -1978334963  # INSTALL_ALREADY_INSTALLED
        -1978334962  # INSTALL_DOWNGRADE (a newer version exists)
    )

    Write-Text -Text 'WinGet Batch Installer' -Color Cyan -Style Bold -LinesAfter 1

    for ($index = 0; $index -lt $packages.Count; $index++) {
        $id = $packages[$index]

        Write-Step -Current ($index + 1) -Total $packages.Count -Message $id

        try {
            # An unexpected list error must not be treated as "not installed".
            & winget.exe list `
                --id $id `
                --exact `
                --disable-interactivity `
                --accept-source-agreements 2>&1 | Out-Null

            $checkExitCode = $LASTEXITCODE

            if ($checkExitCode -eq 0) {
                $skipped.Add($id)
                Write-Status -Type Warning -Message 'Skipped: already installed.'
                continue
            }

            if ($checkExitCode -ne $notFound) {
                throw "Package check failed (ExitCode: $checkExitCode)."
            }

            # --no-upgrade protects against an installation appearing after the check.
            & winget.exe install `
                --id $id `
                --exact `
                --source winget `
                --silent `
                --disable-interactivity `
                --accept-package-agreements `
                --accept-source-agreements `
                --no-upgrade 2>&1 | Out-Null

            $installExitCode = $LASTEXITCODE

            if ($installExitCode -eq 0) {
                $success.Add($id)
                Write-Status -Type Success -Message 'Installed successfully.'
            }
            elseif ($installExitCode -in $alreadyInstalled) {
                $skipped.Add($id)
                Write-Status -Type Warning -Message 'Skipped: already installed.'
            }
            else {
                throw "Installation failed (ExitCode: $installExitCode)."
            }
        }
        catch {
            $message = "$id - $($_.Exception.Message)"
            $failed.Add($message)
            Write-Status -Type Error -Message $message
        }
    }

    # Display totals and names in three distinct result groups.
    Write-Text -Text 'Installation Summary' -Color Cyan -Style Bold -LinesBefore 1
    Write-KeyValue -Data ([ordered]@{
        Total   = $packages.Count
        Success = $success.Count
        Skipped = $skipped.Count
        Failed  = $failed.Count
    })

    foreach ($group in @(
        @{ Name = 'SUCCESS'; Items = $success; Color = 'Green' }
        @{ Name = 'SKIPPED'; Items = $skipped; Color = 'Yellow' }
        @{ Name = 'FAILED';  Items = $failed;  Color = 'Red' }
    )) {
        Write-Text `
            -Text "[$($group.Name)]" `
            -Color $group.Color `
            -Style Bold `
            -LinesBefore 1

        foreach ($item in $group.Items) {
            Write-Text -Text "  $item" -Color $group.Color
        }
    }

    return
}
