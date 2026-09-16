$MowExports = 'all'

function text {
    <#
    .SYNOPSIS
    Writes styled text to the console.

    .DESCRIPTION
    Public interface for the internal Write-Text command.

    Supports colors, styles, spacing, timestamps, centering,
    and optional file logging.
    #>
    [CmdletBinding()]
    param(
        [Parameter(
            Mandatory,
            Position = 0
        )]
        [Alias('T')]
        [string[]]$Text,

        [Alias('C')]
        [ConsoleColor[]]$Color,

        [Alias('B')]
        [ConsoleColor[]]$BackgroundColor,

        [string[]]$Style,

        [int]$StartTab = 0,

        [int]$LinesBefore = 0,

        [int]$LinesAfter = 0,

        [int]$StartSpaces = 0,

        [string]$LogFile,

        [string]$DateTimeFormat = 'yyyy-MM-dd HH:mm:ss',

        [bool]$LogTime = $true,

        [int]$LogRetry = 2,

        [switch]$IgnoreLogError,

        [string]$Encoding = 'UTF8',

        [switch]$ShowTime,

        [switch]$NoNewLine,

        [switch]$NoConsoleOutput,

        [switch]$HorizontalCenter
    )

    Write-Text @PSBoundParameters
}


function log {
    <#
    .SYNOPSIS
    Manages and writes structured log entries.

    .PARAMETER Init
    Starts a new logging session.

    .PARAMETER End
    Ends the logging session and displays all log paths.

    .PARAMETER Message
    Message to write.

    .PARAMETER Level
    Log severity level.

    .PARAMETER Component
    Component that generated the log entry.

    .PARAMETER ExtraFile
    Additional explicit log files.

    .PARAMETER ExtraFolder
    Additional folders that receive a timestamped copy of the log.

    .PARAMETER Append
    Preserves existing contents of explicit log files.
    #>
    [CmdletBinding()]
    param(
        [switch]$Init,

        [switch]$End,

        [string]$Message,

        [string]$Level,

        [string]$Component,

        [string[]]$ExtraFile,

        [string[]]$ExtraFolder,

        [switch]$Append
    )

    Write-Log @PSBoundParameters
}
