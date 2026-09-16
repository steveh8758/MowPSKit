# PSWriteText
# https://github.com/steveh8758/PSWriteText
#
# Copyright (c) 2026 Steven Hsin
#
# PSWriteText is derived from and extends PSWriteColor by EvotecIT:
# https://github.com/EvotecIT/PSWriteColor
#
# Original idea attribution:
# Josh - https://stackoverflow.com/users/81769/josh
#
# Licensed under the MIT License.
# See the LICENSE.md file in the project repository for full license information.
#
# Supports Windows PowerShell 5.1 and PowerShell 7.x (pwsh).
# PowerShell 7.x operation has been manually verified by the maintainer.
# This is a source-code notice only; no runtime version check is intentionally performed.


function Get-AnsiStyleSequence {
    <#
    .SYNOPSIS
    Converts a Write-Text style definition to ANSI prefix and suffix sequences.

    .PARAMETER Style
    Style name or a '+' separated style combination.

    .OUTPUTS
    PSCustomObject with Prefix and Suffix properties.
    #>
    [CmdletBinding()]
    param (
        [AllowEmptyString()]
        [string]$Style = 'None'
    )

    $styleMap = @{
        Bold      = @{ Enable = 1; Disable = 22 }
        Dim       = @{ Enable = 2; Disable = 22 }
        Italic    = @{ Enable = 3; Disable = 23 }
        Underline = @{ Enable = 4; Disable = 24 }
        Blink     = @{ Enable = 5; Disable = 25 }
        Reverse   = @{ Enable = 7; Disable = 27 }
        Hidden    = @{ Enable = 8; Disable = 28 }
        Strike    = @{ Enable = 9; Disable = 29 }
    }

    if ([string]::IsNullOrWhiteSpace($Style) -or $Style -eq 'None') {
        return [PSCustomObject]@{
            Prefix = ''
            Suffix = ''
        }
    }

    $styleNames = @(
        $Style -split '\+' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )

    $enableCodes = @()
    $disableCodes = @()

    foreach ($styleName in $styleNames) {
        if ($styleName -eq 'None') {
            continue
        }

        if (-not $styleMap.ContainsKey($styleName)) {
            $validStyles = @(
                'None',
                'Bold',
                'Dim',
                'Italic',
                'Underline',
                'Reverse',
                'Strike',
                'Blink',
                'Hidden'
            ) -join ', '

            throw "Invalid style '$styleName'. Valid styles: $validStyles."
        }

        $enableCodes += $styleMap[$styleName].Enable
        $disableCodes += $styleMap[$styleName].Disable
    }

    if ($enableCodes.Count -eq 0) {
        return [PSCustomObject]@{
            Prefix = ''
            Suffix = ''
        }
    }

    # A single disable code can reset multiple attributes, for example
    # SGR 22 disables both Bold and Dim.
    $disableCodes = @($disableCodes | Select-Object -Unique)

    $esc = [char]27

    return [PSCustomObject]@{
        Prefix = "$esc[$($enableCodes -join ';')m"
        Suffix = "$esc[$($disableCodes -join ';')m"
    }
}

