[CmdletBinding()]
param()


$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$configPath = Join-Path $projectRoot 'configs\mowpskit.psd1'
$versionPath = Join-Path $projectRoot 'version.txt'

if (-not [System.IO.File]::Exists($configPath)) {
    throw "Config file not found: $configPath"
}

if (-not [System.IO.File]::Exists($versionPath)) {
    throw "Version file not found: $versionPath"
}

$config = Import-PowerShellDataFile -Path $configPath


function Resolve-TextEncoding {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    switch ($Name.ToUpperInvariant()) {
        'UTF8NOBOM' {
            return New-Object System.Text.UTF8Encoding($false, $true)
        }

        'UTF8BOM' {
            return New-Object System.Text.UTF8Encoding($true, $true)
        }

        'UTF16LE' {
            return New-Object System.Text.UnicodeEncoding($false, $true, $true)
        }

        'UTF16BE' {
            return New-Object System.Text.UnicodeEncoding($true, $true, $true)
        }

        'UTF32' {
            return New-Object System.Text.UTF32Encoding($false, $true, $true)
        }

        'ASCII' {
            return [System.Text.Encoding]::ASCII
        }

        default {
            return [System.Text.Encoding]::GetEncoding($Name)
        }
    }
}


function Get-ConfiguredText {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [System.Text.Encoding]$Encoding
    )

    try {
        return [System.IO.File]::ReadAllText($Path, $Encoding)
    }
    catch {
        throw "Failed to read '$Path' using the configured encoding: $($_.Exception.Message)"
    }
}


function ConvertTo-Base64Text {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value,

        [Parameter(Mandatory)]
        [System.Text.Encoding]$Encoding
    )

    return [Convert]::ToBase64String(
        $Encoding.GetBytes($Value)
    )
}


function ConvertTo-PowerShellLiteral {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return "''"
    }

    return "'" + $Value.Replace("'", "''") + "'"
}


function Assert-ValidPowerShell {
    param(
        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )

    $tokens = $null
    $parseErrors = $null

    [void][System.Management.Automation.Language.Parser]::ParseInput(
        $Content,
        [ref]$tokens,
        [ref]$parseErrors
    )

    if ($parseErrors.Count -eq 0) {
        return
    }

    $details = @(
        foreach ($parseError in $parseErrors) {
            '{0}:{1}:{2}: {3}' -f (
                $Label,
                $parseError.Extent.StartLineNumber,
                $parseError.Extent.StartColumnNumber,
                $parseError.Message
            )
        }
    ) -join [Environment]::NewLine

    throw "PowerShell syntax validation failed:$([Environment]::NewLine)$details"
}


$name = [string]$config.General.Name
$prefix = [string]$config.General.Prefix
$commandSeparator = [string]$config.General.CommandSeparator

$sourceRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $projectRoot ([string]$config.Build.SourcePath))
)

$outputPath = [System.IO.Path]::GetFullPath(
    (Join-Path $projectRoot ([string]$config.Build.OutputPath))
)

$artifactUrl = [string]$config.Build.ArtifactUrl
$setupUrl = [string]$config.Build.SetupUrl
$loaderPath = Join-Path $sourceRoot 'loader.ps1'

$encodingName = [string]$config.Normalize.Encoding
$lineEndingName = [string]$config.Normalize.LineEnding
$encoding = Resolve-TextEncoding -Name $encodingName
$versionText = Get-ConfiguredText `
    -Path $versionPath `
    -Encoding $encoding
$version = $versionText.Trim()

if (
    [string]::IsNullOrWhiteSpace($version) -or
    $version -match '[\r\n]'
) {
    throw 'version.txt must contain exactly one non-empty line.'
}

if (
    $version -notmatch
    '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$'
) {
    throw (
        "Invalid version.txt value '$version'. " +
        'Use X.Y.Z, for example 1.0.0.'
    )
}

if ($lineEndingName -eq 'CRLF') {
    $lineEnding = "`r`n"
}
elseif ($lineEndingName -eq 'LF') {
    $lineEnding = "`n"
}
else {
    throw "Unsupported line ending: $lineEndingName"
}

if (-not [System.IO.Directory]::Exists($sourceRoot)) {
    throw "Source path not found: $sourceRoot"
}

if (-not [System.IO.File]::Exists($loaderPath)) {
    throw "Loader not found: $loaderPath"
}

if (-not [string]::IsNullOrWhiteSpace($artifactUrl)) {
    $artifactUri = $null

    if (
        -not [System.Uri]::TryCreate(
            $artifactUrl,
            [System.UriKind]::Absolute,
            [ref]$artifactUri
        ) -or
        $artifactUri.Scheme -notin @('http', 'https')
    ) {
        throw 'Build.ArtifactUrl must be empty or an absolute HTTP/HTTPS URL.'
    }
}

