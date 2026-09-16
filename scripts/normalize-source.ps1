[CmdletBinding()]
param()


$projectRoot = Split-Path $PSScriptRoot -Parent
$configPath = Join-Path $projectRoot 'configs\mowpskit.psd1'

if (-not [System.IO.File]::Exists($configPath)) {
    throw "Config file not found: $configPath"
}

$config = Import-PowerShellDataFile -Path $configPath
$settings = $config.Normalize


# Resolve paths.
$targetPath = Join-Path $projectRoot $settings.Path

if (-not [System.IO.Directory]::Exists($targetPath)) {
    throw "Normalize path not found: $targetPath"
}


# Resolve encoding.
$encodingObject = switch ($settings.Encoding.ToUpperInvariant()) {
    'UTF8NOBOM' {
        New-Object System.Text.UTF8Encoding($false)
    }

    'UTF8BOM' {
        New-Object System.Text.UTF8Encoding($true)
    }

    'UTF16LE' {
        New-Object System.Text.UnicodeEncoding($false, $true)
    }

    'UTF16BE' {
        New-Object System.Text.UnicodeEncoding($true, $true)
    }

    'UTF32' {
        New-Object System.Text.UTF32Encoding($false, $true)
    }

    'ASCII' {
        [System.Text.Encoding]::ASCII
    }

    default {
        [System.Text.Encoding]::GetEncoding($settings.Encoding)
    }
}


# Validate line ending.
if ($settings.LineEnding -notin @('CRLF', 'LF')) {
    throw "Unsupported line ending: $($settings.LineEnding)"
}


$extensions = @($settings.Extensions)
$excludeDirs = @($settings.ExcludeDirs)
$normalizedCount = 0


Get-ChildItem `
    -LiteralPath $targetPath `
    -File `
    -Recurse |
    Where-Object {
        if ($_.Extension -notin $extensions) {
            return $false
        }

        foreach ($excludeDir in $excludeDirs) {
            $pattern = '[\\/]{0}[\\/]' -f (
                [regex]::Escape($excludeDir)
            )

            if ($_.FullName -match $pattern) {
                return $false
            }
        }

        return $true
    } |
    ForEach-Object {
        $file = $_.FullName
        $content = [System.IO.File]::ReadAllText($file)

        # Normalize all line endings to LF first.
        $content = $content -replace "`r`n", "`n"
        $content = $content -replace "`r", "`n"

        # Source files follow the root EditorConfig contract: remove trailing
        # spaces/tabs and keep exactly one final newline.
        $content = $content -replace '(?m)[\t ]+$', ''
        $content = $content.TrimEnd([char[]]"`n") + "`n"

        # Convert LF to the configured line ending.
        if ($settings.LineEnding -eq 'CRLF') {
            $content = $content -replace "`n", "`r`n"
        }

        [System.IO.File]::WriteAllText(
            $file,
            $content,
            $encodingObject
        )

        $normalizedCount++

        Write-Host "Normalized: $file"
    }


Write-Host
Write-Host 'Source normalization completed.' -ForegroundColor Green
Write-Host "  Path        : $targetPath"
Write-Host "  Encoding    : $($settings.Encoding)"
Write-Host "  Line Ending : $($settings.LineEnding)"
Write-Host "  Files       : $normalizedCount"
