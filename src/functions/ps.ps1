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
