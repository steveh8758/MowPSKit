$MowInternal = 'all'


function Write-Status {
    <#
    .SYNOPSIS
    Writes a standardized status message.

    .PARAMETER Type
    Status type: Success, Error, Warning, or Do.

    .PARAMETER Message
    Message to display.

    .PARAMETER StartSpaces
    Number of spaces before the output.

    .PARAMETER Log
    Also writes the message to the active log session.

    .PARAMETER Component
    Component name used when logging.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet(
            'Success',
            'Error',
            'Warning',
            'Do'
        )]
        [string]$Type,

        [Parameter(Mandatory, Position = 1)]
        [string]$Message,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$StartSpaces = 0,

        [switch]$Log,

        [ValidateScript({
            if ([string]::IsNullOrWhiteSpace($_)) {
                throw 'Component cannot be null, empty, or whitespace.'
            }
            $true
        })]
        [string]$Component = 'General'
    )

    switch ($Type) {
        'Success' {
            $symbol = '✓'
            $color = [ConsoleColor]::Green
            $logLevel = 'INFO'
        }

        'Error' {
            $symbol = '✗'
            $color = [ConsoleColor]::Red
            $logLevel = 'ERROR'
        }

        'Warning' {
            $symbol = '!'
            $color = [ConsoleColor]::Yellow
            $logLevel = 'WARNING'
        }

        'Do' {
            $symbol = '→'
            $color = [ConsoleColor]::Cyan
            $logLevel = 'INFO'
        }
    }
    Write-Text `
        -Text "$symbol ", $Message `
        -Color $color, White `
        -Style Bold, None `
        -StartSpaces $StartSpaces

    if ($Log) {
        Write-Log `
            -Level $logLevel `
            -Component $Component `
            -Message $Message
    }
}


function Write-Step {
    <#
    .SYNOPSIS
    Writes a standardized progress step.

    .PARAMETER Current
    Current step number.

    .PARAMETER Total
    Total number of steps.

    .PARAMETER Message
    Step description.

    .PARAMETER Log
    Also writes the step to the active log session.

    .PARAMETER Component
    Component name used when logging.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, Position = 0)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$Current,

        [Parameter(Mandatory, Position = 1)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$Total,

        [Parameter(Mandatory, Position = 2)]
        [string]$Message,

        [switch]$Log,

        [ValidateScript({
            if ([string]::IsNullOrWhiteSpace($_)) {
                throw 'Component cannot be null, empty, or whitespace.'
            }
            $true
        })]
        [string]$Component = 'General'
    )

    if ($Current -gt $Total) {
        throw 'Current step cannot be greater than total steps.'
    }

    $step = "[$Current/$Total]"
    Write-Text `
        -Text "$step ", $Message `
        -Color Cyan, White `
        -Style Bold, None

    if ($Log) {
        Write-Log `
            -Level INFO `
            -Component $Component `
            -Message "Step $Current/$Total - $Message"
    }
}

function Write-KeyValue {
    <#
    .SYNOPSIS
    Writes aligned key-value pairs to the console.

    .DESCRIPTION
    Writes entries from a dictionary. Labels are aligned using best-effort
    Unicode console display widths, including common CJK and Emoji characters.

    Use [ordered]@{} when deterministic insertion order is required.

    .PARAMETER Data
    Dictionary containing label-value pairs.

    .PARAMETER StartSpaces
    Number of spaces to add before each line.

    .PARAMETER LabelColor
    Console color used for labels.

    .PARAMETER SeparatorColor
    Console color used for the separator.

    .PARAMETER ValueColor
    Console color used for values.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, Position = 0)]
        [System.Collections.IDictionary]$Data,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$StartSpaces = 0,

        [ConsoleColor]$LabelColor = [ConsoleColor]::Gray,

        [ConsoleColor]$SeparatorColor = [ConsoleColor]::DarkGray,

        [ConsoleColor]$ValueColor = [ConsoleColor]::White
    )

    if ($Data.Count -eq 0) {
        return
    }

    $maxWidth = 0

    foreach ($key in $Data.Keys) {
        $width = Get-DisplayWidth -Text ([string]$key)

        if ($width -gt $maxWidth) {
            $maxWidth = $width
        }
    }

    foreach ($key in $Data.Keys) {
        $label = [string]$key

        $value = if ($null -eq $Data[$key]) {
            ''
        }
        else {
            [string]$Data[$key]
        }

        $labelWidth = Get-DisplayWidth -Text $label
        $padding = ' ' * ($maxWidth - $labelWidth)
        Write-Text `
            -Text "$label$padding", ' : ', $value `
            -Color $LabelColor, $SeparatorColor, $ValueColor `
            -Style Bold, None, None `
            -StartSpaces $StartSpaces
    }
}

# ---------------------------------------------------------------------------------------------
function Split-DisplayText {
    <#
    .SYNOPSIS
    Splits text by console display width.
    #>
    param(
        [AllowEmptyString()]
        [string]$Text,

        [int]$Width
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return @('')
    }

    if ($Width -le 0) {
        return @('')
    }

    $lines = @()

    foreach ($sourceLine in @($Text -split '\r?\n')) {
        if ($sourceLine.Length -eq 0) {
            $lines += ''
            continue
        }

        $line = ''

        $enumerator =
            [System.Globalization.StringInfo]::GetTextElementEnumerator(
                $sourceLine
            )

        while ($enumerator.MoveNext()) {
            $element = $enumerator.GetTextElement()
            $candidate = $line + $element

            if (
                $line -ne '' -and
                (Get-DisplayWidth $candidate) -gt $Width
            ) {
                $lines += $line
                $line = $element
            }
            else {
                $line = $candidate
            }
        }

        $lines += $line
    }

    return $lines
}


function Format-TableCell {
    <#
    .SYNOPSIS
    Pads text to a specified console display width.
    #>
    param(
        [AllowEmptyString()]
        [string]$Text,

        [int]$Width,

        [ValidateSet('Left', 'Center', 'Right')]
        [string]$Align = 'Left'
    )

    $padding = [Math]::Max(
        0,
        $Width - (Get-DisplayWidth $Text)
    )

    switch ($Align) {
        'Right' {
            return (' ' * $padding) + $Text
        }

        'Center' {
            $left = [Math]::Floor($padding / 2)
            $right = $padding - $left

            return (
                (' ' * $left) +
                $Text +
                (' ' * $right)
            )
        }

        default {
            return $Text + (' ' * $padding)
        }
    }
}


function Write-Table {
    <#
    .SYNOPSIS
    Writes objects as a styled console table.

    .PARAMETER InputObject
    Objects to display.

    .PARAMETER Property
    Properties to display and their order.

    .PARAMETER Color
    Colors for individual columns.

    .PARAMETER Align
    Alignment for individual columns.

    .PARAMETER ColumnSpacing
    Number of spaces between table columns.

    .PARAMETER Width
    Fallback table width when console width is unavailable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(
            Mandatory,
            ValueFromPipeline,
            Position = 0
        )]
        [object]$InputObject,

        [string[]]$Property,

        [hashtable]$Color = @{},

        [hashtable]$Align = @{},

        [int]$ColumnSpacing = 3,

        [int]$Width = 160
    )

    begin {
        $buffer = New-Object System.Collections.ArrayList
    }

    process {
        foreach ($item in @($InputObject)) {
            [void]$buffer.Add($item)
        }
    }

    end {
        if ($buffer.Count -eq 0) {
            return
        }

        if (-not $Property) {
            $Property = @(
                $buffer[0].PSObject.Properties.Name
            )
        }

        try {
            $windowWidth = [int]$Host.UI.RawUI.WindowSize.Width

            if ($windowWidth -gt 0) {
                $Width = $windowWidth
            }
        }
        catch {
            # Keep fallback width.
        }

        $columnWidths = @{}

        foreach ($name in $Property) {
            $columnWidth = Get-DisplayWidth $name

            foreach ($row in $buffer) {
                $propertyValue = $row.PSObject.Properties[$name]

                if ($null -eq $propertyValue) {
                    $value = ''
                }
                elseif ($null -eq $propertyValue.Value) {
                    $value = ''
                }
                else {
                    $value = [string]$propertyValue.Value
                }

                foreach ($line in @($value -split '\r?\n')) {
                    $valueWidth = Get-DisplayWidth $line

                    if ($valueWidth -gt $columnWidth) {
                        $columnWidth = $valueWidth
                    }
                }
            }

            $columnWidths[$name] = $columnWidth
        }

        $separatorWidth = $ColumnSpacing
        $separator = ' ' * $ColumnSpacing

        $availableWidth = [Math]::Max(
            $Property.Count,
            $Width - (($Property.Count - 1) * $separatorWidth)
        )

        while ($true) {
            $totalWidth = 0

            foreach ($name in $Property) {
                $totalWidth += $columnWidths[$name]
            }

            if ($totalWidth -le $availableWidth) {
                break
            }

            $largest = $null
            $largestWidth = 0

            foreach ($name in $Property) {
                if (
                    $columnWidths[$name] -gt $largestWidth -and
                    $columnWidths[$name] -gt 3
                ) {
                    $largest = $name
                    $largestWidth = $columnWidths[$name]
                }
            }

            if (-not $largest) {
                break
            }

            $columnWidths[$largest]--
        }

        # Header
        $text = @()
        $colors = @()
        $styles = @()

        for ($i = 0; $i -lt $Property.Count; $i++) {
            $name = $Property[$i]

            $alignment = if ($Align.ContainsKey($name)) {
                $Align[$name]
            }
            else {
                'Left'
            }

            $text += Format-TableCell `
                $name `
                $columnWidths[$name] `
                $alignment

            $colors += 'Green'
            $styles += 'Bold'

            if ($i -lt ($Property.Count - 1)) {
                $text += $separator
                $colors += 'DarkGray'
                $styles += 'None'
            }
        }

        Write-Text `
            -Text $text `
            -Color $colors `
            -Style $styles

        # Separator
        $text = @()
        $colors = @()

        for ($i = 0; $i -lt $Property.Count; $i++) {
            $name = $Property[$i]

            $text += '-' * $columnWidths[$name]
            $colors += 'DarkGray'

            if ($i -lt ($Property.Count - 1)) {
                $text += $separator
                $colors += 'DarkGray'
            }
        }

        Write-Text `
            -Text $text `
            -Color $colors

        # Rows
        foreach ($row in $buffer) {
            $cells = @{}
            $lineCount = 1

            foreach ($name in $Property) {
                $propertyValue = $row.PSObject.Properties[$name]

                if ($null -eq $propertyValue) {
                    $value = ''
                }
                elseif ($null -eq $propertyValue.Value) {
                    $value = ''
                }
                else {
                    $value = [string]$propertyValue.Value
                }

                $cells[$name] = @(
                    Split-DisplayText `
                        $value `
                        $columnWidths[$name]
                )

                if ($cells[$name].Count -gt $lineCount) {
                    $lineCount = $cells[$name].Count
                }
            }

            for (
                $lineIndex = 0
                $lineIndex -lt $lineCount
                $lineIndex++
            ) {
                $text = @()
                $colors = @()
                $styles = @()

                for ($i = 0; $i -lt $Property.Count; $i++) {
                    $name = $Property[$i]
                    $value = ''

                    if ($lineIndex -lt $cells[$name].Count) {
                        $value = $cells[$name][$lineIndex]
                    }

                    $alignment = if ($Align.ContainsKey($name)) {
                        $Align[$name]
                    }
                    else {
                        'Left'
                    }

                    $columnColor = if ($Color.ContainsKey($name)) {
                        $Color[$name]
                    }
                    else {
                        'White'
                    }

                    $text += Format-TableCell `
                        $value `
                        $columnWidths[$name] `
                        $alignment

                    $colors += $columnColor
                    $styles += 'None'

                    if ($i -lt ($Property.Count - 1)) {
                        $text += $separator
                        $colors += 'DarkGray'
                        $styles += 'None'
                    }
                }

                Write-Text `
                    -Text $text `
                    -Color $colors `
                    -Style $styles
            }
        }
    }
}
