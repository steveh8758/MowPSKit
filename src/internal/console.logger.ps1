$MowInternal = 'Write-Log'


$script:LogFiles = @()

function Initialize-Log {
    <#
    .SYNOPSIS
    Initializes a logging session.

    .PARAMETER ExtraFile
    Additional explicit log file paths.

    Existing files are cleared by default when a new logging session starts.
    Use -Append to preserve existing contents.

    .PARAMETER ExtraFolder
    Additional folders that receive a timestamped copy of the log.

    .PARAMETER Append
    Preserves existing log contents instead of clearing them during
    initialization.
    #>
    [CmdletBinding()]
    param (
        [string[]]$ExtraFile = @(),

        [string[]]$ExtraFolder = @(),

        [switch]$Append
    )

    foreach ($file in $ExtraFile) {
        if ([string]::IsNullOrWhiteSpace($file)) {
            throw 'ExtraFile cannot contain a null, empty, or whitespace path.'
        }
    }

    foreach ($folder in $ExtraFolder) {
        if ([string]::IsNullOrWhiteSpace($folder)) {
            throw 'ExtraFolder cannot contain a null, empty, or whitespace path.'
        }
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $fileName = "MowPSKit_${timestamp}_${PID}.log"

    $defaultFolder = [System.IO.Path]::Combine(
        [System.IO.Path]::GetTempPath(),
        'MowPSKit',
        'Logs'
    )

    $candidateLogFiles = [System.Collections.Generic.List[string]]::new()
    $candidateLogFiles.Add(
        [System.IO.Path]::Combine($defaultFolder, $fileName)
    )

    foreach ($folder in $ExtraFolder) {
        $candidateLogFiles.Add(
            [System.IO.Path]::Combine($folder, $fileName)
        )
    }

    foreach ($file in $ExtraFile) {
        $candidateLogFiles.Add($file)
    }

    # Path comparison follows the platform's usual case sensitivity.
    $pathComparer = if (
        [System.Environment]::OSVersion.Platform -eq
        [System.PlatformID]::Win32NT
    ) {
        [System.StringComparer]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparer]::Ordinal
    }

    $seenPaths = [System.Collections.Generic.HashSet[string]]::new(
        $pathComparer
    )
    $uniqueLogFiles = [System.Collections.Generic.List[string]]::new()

    foreach ($candidate in $candidateLogFiles) {
        $fullPath = [System.IO.Path]::GetFullPath($candidate)

        if ($seenPaths.Add($fullPath)) {
            $uniqueLogFiles.Add($fullPath)
        }
    }

    $script:LogFiles = $uniqueLogFiles.ToArray()
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

    foreach ($logFile in $script:LogFiles) {
        $directory = [System.IO.Path]::GetDirectoryName($logFile)

        if (-not [System.IO.Directory]::Exists($directory)) {
            [System.IO.Directory]::CreateDirectory($directory) | Out-Null
        }

        if ($Append -and [System.IO.File]::Exists($logFile)) {
            continue
        }

        # Starting a new session clears an existing explicit log file unless
        # -Append was requested. Generated timestamped files are normally new.
        [System.IO.File]::WriteAllText(
            $logFile,
            '',
            $utf8NoBom
        )
    }
}


function Write-Log {
    <#
    .SYNOPSIS
    Manages and writes structured log entries.

    .DESCRIPTION
    Log format:

        TIMESTAMP [LEVEL] [COMPONENT] MESSAGE

    Logs use UTF-8 without BOM.

    A default timestamped log is automatically created under the platform's
    temporary directory in:

        MowPSKit/Logs

    .PARAMETER Init
    Starts a new logging session.

    .PARAMETER End
    Ends the logging session and displays all log paths.

    .PARAMETER Message
    Message to write.

    .PARAMETER Level
    Log severity level.

    .PARAMETER Component
    Component that generated the log entry. Cannot be empty or whitespace.

    .PARAMETER ExtraFile
    Additional explicit log files. Existing contents are cleared at session
    initialization unless -Append is used.

    .PARAMETER ExtraFolder
    Additional folders that receive a timestamped copy of the log.

    .PARAMETER Append
    When used with -Init, preserves existing contents of explicit log files.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Write')]
    param (
        [Parameter(
            Mandatory,
            ParameterSetName = 'Init'
        )]
        [switch]$Init,

        [Parameter(
            Mandatory,
            ParameterSetName = 'End'
        )]
        [switch]$End,

        [Parameter(
            Mandatory,
            Position = 0,
            ParameterSetName = 'Write'
        )]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(ParameterSetName = 'Write')]
        [ValidateSet(
            'DEBUG',
            'INFO',
            'WARNING',
            'ERROR',
            'CRITICAL'
        )]
        [string]$Level = 'INFO',

        [Parameter(ParameterSetName = 'Write')]
        [ValidateScript({
            if ([string]::IsNullOrWhiteSpace($_)) {
                throw 'Component cannot be null, empty, or whitespace.'
            }
            $true
        })]
        [string]$Component = 'General',

        [Parameter(ParameterSetName = 'Init')]
        [string[]]$ExtraFile = @(),

        [Parameter(ParameterSetName = 'Init')]
        [string[]]$ExtraFolder = @(),

        [Parameter(ParameterSetName = 'Init')]
        [switch]$Append
    )

    if ($Init) {
        Initialize-Log `
            -ExtraFile $ExtraFile `
            -ExtraFolder $ExtraFolder `
            -Append:$Append

        return
    }

    if ($End) {
        if ($script:LogFiles.Count -eq 0) {
            return
        }

        foreach ($logFile in $script:LogFiles) {
            Write-Text `
                -Text 'Log path: ', $logFile `
                -Color DarkGray, Cyan
        }

        $script:LogFiles = @()
        return
    }

    # Automatically initialize if no logging session exists.
    if ($script:LogFiles.Count -eq 0) {
        Initialize-Log
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    # Keep every log entry on one physical line and normalize the component.
    $normalizedMessage = $Message -replace '[\r\n]+', ' '
    $normalizedComponent = (
        $Component -replace '[\r\n]+', ' '
    ).Trim()

    $logLine = '{0} [{1}] [{2}] {3}' -f (
        $timestamp,
        $Level.ToUpperInvariant(),
        $normalizedComponent,
        $normalizedMessage
    )

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

    foreach ($logFile in $script:LogFiles) {
        [System.IO.File]::AppendAllText(
            $logFile,
            $logLine + [Environment]::NewLine,
            $utf8NoBom
        )
    }
}