function Get-DisplayWidth {
    <#
    .SYNOPSIS
    Gets the approximate console display width of a string.

    .DESCRIPTION
    Calculates display width for console alignment with best-effort Unicode
    handling. Common CJK/full-width characters and Emoji are treated as width 2.
    Combining marks, formatting characters, variation selectors, and Emoji skin
    tone modifiers do not add width. ZWJ Emoji sequences and regional-indicator
    flag pairs are treated as a single display cluster where possible.

    Exact rendering can still vary by terminal, font, and Unicode version.

    .PARAMETER Text
    Text to measure.

    .OUTPUTS
    System.Int32
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    if ($Text.Length -eq 0) {
        return 0
    }

    $totalWidth = 0
    $clusterWidth = 0
    $clusterHasBase = $false
    $joinNextBase = $false
    $regionalIndicatorCount = 0
    $index = 0

    while ($index -lt $Text.Length) {
        $char = $Text[$index]
        $scalarText = $null

        if (
            [char]::IsHighSurrogate($char) -and
            ($index + 1 -lt $Text.Length) -and
            [char]::IsLowSurrogate($Text[$index + 1])
        ) {
            $codePoint = [char]::ConvertToUtf32(
                $char,
                $Text[$index + 1]
            )
            $scalarText = $Text.Substring($index, 2)
            $index += 2
        }
        else {
            $codePoint = [int]$char
            $scalarText = $Text.Substring($index, 1)
            $index++
        }

        # Zero-width joiner joins the previous and next base characters into
        # one display cluster (for example, many Emoji sequences).
        if ($codePoint -eq 0x200D) {
            $joinNextBase = $true
            continue
        }

        # Variation Selector-16 requests Emoji-style presentation on terminals
        # that support it, so the current cluster should be at least width 2.
        if ($codePoint -eq 0xFE0F) {
            if ($clusterHasBase -and $clusterWidth -lt 2) {
                $clusterWidth = 2
            }
            continue
        }

        # Variation Selector-15 and supplementary variation selectors do not
        # consume an additional console cell.
        if (
            ($codePoint -eq 0xFE0E) -or
            ($codePoint -ge 0xE0100 -and $codePoint -le 0xE01EF)
        ) {
            continue
        }

        # Emoji skin-tone modifiers modify the previous Emoji and do not add
        # additional display width.
        if ($codePoint -ge 0x1F3FB -and $codePoint -le 0x1F3FF) {
            continue
        }

        $unicodeCategory = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory(
            $scalarText,
            0
        )

        # Combining/format characters normally occupy no additional cells.
        if (
            $unicodeCategory -eq [System.Globalization.UnicodeCategory]::NonSpacingMark -or
            $unicodeCategory -eq [System.Globalization.UnicodeCategory]::SpacingCombiningMark -or
            $unicodeCategory -eq [System.Globalization.UnicodeCategory]::EnclosingMark -or
            $unicodeCategory -eq [System.Globalization.UnicodeCategory]::Format -or
            $unicodeCategory -eq [System.Globalization.UnicodeCategory]::Control
        ) {
            # U+20E3 COMBINING ENCLOSING KEYCAP generally renders the cluster
            # as a two-cell keycap Emoji.
            if ($codePoint -eq 0x20E3 -and $clusterHasBase) {
                $clusterWidth = 2
            }
            continue
        }

        $isRegionalIndicator = (
            $codePoint -ge 0x1F1E6 -and
            $codePoint -le 0x1F1FF
        )

        $isWide = (
            ($codePoint -ge 0x1100 -and $codePoint -le 0x115F) -or
            ($codePoint -eq 0x2329) -or
            ($codePoint -eq 0x232A) -or
            ($codePoint -ge 0x2E80 -and $codePoint -le 0xA4CF) -or
            ($codePoint -ge 0xAC00 -and $codePoint -le 0xD7A3) -or
            ($codePoint -ge 0xF900 -and $codePoint -le 0xFAFF) -or
            ($codePoint -ge 0xFE10 -and $codePoint -le 0xFE19) -or
            ($codePoint -ge 0xFE30 -and $codePoint -le 0xFE6F) -or
            ($codePoint -ge 0xFF00 -and $codePoint -le 0xFF60) -or
            ($codePoint -ge 0xFFE0 -and $codePoint -le 0xFFE6) -or
            ($codePoint -ge 0x1F000 -and $codePoint -le 0x1FAFF) -or
            ($codePoint -ge 0x20000 -and $codePoint -le 0x3FFFD)
        )

        $baseWidth = if ($isWide) { 2 } else { 1 }

        if (-not $clusterHasBase) {
            $clusterWidth = $baseWidth
            $clusterHasBase = $true
            $regionalIndicatorCount = if ($isRegionalIndicator) { 1 } else { 0 }
            $joinNextBase = $false
            continue
        }

        if ($joinNextBase) {
            if ($baseWidth -gt $clusterWidth) {
                $clusterWidth = $baseWidth
            }
            $joinNextBase = $false
            $regionalIndicatorCount = 0
            continue
        }

        # Pair two regional indicators into one flag cluster.
        if ($isRegionalIndicator -and $regionalIndicatorCount -eq 1) {
            if ($baseWidth -gt $clusterWidth) {
                $clusterWidth = $baseWidth
            }
            $regionalIndicatorCount = 2
            continue
        }

        $totalWidth += $clusterWidth
        $clusterWidth = $baseWidth
        $clusterHasBase = $true
        $regionalIndicatorCount = if ($isRegionalIndicator) { 1 } else { 0 }
    }

    if ($clusterHasBase) {
        $totalWidth += $clusterWidth
    }

    return $totalWidth
}