if (-not [string]::IsNullOrWhiteSpace($setupUrl)) {
    $setupUri = $null

    if (
        -not [System.Uri]::TryCreate(
            $setupUrl,
            [System.UriKind]::Absolute,
            [ref]$setupUri
        ) -or
        $setupUri.Scheme -notin @('http', 'https')
    ) {
        throw 'Build.SetupUrl must be empty or an absolute HTTP/HTTPS URL.'
    }
}

$sourceRootWithSeparator = $sourceRoot.TrimEnd('\', '/') +
    [System.IO.Path]::DirectorySeparatorChar

if (
    $outputPath.StartsWith(
        $sourceRootWithSeparator,
        [System.StringComparison]::OrdinalIgnoreCase
    )
) {
    throw "Build output cannot be written inside src: $outputPath"
}

$buildScriptPath = [System.IO.Path]::GetFullPath($PSCommandPath)

if (
    $outputPath.Equals(
        $buildScriptPath,
        [System.StringComparison]::OrdinalIgnoreCase
    )
) {
    throw 'Build output cannot overwrite build.ps1.'
}

$buildVersion = $version


$loaderSource = Get-ConfiguredText `
    -Path $loaderPath `
    -Encoding $encoding

Assert-ValidPowerShell `
    -Label 'src/loader.ps1' `
    -Content $loaderSource


$unitDescriptors = [System.Collections.Generic.List[object]]::new()

foreach ($category in @('core', 'internal', 'functions')) {
    $categoryRoot = Join-Path $sourceRoot $category

    if (-not [System.IO.Directory]::Exists($categoryRoot)) {
        continue
    }

    $files = @(
        Get-ChildItem `
            -LiteralPath $categoryRoot `
            -File `
            -Filter '*.ps1' `
            -Recurse
    )

    $relativePaths = @(
        foreach ($file in $files) {
            $file.FullName.Substring(
                $categoryRoot.Length
            ).TrimStart('\', '/')
        }
    )

    [System.Array]::Sort(
        [string[]]$relativePaths,
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($relativePath in $relativePaths) {
        $normalizedPath = $relativePath.Replace('\', '/')
        $fullPath = Join-Path $categoryRoot $relativePath

        $content = Get-ConfiguredText `
            -Path $fullPath `
            -Encoding $encoding

        Assert-ValidPowerShell `
            -Label "$category/$normalizedPath" `
            -Content $content

        $unitDescriptors.Add(
            [pscustomobject]@{
                Category = $category
                RelativePath = $normalizedPath
                Content = $content
            }
        )
    }
}


$resourceDescriptors = [System.Collections.Generic.List[object]]::new()
$resourcesRoot = Join-Path $sourceRoot 'resources'

if ([System.IO.Directory]::Exists($resourcesRoot)) {
    $resourceFiles = @(
        Get-ChildItem `
            -LiteralPath $resourcesRoot `
            -File `
            -Recurse
    )

    $resourcePaths = @(
        foreach ($file in $resourceFiles) {
            $file.FullName.Substring(
                $resourcesRoot.Length
            ).TrimStart('\', '/')
        }
    )

    [System.Array]::Sort(
        [string[]]$resourcePaths,
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($relativePath in $resourcePaths) {
        $resourceDescriptors.Add(
            [pscustomobject]@{
                RelativePath = $relativePath.Replace('\', '/')
                Bytes = [System.IO.File]::ReadAllBytes(
                    (Join-Path $resourcesRoot $relativePath)
                )
            }
        )
    }
}


$lines = [System.Collections.Generic.List[string]]::new()

$lines.Add(
    '# Generated by scripts/build.ps1. Edit src/, configs/, and version.txt instead.'
)
$lines.Add('& {')
$lines.Add('    [CmdletBinding()]')
$lines.Add('    param(')
$lines.Add('        [AllowEmptyString()]')
$lines.Add(
    '        [string]$Prefix = {0},' -f (
        ConvertTo-PowerShellLiteral $prefix
    )
)
$lines.Add('')
$lines.Add("        [Alias('Separator')]")
$lines.Add('        [AllowEmptyString()]')
$lines.Add(
    '        [string]$CommandSeparator = {0},' -f (
        ConvertTo-PowerShellLiteral $commandSeparator
    )
)
$lines.Add('')
$lines.Add('        [AllowEmptyString()]')
$lines.Add(
    '        [string]$ArtifactUrl = {0},' -f (
        ConvertTo-PowerShellLiteral $artifactUrl
    )
)
$lines.Add('')
$lines.Add('        [AllowEmptyString()]')
$lines.Add('        [string]$EntryPointPath = $PSCommandPath,')
$lines.Add('')
$lines.Add('        [switch]$VersionOnly')
$lines.Add('    )')
$lines.Add('')
$lines.Add(
    '    Microsoft.PowerShell.Utility\Set-Variable -Name MowPSKitVersion -Value {0} -Option Constant -Scope Local' -f (
        ConvertTo-PowerShellLiteral $version
    )
)
$lines.Add('')
$lines.Add('    if ($VersionOnly) {')
$lines.Add('        return $MowPSKitVersion')
$lines.Add('    }')
$lines.Add('')

# Bundled script source is always encoded as UTF-8 inside the artifact.
$lines.Add(
    '    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)'
)
$lines.Add('    $units = @(')

$bundleUtf8 = New-Object System.Text.UTF8Encoding($false, $true)

foreach ($unit in $unitDescriptors) {
    $lines.Add('        [pscustomobject]@{')
    $lines.Add(
        '            Category = {0}' -f (
            ConvertTo-PowerShellLiteral $unit.Category
        )
    )

    $relativePathBase64 = ConvertTo-Base64Text `
        -Value $unit.RelativePath `
        -Encoding $bundleUtf8

    $contentBase64 = ConvertTo-Base64Text `
        -Value $unit.Content `
        -Encoding $bundleUtf8

    $lines.Add(
        '            RelativePath = $utf8.GetString([Convert]::FromBase64String({0}))' -f (
            ConvertTo-PowerShellLiteral $relativePathBase64
        )
    )
    $lines.Add(
        '            Content = $utf8.GetString([Convert]::FromBase64String({0}))' -f (
            ConvertTo-PowerShellLiteral $contentBase64
        )
    )
    $lines.Add('        }')
}

$lines.Add('    )')
$lines.Add('    $resources = [ordered]@{}')

foreach ($resource in $resourceDescriptors) {
    $pathBase64 = ConvertTo-Base64Text `
        -Value $resource.RelativePath `
        -Encoding $bundleUtf8

    $contentBase64 = [Convert]::ToBase64String(
        $resource.Bytes
    )

    $lines.Add(
        '    $resources[$utf8.GetString([Convert]::FromBase64String({0}))] = [Convert]::FromBase64String({1})' -f (
            (ConvertTo-PowerShellLiteral $pathBase64),
            (ConvertTo-PowerShellLiteral $contentBase64)
        )
    )
}

$lines.Add('')
$lines.Add('    $bundle = [ordered]@{')
$lines.Add('        Version = $MowPSKitVersion')
$lines.Add('        BuildVersion = $MowPSKitVersion')
$lines.Add(
    '        SetupUrl = {0}' -f (
        ConvertTo-PowerShellLiteral $setupUrl
    )
)
$lines.Add('        Units = $units')
$lines.Add('        Resources = $resources')
$lines.Add('    }')

$loaderBase64 = ConvertTo-Base64Text `
    -Value $loaderSource `
    -Encoding $bundleUtf8

$lines.Add(
    '    $loaderSource = $utf8.GetString([Convert]::FromBase64String({0}))' -f (
        ConvertTo-PowerShellLiteral $loaderBase64
    )
)
$lines.Add(
    '    $loaderScript = [scriptblock]::Create($loaderSource)'
)
$lines.Add('')
$lines.Add('    & $loaderScript `')
$lines.Add('        -Prefix $Prefix `')
$lines.Add('        -CommandSeparator $CommandSeparator `')
$lines.Add('        -Bundle $bundle `')
$lines.Add('        -ArtifactUrl $ArtifactUrl `')
$lines.Add('        -EntryPointPath $EntryPointPath')
$lines.Add('} @args')


$artifactText = $lines -join $lineEnding

Assert-ValidPowerShell `
    -Label 'compiled artifact' `
    -Content $artifactText


$outputDirectory = [System.IO.Path]::GetDirectoryName(
    $outputPath
)

if (-not [System.IO.Directory]::Exists($outputDirectory)) {
    [void][System.IO.Directory]::CreateDirectory(
        $outputDirectory
    )
}

[System.IO.File]::WriteAllText(
    $outputPath,
    $artifactText,
    $encoding
)


Write-Host ("Built $name") -ForegroundColor Green
Write-Host "  Version       : $version"
Write-Host "  Build Version : $buildVersion"
Write-Host "  Source        : $sourceRoot"
Write-Host "  Output        : $outputPath"
Write-Host "  Units         : $($unitDescriptors.Count)"
Write-Host "  Resources     : $($resourceDescriptors.Count)"
Write-Host "  Encoding      : $encodingName"
Write-Host "  Line Ending   : $lineEndingName"
Write-Host (
    "  Reload URL    : $(if ([string]::IsNullOrWhiteSpace($artifactUrl)) {
        '<none>'
    }
    else {
        $artifactUrl
    })"
)

Write-Host (
    "  Setup URL     : $(if ([string]::IsNullOrWhiteSpace($setupUrl)) {
        '<none>'
    }
    else {
        $setupUrl
    })"
)