function Write-Text {
    <#
    .SYNOPSIS
    Writes styled text to the console and optional log files.

    .DESCRIPTION
    Write-Text is a wrapper around Write-Host for Windows PowerShell 5.1 and PowerShell 7.x that supports multiple text segments and independent formatting for each segment.

    The command supports:
    - Per-segment foreground colors.
    - Independent per-segment background colors.
    - Optional ANSI text styles when the current host supports virtual-terminal sequences.
    - Tabs, spaces, blank lines, timestamps, and horizontal centering.
    - Best-effort Unicode display-width calculation for horizontal centering.
    - Optional file logging with configurable encoding and retry behavior.
    - Short aliases for commonly used parameters.

    WhatIf and Confirm apply only to log-file appends. Console output is not suppressed by these common parameters.

    Supports Windows PowerShell 5.1 and PowerShell 7.x (pwsh). PowerShell 7.x operation has been manually verified by the maintainer. No additional runtime version check is performed.

    .PARAMETER Text
    Text to display on screen and, when LogFile is specified, write to the log file.
    Accepts an array of strings. Each array element is treated as a separate text segment for color, background color, and style selection.

    .PARAMETER Color
    Foreground color of the text. Accepts an array of ConsoleColor values.
    Colors are applied to text segments by matching array index while values are available.
    If there are more text segments than colors, all remaining segments use White.
    Available colors are: Black, DarkBlue, DarkGreen, DarkCyan, DarkRed, DarkMagenta, DarkYellow, Gray, DarkGray, Blue, Green, Cyan, Red, Magenta, Yellow, White.

    .PARAMETER BackgroundColor
    Background color of the text. Accepts an array of ConsoleColor values and is handled independently from Color.
    Background colors are applied only to text segments with a matching array index.
    If there are more text segments than background colors, the remaining segments are written without a background color.
    Therefore, a single background color applies only to the first text segment. Color and BackgroundColor counts do not need to match.

    .PARAMETER Style
    Optional ANSI text style. Accepts an array of style definitions, one per text segment.
    If there are more text segments than styles, the first style is reused.
    Multiple styles can be combined with '+', for example Bold+Underline.
    Available styles are: None, Bold, Dim, Italic, Underline, Reverse, Strike, Blink, Hidden.
    If the current host does not advertise virtual-terminal support, ANSI style sequences are omitted and the text is written normally.

    .PARAMETER StartTab
    Number of tab characters to write before the text. Default is 0.

    .PARAMETER LinesBefore
    Number of empty lines to write before the text. Default is 0.

    .PARAMETER LinesAfter
    Number of empty lines to write after the text. Default is 0.

    .PARAMETER StartSpaces
    Number of spaces to write before the text. Default is 0.

    .PARAMETER LogFile
    Literal path to the log file. If not specified, no log file is written.

    .PARAMETER DateTimeFormat
    Custom date and time format string used by ShowTime and LogTime.
    Default is yyyy-MM-dd HH:mm:ss.

    .PARAMETER LogTime
    Controls whether a timestamp is added to each log-file entry. Default is $true.

    .PARAMETER LogRetry
    Number of retry attempts after the initial log-file write fails.
    Accepts 0 through 5 retries (up to 6 total write attempts).
    Default is 2, allowing up to 3 total write attempts: 1 initial attempt plus 2 retries.

    .PARAMETER IgnoreLogError
    Silences log-write failure diagnostics, including retry messages.
    By default, exhausted retries produce a non-terminating error. Use -ErrorAction Stop to terminate instead.
    IgnoreLogError takes precedence over ErrorAction for log-write failures only.

    .PARAMETER Encoding
    Encoding used by Add-Content when writing the log file. Default is UTF8.
    Under Windows PowerShell 5.1, UTF8 creates new files with a byte-order mark (BOM).
    Encoding names and BOM behavior depend on the PowerShell version. Explicit values must be supported by Add-Content in the current session.

    .PARAMETER ShowTime
    Adds the current time to console output using DateTimeFormat.

    .PARAMETER NoNewLine
    Prevents Write-Text from adding the final console newline.
    Explicit LinesAfter output is still written when both options are used.

    .PARAMETER NoConsoleOutput
    Suppresses console output. Logging can still occur when LogFile is specified.

    .PARAMETER HorizontalCenter
    Horizontally centers the complete visible line, including tabs, spaces, and an optional timestamp, using the current host WindowSize.Width and a best-effort Unicode display-width calculation.
    When centering is applied, StartTab values are rendered as eight spaces each so their width is deterministic.
    If Text contains control characters, or if RawUI window width is unavailable, no centering padding is added and a verbose message is emitted.
    Exact alignment can still vary by terminal, font, and Unicode rendering behavior.

    .EXAMPLE
    Write-Text -Text 'Red ', 'Green ', 'Yellow' -Color Red, Green, Yellow

    Writes three text segments using matching foreground colors.

    .EXAMPLE
    Write-Text -Text 'Primary', ' fallback', ' fallback again' -Color Cyan

    Uses Cyan for the first segment and White for all remaining segments.

    .EXAMPLE
    Write-Text -Text 'With background', ' without background' -Color White, Yellow -BackgroundColor DarkBlue

    Applies DarkBlue only to the first text segment. The second segment is written without a background color.

    .EXAMPLE
    Write-Text -Text 'Bold', ' Normal', ' Underline' -Style Bold, None, Underline

    Applies independent ANSI styles when the host supports virtual-terminal sequences.

    .EXAMPLE
    Write-Text -Text 'Important' -Color Yellow -Style 'Bold+Underline'

    Combines multiple ANSI styles for one text segment when supported by the host.

    .EXAMPLE
    Write-Text -Text 'Centered Unicode: 中文 😀' -HorizontalCenter

    Centers the text using WindowSize.Width and the module's best-effort Unicode display-width calculation.

    .EXAMPLE
    Write-Text -Text 'Logged message' -LogFile 'C:\Temp\example.log' -LogRetry 2

    Attempts the initial log write and retries up to two additional times if the write fails.

    .EXAMPLE
    Write-Text -T 'Short aliases ', 'still work' -C Yellow, Green -B DarkBlue

    Uses parameter aliases. The command itself has no exported compatibility alias.

    .NOTES
        Project: PSWriteText
        Author: Steve H.
        Repository: https://github.com/steveh8758/PSWriteText

        Supports Windows PowerShell 5.1 and PowerShell 7.x (pwsh).
        PowerShell 7.x operation has been manually verified by the maintainer.
        This compatibility note is informational only; the module performs no
        runtime PowerShell-version check.

        PSWriteText is derived from and extends PSWriteColor by EvotecIT:
        https://github.com/EvotecIT/PSWriteColor

        Original idea attribution:
        Josh - https://stackoverflow.com/users/81769/josh

        Date/time format reference:
        https://learn.microsoft.com/en-us/dotnet/standard/base-types/custom-date-and-time-format-strings
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [alias ('T')] [String[]]$Text,
        [alias ('C', 'ForegroundColor', 'FGC')] [ValidateNotNullOrEmpty()] [ConsoleColor[]]$Color = [ConsoleColor]::White,
        [alias ('B', 'BGC')] [ConsoleColor[]]$BackgroundColor = $null,
        [alias ('S')] [string[]]$Style = @('None'),
        [alias ('Indent')] [ValidateRange(0, 100)] [int] $StartTab = 0,
        [ValidateRange(0, 100)] [int] $LinesBefore = 0,
        [ValidateRange(0, 100)] [int] $LinesAfter = 0,
        [ValidateRange(0, 10000)] [int] $StartSpaces = 0,
        [alias ('L')] [string] $LogFile = '',
        [Alias('DateFormat', 'TimeFormat')][ValidateNotNullOrEmpty()][string] $DateTimeFormat = 'yyyy-MM-dd HH:mm:ss',
        [alias ('LogTimeStamp')][bool] $LogTime = $true,
        [ValidateRange(0, 5)] [int] $LogRetry = 2,
        [ValidateSet('unknown', 'string', 'unicode', 'bigendianunicode', 'utf8', 'utf7', 'utf32', 'ascii', 'default', 'oem')][string]$Encoding = 'UTF8',
        [switch] $ShowTime,
        [switch] $NoNewLine,
        [switch] $HorizontalCenter,
        [alias('HideConsole')][switch] $NoConsoleOutput,
        [switch] $IgnoreLogError
    )

    $UsesConsoleTimestamp = -not $NoConsoleOutput -and $ShowTime
    $UsesLogTimestamp = $Text.Count -and $LogFile -and $LogTime
    $TimestampPrefix = ''

    # Format the timestamp once so console and log output from the same call use
    # the same value. Validate the format before output, but only when this call
    # actually requests a timestamp.
    if ($UsesConsoleTimestamp -or $UsesLogTimestamp) {
        $CurrentDateTime = [datetime]::Now
        try {
            $FormattedDateTime = $CurrentDateTime.ToString($DateTimeFormat)
        }
        catch [System.FormatException] {
            throw "Write-Text - Invalid DateTimeFormat '$DateTimeFormat': $($_.Exception.Message)"
        }

        $TimestampPrefix = "[$FormattedDateTime] "
    }

    if (-not $NoConsoleOutput) {
        $DefaultColor = [ConsoleColor]::White
        $DefaultStyle = if ($Style.Count -gt 0) {
            $Style[0]
        }
        else {
            'None'
        }

        # Validate all requested styles before writing any console output.
        foreach ($styleValue in $Style) {
            Get-AnsiStyleSequence -Style $styleValue | Out-Null
        }

        # ANSI styles are optional. If the current host does not advertise
        # virtual-terminal support, preserve the text and ConsoleColor output
        # but omit ANSI escape sequences.
        $SupportsVirtualTerminal = (
            $null -ne $Host.UI.PSObject.Properties['SupportsVirtualTerminal'] -and
            [bool]$Host.UI.SupportsVirtualTerminal
        )

        $CenterPadding = 0
        $ExpandTabsForCentering = $false
        if ($HorizontalCenter) {
            $Message = $Text -join ''
            if ($Message -match '\p{Cc}') {
                Write-Verbose 'Horizontal centering skipped because Text contains control characters.'
            }
            else {
                $MessageWidth = Get-DisplayWidth -Text $Message
                $PrefixWidth = $StartSpaces + ($StartTab * 8)

                if ($ShowTime) {
                    $PrefixWidth += Get-DisplayWidth -Text $TimestampPrefix
                }

                $LineWidth = $PrefixWidth + $MessageWidth

                try {
                    $WindowWidth = [int]$Host.UI.RawUI.WindowSize.Width

                    if ($WindowWidth -gt 0 -and $WindowWidth -ge $LineWidth) {
                        $CenterPadding = [int][Math]::Floor(
                            ($WindowWidth - $LineWidth) / 2
                        )
                        $ExpandTabsForCentering = $true
                    }
                    elseif ($WindowWidth -le 0) {
                        Write-Verbose 'Horizontal centering skipped because RawUI returned an invalid window width.'
                    }
                }
                catch {
                    Write-Verbose "Horizontal centering skipped because RawUI window width is unavailable: $($_.Exception.Message)"
                }
            }
        }

        if ($LinesBefore -ne 0) {
            for ($i = 0; $i -lt $LinesBefore; $i++) {
                Write-Host -Object "`n" -NoNewline
            }
        } # Add empty line before
        if ($CenterPadding -gt 0) {
            Write-Host -Object (' ' * $CenterPadding) -NoNewline
        } # Center the complete visible line when RawUI window width is available
        if ($StartTab -ne 0) {
            if ($ExpandTabsForCentering) {
                Write-Host -Object (' ' * ($StartTab * 8)) -NoNewline
            }
            else {
                for ($i = 0; $i -lt $StartTab; $i++) {
                    Write-Host -Object "`t" -NoNewline
                }
            }
        }  # Add TABS before text
        if ($StartSpaces -ne 0) {
            for ($i = 0; $i -lt $StartSpaces; $i++) {
                Write-Host -Object ' ' -NoNewline
            }
        }  # Add SPACES before text
        if ($ShowTime) {
            Write-Host -Object $TimestampPrefix -NoNewline
        } # Add Time before output
        if ($Text.Count -ne 0) {
            for ($i = 0; $i -lt $Text.Length; $i++) {
                $segmentColor = if ($i -lt $Color.Count) {
                    $Color[$i]
                }
                else {
                    $DefaultColor
                }

                $segmentStyle = if ($i -lt $Style.Count) {
                    $Style[$i]
                }
                else {
                    $DefaultStyle
                }

                if ($SupportsVirtualTerminal) {
                    $ansiStyle = Get-AnsiStyleSequence -Style $segmentStyle

                    # Keep ANSI style codes and text in the same Write-Host call.
                    # Write-Host applies ConsoleColor before emitting the object;
                    # embedding ANSI here prevents ForegroundColor/BackgroundColor
                    # from overwriting the requested ANSI text attributes.
                    $styledText = '{0}{1}{2}' -f (
                        $ansiStyle.Prefix,
                        $Text[$i],
                        $ansiStyle.Suffix
                    )
                }
                else {
                    # Host does not support virtual-terminal sequences.
                    # Fall back to plain text while keeping ConsoleColor handling.
                    $styledText = $Text[$i]
                }

                if ($null -eq $BackgroundColor -or $i -ge $BackgroundColor.Count) {
                    Write-Host `
                        -Object $styledText `
                        -ForegroundColor $segmentColor `
                        -NoNewline
                }
                else {
                    Write-Host `
                        -Object $styledText `
                        -ForegroundColor $segmentColor `
                        -BackgroundColor $BackgroundColor[$i] `
                        -NoNewline
                }
            }
        }
        if ($NoNewLine -eq $true) {
            Write-Host -NoNewline
        }
        else {
            Write-Host
        } # Support for no new line
        if ($LinesAfter -ne 0) {
            for ($i = 0; $i -lt $LinesAfter; $i++) {
                Write-Host -Object "`n" -NoNewline
            }
        }  # Add empty line after
    }
    if ($Text.Count -and $LogFile) {
        $TextToFile = $Text -join ''
        $LogEntry = if ($LogTime) {
            "$TimestampPrefix$TextToFile"
        }
        else {
            $TextToFile
        }

        if ($PSCmdlet.ShouldProcess($LogFile, 'Append log entry')) {
            $Saved = $false
            $Attempt = 0
            $MaxAttempts = $LogRetry + 1

            while (-not $Saved -and $Attempt -lt $MaxAttempts) {
                $Attempt++
                try {
                    Add-Content `
                        -LiteralPath $LogFile `
                        -Value $LogEntry `
                        -Encoding $Encoding `
                        -ErrorAction Stop `
                        -Confirm:$false
                    $Saved = $true
                }
                catch {
                    if ($Attempt -ge $MaxAttempts) {
                        $OriginalException = $_.Exception
                        $FailureMessage = "Write-Text - Could not write to log file '$LogFile'. $($OriginalException.Message) Tried $Attempt time(s): 1 initial attempt + $LogRetry retry/retries."

                        if (-not $IgnoreLogError) {
                            $FailureException = [System.IO.IOException]::new(
                                $FailureMessage,
                                $OriginalException
                            )

                            $LogError = [System.Management.Automation.ErrorRecord]::new(
                                $FailureException,
                                'PSWriteText.LogWriteFailed',
                                [System.Management.Automation.ErrorCategory]::WriteError,
                                $LogFile
                            )

                            $LogError.ErrorDetails = [System.Management.Automation.ErrorDetails]::new(
                                $FailureMessage
                            )

                            $PSCmdlet.WriteError($LogError)
                        }
                    }
                    else {
                        $NextRetry = $Attempt

                        if (-not $IgnoreLogError) {
                            Write-Verbose "Write-Text - Could not write to log file '$LogFile'. $($_.Exception.Message) Retrying... ($NextRetry/$LogRetry)"
                        }

                        Start-Sleep -Milliseconds 200
                    }
                }
            }
        }
    }
}
