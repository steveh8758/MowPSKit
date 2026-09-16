[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$moduleName = 'MowPSKit'

$loaderPath = Join-Path $projectRoot 'src\loader.ps1'
$buildPath = Join-Path $projectRoot 'scripts\build.ps1'
$normalizePath = Join-Path $projectRoot 'scripts\normalize-source.ps1'
$configPath = Join-Path $projectRoot 'configs\mowpskit.psd1'
$setupPath = Join-Path $projectRoot 'setup.ps1'
$versionPath = Join-Path $projectRoot 'version.txt'

$script:TestResults = @()


# ============================================================
# Test helpers
# ============================================================

function Assert-MowTrue {
    param(
        [Parameter(Mandatory)]
        [bool]$Condition,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}


function Assert-MowFalse {
    param(
        [Parameter(Mandatory)]
        [bool]$Condition,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if ($Condition) {
        throw "Assertion failed: $Message"
    }
}


function Assert-MowEqual {
    param(
        [AllowNull()]
        [object]$Actual,

        [AllowNull()]
        [object]$Expected,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        throw (
            "Assertion failed: $Message" +
            [Environment]::NewLine +
            "  Expected: $Expected" +
            [Environment]::NewLine +
            "  Actual  : $Actual"
        )
    }
}


function Assert-MowSequenceEqual {
    param(
        [Parameter(Mandatory)]
        [object[]]$Actual,

        [Parameter(Mandatory)]
        [object[]]$Expected,

        [Parameter(Mandatory)]
        [string]$Message
    )

    $actualText = @($Actual) -join '|'
    $expectedText = @($Expected) -join '|'

    if ($actualText -ne $expectedText) {
        throw (
            "Assertion failed: $Message" +
            [Environment]::NewLine +
            "  Expected: $expectedText" +
            [Environment]::NewLine +
            "  Actual  : $actualText"
        )
    }
}


function Assert-MowThrows {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Action,

        [string]$Pattern = '',

        [Parameter(Mandatory)]
        [string]$Message
    )

    $thrown = $false
    $errorMessage = ''

    try {
        $null = & $Action
    }
    catch {
        $thrown = $true
        $errorMessage = $_.Exception.Message
    }

    if (-not $thrown) {
        throw "Assertion failed: $Message Expected an exception, but none was thrown."
    }

    if (
        -not [string]::IsNullOrWhiteSpace($Pattern) -and
        $errorMessage -notmatch $Pattern
    ) {
        throw (
            "Assertion failed: $Message" +
            [Environment]::NewLine +
            "  Expected error matching: $Pattern" +
            [Environment]::NewLine +
            "  Actual error           : $errorMessage"
        )
    }
}


function Reset-MowTestRuntime {
    $modules = @(
        Microsoft.PowerShell.Core\Get-Module `
            -Name $moduleName `
            -All `
            -ErrorAction SilentlyContinue
    )

    foreach ($module in $modules) {
        Microsoft.PowerShell.Core\Remove-Module `
            -ModuleInfo $module `
            -Force `
            -ErrorAction SilentlyContinue
    }
}


function New-MowTestRoot {
    param(
        [string]$Name = 'case'
    )

    $safeRoot = [System.IO.Path]::Combine(
        [System.IO.Path]::GetTempPath(),
        'MowPSKitTests'
    )

    [void][System.IO.Directory]::CreateDirectory($safeRoot)

    $root = [System.IO.Path]::Combine(
        $safeRoot,
        ('{0}-{1}' -f $Name, [guid]::NewGuid().ToString('N'))
    )

    if (-not $root.StartsWith(
        $safeRoot,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Refusing to create an unsafe test path.'
    }

    [void][System.IO.Directory]::CreateDirectory($root)

    return $root
}


function Remove-MowTestRoot {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $safeRoot = [System.IO.Path]::Combine(
        [System.IO.Path]::GetTempPath(),
        'MowPSKitTests'
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)

    if (-not $fullPath.StartsWith(
        $safeRoot,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Refusing to remove an unsafe test path: $fullPath"
    }

    if ([System.IO.Directory]::Exists($fullPath)) {
        Remove-Item `
            -LiteralPath $fullPath `
            -Recurse `
            -Force
    }
}


function Write-MowTestFile {
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$RelativePath,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )

    $path = Join-Path $Root $RelativePath
    $directory = [System.IO.Path]::GetDirectoryName($path)

    if (-not [System.IO.Directory]::Exists($directory)) {
        [void][System.IO.Directory]::CreateDirectory($directory)
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    [System.IO.File]::WriteAllText(
        $path,
        $Content,
        $utf8NoBom
    )

    return $path
}


function New-MowLoaderFixture {
    param(
        [string]$Name = 'loader',

        [string]$Version = '9.8.7'
    )

    $projectRoot = New-MowTestRoot -Name $Name
    $root = Join-Path $projectRoot 'src'

    [void][System.IO.Directory]::CreateDirectory($root)

    Copy-Item `
        -LiteralPath $loaderPath `
        -Destination (Join-Path $root 'loader.ps1')

    $null = Write-MowTestFile `
        -Root $projectRoot `
        -RelativePath 'version.txt' `
        -Content $Version

    return $root
}


function Remove-MowLoaderFixture {
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot
    )

    $projectRoot = Split-Path `
        ([System.IO.Path]::GetFullPath($SourceRoot)) `
        -Parent

    Remove-MowTestRoot -Path $projectRoot
}


function Get-MowExportedNames {
    return @(
        Microsoft.PowerShell.Core\Get-Command `
            -Module $moduleName `
            -ErrorAction Stop |
            Sort-Object Name |
            ForEach-Object { $_.Name }
    )
}


function Invoke-MowTest {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [scriptblock]$Test
    )

    Reset-MowTestRuntime

    try {
        & $Test

        $script:TestResults += [pscustomobject]@{
            Name = $Name
            Passed = $true
            Error = ''
        }

        Write-Host ("PASS  {0}" -f $Name) -ForegroundColor Green
    }
    catch {
        $script:TestResults += [pscustomobject]@{
            Name = $Name
            Passed = $false
            Error = $_.Exception.Message
        }

        Write-Host ("FAIL  {0}" -f $Name) -ForegroundColor Red
        Write-Host ("      {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    finally {
        Reset-MowTestRuntime
    }
}


function Write-MowBuildConfig {
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [string]$OutputPath = 'dist\MowPSKit.ps1',

        [string]$Version = '9.8.7',

        [string]$Prefix = '',

        [string]$CommandSeparator = '',

        [string]$SetupUrl = 'https://example.invalid/MowPSKit/setup.ps1'
    )

    $escapedOutput = $OutputPath.Replace("'", "''")
    $escapedPrefix = $Prefix.Replace("'", "''")
    $escapedSeparator = $CommandSeparator.Replace("'", "''")
    $escapedSetupUrl = $SetupUrl.Replace("'", "''")

    $content = @"
@{
    General = @{
        Name = 'MowPSKit'
        Prefix = '$escapedPrefix'
        CommandSeparator = '$escapedSeparator'
    }

    Build = @{
        SourcePath = 'src'
        OutputPath = '$escapedOutput'
        ArtifactUrl = ''
        SetupUrl = '$escapedSetupUrl'
    }

    Normalize = @{
        Path = 'src'
        Encoding = 'UTF8NoBOM'
        LineEnding = 'CRLF'

        Extensions = @(
            '.ps1'
            '.psm1'
            '.psd1'
            '.json'
            '.md'
            '.txt'
        )

        ExcludeDirs = @(
            '.git'
            '.github'
            '.venv'
            'venv'
            'node_modules'
        )
    }
}
"@

    $null = Write-MowTestFile `
        -Root $Root `
        -RelativePath 'configs\mowpskit.psd1' `
        -Content $content

    $null = Write-MowTestFile `
        -Root $Root `
        -RelativePath 'version.txt' `
        -Content $Version
}


function New-MowBuildFixture {
    $root = New-MowTestRoot -Name 'build'

    foreach ($directory in @(
        'configs'
        'scripts'
        'src'
        'src\core'
        'src\internal'
        'src\functions'
        'src\resources'
        'dist'
    )) {
        [void][System.IO.Directory]::CreateDirectory(
            (Join-Path $root $directory)
        )
    }

    Copy-Item `
        -LiteralPath $loaderPath `
        -Destination (Join-Path $root 'src\loader.ps1')

    Copy-Item `
        -LiteralPath $buildPath `
        -Destination (Join-Path $root 'scripts\build.ps1')

    Write-MowBuildConfig -Root $root

    $null = Write-MowTestFile `
        -Root $root `
        -RelativePath 'src\core\base.ps1' `
        -Content @'
function FixtureBuildCore {
    'core'
}
'@

    $null = Write-MowTestFile `
        -Root $root `
        -RelativePath 'src\internal\shared.ps1' `
        -Content @'
$MowInternal = 'FixtureBuildInternal'

function FixtureBuildInternal {
    'internal'
}
'@

    $null = Write-MowTestFile `
        -Root $root `
        -RelativePath 'src\functions\run.ps1' `
        -Content @'
$MowExports = @(
    'Run'
    'Get-Resource'
)

function Run {
    "$(FixtureBuildCore)|$(FixtureBuildInternal)"
}

function Get-Resource {
    [Convert]::ToBase64String(
        [byte[]]$script:MowResources['blob.bin']
    )
}
'@

    $resourceBytes = [byte[]]@(
        0x00,
        0x01,
        0x02,
        0x03,
        0xFE,
        0xFF
    )

    [System.IO.File]::WriteAllBytes(
        (Join-Path $root 'src\resources\blob.bin'),
        $resourceBytes
    )

    return $root
}


# ============================================================
# Project contract
# ============================================================

foreach ($requiredPath in @(
    $loaderPath
    $buildPath
    $normalizePath
    $configPath
    $setupPath
    $versionPath
)) {
    if (-not [System.IO.File]::Exists($requiredPath)) {
        throw "Required project file not found: $requiredPath"
    }
}


# ============================================================
# 1. Architecture + namespace + scope
# ============================================================

Invoke-MowTest 'Architecture, namespace, public surface, and scope isolation' {
    $root = New-MowLoaderFixture -Name 'architecture'

    try {
        $null = Write-MowTestFile `
            -Root $root `
            -RelativePath 'core\base.ps1' `
            -Content @'
$MowExports = 'FixtureCorePublic'

function FixtureCoreShared {
    'core'
}

function FixtureShadow {
    'core-shadow'
}

function FixtureCorePublic {
    "core-public|$(FixtureCoreShared)"
}
'@

        $null = Write-MowTestFile `
            -Root $root `
            -RelativePath 'internal\shared.ps1' `
            -Content @'
$MowInternal = 'FixtureInternalShared'

function FixtureInternalPrivate {
    'internal-private'
}

function FixtureInternalShared {
    "internal|$(FixtureInternalPrivate)"
}
'@

        $null = Write-MowTestFile `
            -Root $root `
            -RelativePath 'functions\provider.ps1' `
            -Content @'
$MowInternal = 'FixtureFeatureShared'

function FixtureFeaturePrivate {
    'feature-private'
}

function FixtureFeatureShared {
    "feature|$(FixtureFeaturePrivate)"
}
'@

        $null = Write-MowTestFile `
            -Root $root `
            -RelativePath 'functions\alpha.ps1' `
            -Content @'
$MowExports = @(
    'Run'
    'Typed'
)

function FixtureShadow {
    'alpha-shadow'
}

function FixtureLocalOnly {
    'alpha-local'
}

function Run {
    "$(FixtureShadow)|$(FixtureCoreShared)|$(FixtureInternalShared)|$(FixtureFeatureShared)|$(FixtureLocalOnly)"
}

function Typed {
    param(
        [int]$Number
    )

    $Number
}
'@

        $null = Write-MowTestFile `
            -Root $root `
            -RelativePath 'functions\nested\beta.ps1' `
            -Content @'
$MowExports = 'Run'

function Run {
    "$(FixtureShadow)|$(FixtureCoreShared)|$(FixtureInternalShared)|$(FixtureFeatureShared)"
}
'@

        $null = Write-MowTestFile `
            -Root $root `
            -RelativePath 'functions\all.ps1' `
            -Content @'
$MowExports = 'all'

function First {
    'first'
}

function Second {
    'second'
}
'@

        $fixtureLoader = Join-Path $root 'loader.ps1'

        & $fixtureLoader `
            -Prefix '' `
            -CommandSeparator '' `
            -SourceRoot $root

        $expectedCommands = @(
            'all.First'
            'all.Second'
            'alpha.Run'
            'alpha.Typed'
            'base.FixtureCorePublic'
            'mow.help'
            'mow.install'
            'mow.reload'
            'mow.uninstall'
            'mow.unload'
            'mow.update'
            'mow.ver'
            'nested.beta.Run'
        ) | Sort-Object

        Assert-MowSequenceEqual `
            -Actual (Get-MowExportedNames) `
            -Expected $expectedCommands `
            -Message 'The exported command surface does not match the fixture contract.'

        Assert-MowEqual `
            -Actual (& 'alpha.Run') `
            -Expected 'alpha-shadow|core|internal|internal-private|feature|feature-private|alpha-local' `
            -Message 'File-private shadowing or shared function binding is incorrect.'

        Assert-MowEqual `
            -Actual (& 'nested.beta.Run') `
            -Expected 'core-shadow|core|internal|internal-private|feature|feature-private' `
            -Message 'Core or internal sharing across Source Units is incorrect.'

        Assert-MowEqual `
            -Actual (& 'all.First') `
            -Expected 'first' `
            -Message '$MowExports = all did not export the first function.'

        Assert-MowEqual `
            -Actual (& 'all.Second') `
            -Expected 'second' `
            -Message '$MowExports = all did not export the second function.'

        foreach ($privateName in @(
            'FixtureCoreShared'
            'FixtureShadow'
            'FixtureInternalShared'
            'FixtureInternalPrivate'
            'FixtureFeatureShared'
            'FixtureFeaturePrivate'
            'FixtureLocalOnly'
            'Run'
            'Typed'
        )) {
            Assert-MowTrue `
                -Condition ($null -eq (
                    Get-Command $privateName -ErrorAction SilentlyContinue
                )) `
                -Message "A non-public function leaked into the caller session: $privateName"
        }

        $typedCommand = Get-Command 'alpha.Typed' -ErrorAction Stop

        Assert-MowTrue `
            -Condition (
                $typedCommand.Parameters['Number'].ParameterType -eq [int]
            ) `
            -Message 'Public command parameter metadata was not preserved.'

        $helpCommands = @(
            & 'mow.help' |
                ForEach-Object { $_.Command } |
                Sort-Object
        )

        Assert-MowSequenceEqual `
            -Actual $helpCommands `
            -Expected $expectedCommands `
            -Message 'mow.help does not reflect the public command surface.'

        $versionInfo = & 'mow.ver'

        Assert-MowEqual `
            -Actual $versionInfo.Product `
            -Expected 'MowPSKit' `
            -Message 'mow.ver reported the wrong product.'

        Assert-MowEqual `
            -Actual $versionInfo.Mode `
            -Expected 'Ephemeral' `
            -Message 'Source fixture did not report Ephemeral runtime mode.'

        Assert-MowEqual `
            -Actual $versionInfo.BuildMode `
            -Expected 'Source' `
            -Message 'Source fixture did not report Source build mode.'

        Assert-MowEqual `
            -Actual $versionInfo.Version `
            -Expected '9.8.7' `
            -Message 'Source fixture did not read version.txt.'

        Assert-MowThrows `
            -Action {
                & 'mow.install' -ErrorAction Stop
            } `
            -Pattern 'SetupUrl.*not configured' `
            -Message 'mow.install did not reject an unconfigured SetupUrl.'

        $updateOutput = (& 'mow.update' 6>&1 | Out-String)
        $uninstallOutput = (& 'mow.uninstall' 6>&1 | Out-String)

        Assert-MowTrue `
            -Condition ($updateOutput -match 'not installed') `
            -Message 'Ephemeral mow.update did not report that MowPSKit is not installed.'

        Assert-MowTrue `
            -Condition ($uninstallOutput -match 'not installed') `
            -Message 'Ephemeral mow.uninstall did not report that MowPSKit is not installed.'
    }
    finally {
        Remove-MowLoaderFixture -SourceRoot $root
    }
}


# ============================================================
# 2. Prefix / separator behavior
# ============================================================

Invoke-MowTest 'Prefix and command separator composition' {
    $root = New-MowLoaderFixture -Name 'prefix'

    try {
        $null = Write-MowTestFile `
            -Root $root `
            -RelativePath 'functions\tool.ps1' `
            -Content @'
$MowExports = 'Go'

function Go {
    'ok'
}
'@

        & (Join-Path $root 'loader.ps1') `
            -Prefix 'x' `
            -CommandSeparator '-' `
            -SourceRoot $root

        Assert-MowEqual `
            -Actual (& 'x-tool.Go') `
            -Expected 'ok' `
            -Message 'Prefix + separator + namespace composition is incorrect.'

        Assert-MowTrue `
            -Condition ($null -eq (
                Get-Command 'tool.Go' -ErrorAction SilentlyContinue
            )) `
            -Message 'Unprefixed public command was exported unexpectedly.'

        foreach ($managementCommand in @(
            'mow.help'
            'mow.install'
            'mow.reload'
            'mow.uninstall'
            'mow.unload'
            'mow.update'
            'mow.ver'
        )) {
            Assert-MowTrue `
                -Condition ($null -ne (
                    Get-Command $managementCommand -ErrorAction SilentlyContinue
                )) `
                -Message "Management command must remain under mow.* regardless of Prefix: $managementCommand"
        }
    }
    finally {
        Remove-MowLoaderFixture -SourceRoot $root
    }
}


# ============================================================
# 3. Loader input validation
# ============================================================

Invoke-MowTest 'Loader validates Prefix and CommandSeparator' {
    $root = New-MowLoaderFixture -Name 'loader-input'

    try {
        $null = Write-MowTestFile `
            -Root $root `
            -RelativePath 'functions\tool.ps1' `
            -Content @'
$MowExports = 'Go'
function Go { 'ok' }
'@

        $fixtureLoader = Join-Path $root 'loader.ps1'

        Assert-MowThrows `
            -Action {
                & $fixtureLoader `
                    -Prefix 'bad.prefix' `
                    -CommandSeparator '.' `
                    -SourceRoot $root
            } `
            -Pattern 'prefix' `
            -Message 'Invalid Prefix was accepted.'

        Assert-MowThrows `
            -Action {
                & $fixtureLoader `
                    -Prefix 'x' `
                    -CommandSeparator "`n" `
                    -SourceRoot $root
            } `
            -Pattern 'CommandSeparator' `
            -Message 'A line break in CommandSeparator was accepted.'
    }
    finally {
        Remove-MowLoaderFixture -SourceRoot $root
    }
}


# ============================================================
# 4. Metadata contract
# ============================================================

Invoke-MowTest 'Metadata validation for MowExports and MowInternal' {
    $cases = @(
        [pscustomobject]@{
            Name = 'Undefined export'
            Content = @'
$MowExports = 'Missing'
function Present { 'x' }
'@
            Pattern = 'was not defined'
        }

        [pscustomobject]@{
            Name = 'Undefined internal'
            Content = @'
$MowInternal = 'Missing'
function Present { 'x' }
'@
            Pattern = 'was not defined'
        }

        [pscustomobject]@{
            Name = 'Non-string metadata'
            Content = @'
$MowExports = 123
function Present { 'x' }
'@
            Pattern = 'must contain only function names'
        }

        [pscustomobject]@{
            Name = 'all combined with another name'
            Content = @'
$MowExports = @(
    'all'
    'Present'
)
function Present { 'x' }
'@
            Pattern = "cannot combine 'all'"
        }

        [pscustomobject]@{
            Name = 'Case-insensitive duplicate metadata'
            Content = @'
$MowExports = @(
    'Present'
    'present'
)
function Present { 'x' }
'@
            Pattern = 'duplicate function'
        }
    )

    foreach ($case in $cases) {
        Reset-MowTestRuntime
        $root = New-MowLoaderFixture -Name 'metadata'

        try {
            $null = Write-MowTestFile `
                -Root $root `
                -RelativePath 'functions\case.ps1' `
                -Content $case.Content

            $fixtureLoader = Join-Path $root 'loader.ps1'

            Assert-MowThrows `
                -Action {
                    & $fixtureLoader `
                        -Prefix '' `
                        -CommandSeparator '' `
                        -SourceRoot $root
                } `
                -Pattern $case.Pattern `
                -Message ("Metadata case failed: {0}" -f $case.Name)
        }
        finally {
            Reset-MowTestRuntime
            Remove-MowLoaderFixture -SourceRoot $root
        }
    }
}


# ============================================================
# 5. Source Unit validation and collision rules
# ============================================================

Invoke-MowTest 'Source Unit syntax, naming, and collision validation' {
    $subtests = @(
        [pscustomobject]@{
            Name = 'Duplicate function in one Source Unit'
            Files = @{
                'functions\bad.ps1' = @'
function Duplicate { 'a' }
function duplicate { 'b' }
'@
            }
            Pattern = 'defines.*more than once'
        }

        [pscustomobject]@{
            Name = 'Scope-qualified function'
            Files = @{
                'functions\bad.ps1' = @'
function script:Bad {
    'x'
}
'@
            }
            Pattern = 'Scope-qualified function'
        }

        [pscustomobject]@{
            Name = 'PowerShell syntax error'
            Files = @{
                'functions\bad.ps1' = @'
function Broken {
'@
            }
            Pattern = 'syntax validation failed'
        }

        [pscustomobject]@{
            Name = 'Case-insensitive internal collision'
            Files = @{
                'core\a.ps1' = @'
function FixtureCollisionShared {
    'core'
}
'@
                'internal\b.ps1' = @'
$MowInternal = 'FIXTURECOLLISIONSHARED'

function FIXTURECOLLISIONSHARED {
    'internal'
}
'@
            }
            Pattern = 'internal function collision'
        }

        [pscustomobject]@{
            Name = 'Reserved public command'
            Files = @{
                'functions\mow.ps1' = @'
$MowExports = 'help'

function help {
    'bad'
}
'@
            }
            Pattern = 'reserved'
        }

        [pscustomobject]@{
            Name = 'Public namespace collision'
            Files = @{
                'functions\a.b.ps1' = @'
$MowExports = 'Run'

function Run {
    'flat'
}
'@
                'functions\a\b.ps1' = @'
$MowExports = 'Run'

function Run {
    'nested'
}
'@
            }
            Pattern = 'public command collision'
        }
    )

    foreach ($subtest in $subtests) {
        Reset-MowTestRuntime
        $root = New-MowLoaderFixture -Name 'validation'

        try {
            foreach ($relativePath in $subtest.Files.Keys) {
                $null = Write-MowTestFile `
                    -Root $root `
                    -RelativePath $relativePath `
                    -Content $subtest.Files[$relativePath]
            }

            $fixtureLoader = Join-Path $root 'loader.ps1'

            Assert-MowThrows `
                -Action {
                    & $fixtureLoader `
                        -Prefix '' `
                        -CommandSeparator '' `
                        -SourceRoot $root
                } `
                -Pattern $subtest.Pattern `
                -Message ("Validation case failed: {0}" -f $subtest.Name)
        }
        finally {
            Reset-MowTestRuntime
            Remove-MowLoaderFixture -SourceRoot $root
        }
    }
}


# ============================================================
# 6. Bundle input validation
# ============================================================

Invoke-MowTest 'Compiled bundle input validation' {
    $root = New-MowLoaderFixture -Name 'bundle'

    try {
        $fixtureLoader = Join-Path $root 'loader.ps1'

        $bundleCases = @(
            [pscustomobject]@{
                Name = 'Missing Units'
                Bundle = @{
                    Resources = @{}
                }
                Pattern = 'does not contain.*Units'
            }

            [pscustomobject]@{
                Name = 'Null Source Unit'
                Bundle = @{
                    Units = @($null)
                    Resources = @{}
                }
                Pattern = 'null Source Unit'
            }

            [pscustomobject]@{
                Name = 'Invalid category'
                Bundle = @{
                    Units = @(
                        [pscustomobject]@{
                            Category = 'other'
                            RelativePath = 'x.ps1'
                            Content = "function X { 'x' }"
                        }
                    )
                    Resources = @{}
                }
                Pattern = 'category'
            }

            [pscustomobject]@{
                Name = 'Source Unit path traversal'
                Bundle = @{
                    Units = @(
                        [pscustomobject]@{
                            Category = 'functions'
                            RelativePath = '../evil.ps1'
                            Content = "function X { 'x' }"
                        }
                    )
                    Resources = @{}
                }
                Pattern = 'Source Unit path'
            }

            [pscustomobject]@{
                Name = 'Resource path traversal'
                Bundle = @{
                    Units = @()
                    Resources = @{
                        '../secret.bin' = [byte[]]@(1, 2, 3)
                    }
                }
                Pattern = 'resource path'
            }


            [pscustomobject]@{
                Name = 'Invalid SetupUrl'
                Bundle = @{
                    Units = @()
                    Resources = @{}
                    SetupUrl = 'ftp://example.invalid/setup.ps1'
                }
                Pattern = 'SetupUrl.*HTTP/HTTPS'
            }
        )

        foreach ($case in $bundleCases) {
            Reset-MowTestRuntime

            Assert-MowThrows `
                -Action {
                    & $fixtureLoader `
                        -Prefix '' `
                        -CommandSeparator '' `
                        -Bundle $case.Bundle `
                        -ArtifactUrl ''
                } `
                -Pattern $case.Pattern `
                -Message ("Bundle validation failed: {0}" -f $case.Name)
        }

        Reset-MowTestRuntime

        & $fixtureLoader `
            -Prefix '' `
            -CommandSeparator '' `
            -Bundle @{
                Version = '2.3.4'
                BuildVersion = '2.3.4'
                Units = @()
                Resources = @{}
            } `
            -ArtifactUrl ''

        $bundleVersion = & 'mow.ver'

        Assert-MowEqual `
            -Actual $bundleVersion.Version `
            -Expected '2.3.4' `
            -Message 'Bundle.Version did not expose its product version.'

        Assert-MowEqual `
            -Actual $bundleVersion.BuildVersion `
            -Expected '2.3.4' `
            -Message 'Bundle.BuildVersion did not match the product version.'
    }
    finally {
        Remove-MowLoaderFixture -SourceRoot $root
    }
}


# ============================================================
# 7. Lifecycle: reload, rollback, unload
# ============================================================

Invoke-MowTest 'Runtime lifecycle, reload replacement, rollback, and unload' {
    $root = New-MowLoaderFixture -Name 'lifecycle'

    try {
        $versionPath = Write-MowTestFile `
            -Root $root `
            -RelativePath 'functions\version.ps1' `
            -Content @'
$MowExports = 'Get-Version'

function Get-Version {
    'v1'
}
'@

        $fixtureLoader = Join-Path $root 'loader.ps1'

        & $fixtureLoader `
            -Prefix 'x' `
            -CommandSeparator '-' `
            -SourceRoot $root

        $firstModule = Get-Module -Name $moduleName -ErrorAction Stop

        Assert-MowEqual `
            -Actual (& 'x-version.Get-Version') `
            -Expected 'v1' `
            -Message 'Initial runtime did not expose v1.'

        $null = Write-MowTestFile `
            -Root $root `
            -RelativePath 'functions\version.ps1' `
            -Content @'
$MowExports = 'Get-Version'

function Get-Version {
    'v2'
}
'@

        $sourceReloadOutput = @(
            & 'mow.reload' 6>&1
        ) -join [Environment]::NewLine

        $secondModule = Get-Module -Name $moduleName -ErrorAction Stop

        Assert-MowTrue `
            -Condition (-not [object]::ReferenceEquals(
                $firstModule,
                $secondModule
            )) `
            -Message 'Successful reload did not replace the runtime module.'

        Assert-MowEqual `
            -Actual (& 'x-version.Get-Version') `
            -Expected 'v2' `
            -Message 'Successful reload did not activate the new implementation.'

        Assert-MowEqual `
            -Actual (@(Get-Module -Name $moduleName -All).Count) `
            -Expected 1 `
            -Message 'Successful reload left multiple runtime modules loaded.'

        Assert-MowTrue `
            -Condition ($sourceReloadOutput -match 'reloaded from source loader') `
            -Message 'Source reload did not report that it used the source loader.'

        $null = Write-MowTestFile `
            -Root $root `
            -RelativePath 'functions\bad.ps1' `
            -Content @'
$MowExports = 'Missing'

function Present {
    'bad'
}
'@

        Assert-MowThrows `
            -Action {
                & 'mow.reload' -ErrorAction Stop
            } `
            -Pattern 'reload failed|was not defined' `
            -Message 'Failed reload did not report an error.'

        Assert-MowEqual `
            -Actual (& 'x-version.Get-Version') `
            -Expected 'v2' `
            -Message 'Failed reload removed or replaced the last good runtime.'

        Assert-MowEqual `
            -Actual (@(Get-Module -Name $moduleName -All).Count) `
            -Expected 1 `
            -Message 'Failed reload changed the number of active runtime modules.'

        & 'mow.unload'

        Assert-MowTrue `
            -Condition ($null -eq (
                Get-Module -Name $moduleName -ErrorAction SilentlyContinue
            )) `
            -Message 'mow.unload left the runtime module loaded.'

        foreach ($commandName in @(
            'x-version.Get-Version'
            'mow.help'
            'mow.ver'
            'mow.reload'
            'mow.install'
            'mow.update'
            'mow.uninstall'
            'mow.unload'
        )) {
            Assert-MowTrue `
                -Condition ($null -eq (
                    Get-Command $commandName -ErrorAction SilentlyContinue
                )) `
                -Message "mow.unload left a public command in the session: $commandName"
        }
    }
    finally {
        Remove-MowLoaderFixture -SourceRoot $root
    }
}


Invoke-MowTest 'Management routing, remote/installed reload, and local uninstall' {
    $root = New-MowLoaderFixture -Name 'setup-boundary'
    $oldInvokeRestMethod = Get-Item `
        -LiteralPath 'Function:\global:Invoke-RestMethod' `
        -ErrorAction SilentlyContinue

    try {
        $fixtureLoader = Join-Path $root 'loader.ps1'
        $entryPointPath = Join-Path $root 'MowPSKit.ps1'
        $metadataPath = Join-Path $root 'install.json'
        $profilePath = Join-Path (Split-Path $root -Parent) 'profile.ps1'
        $global:MowSetupBoundaryLoader = $fixtureLoader
        $global:MowSetupBoundaryEntryPoint = $entryPointPath
        $global:MowSetupBoundaryDownloadCount = 0
        $global:MowSetupBoundaryActions = @()
        $global:MowSetupBoundaryCalls = @()
        $global:MowSetupBoundarySource = @'
param(
    [ValidateSet('Install', 'Update')]
    [string]$Action = 'Install',
    [string]$InstallDir = '',
    [string]$ProfilePath = ''
)

$global:MowSetupBoundaryActions += $Action
$global:MowSetupBoundaryCalls += [pscustomobject]@{
    Action = $Action
    InstallDir = $InstallDir
    ProfilePath = $ProfilePath
}
'@

        $global:MowSetupBoundaryArtifactSource = @'
[CmdletBinding()]
param(
    [string]$Prefix = '',
    [string]$CommandSeparator = '',
    [string]$ArtifactUrl = 'https://example.invalid/MowPSKit.ps1',
    [string]$EntryPointPath = $PSCommandPath,
    [switch]$VersionOnly
)

Microsoft.PowerShell.Utility\Set-Variable -Name MowPSKitVersion -Value '2.0.0' -Option Constant -Scope Local

if ($VersionOnly) {
    return $MowPSKitVersion
}

& $global:MowSetupBoundaryLoader `
    -Prefix $Prefix `
    -CommandSeparator $CommandSeparator `
    -EntryPointPath $EntryPointPath `
    -Bundle @{
        Version = $MowPSKitVersion
        BuildVersion = $MowPSKitVersion
        Units = @()
        Resources = @{}
        SetupUrl = 'https://example.invalid/setup.ps1'
    } `
    -ArtifactUrl $ArtifactUrl
'@

        $null = Write-MowTestFile `
            -Root $root `
            -RelativePath 'MowPSKit.ps1' `
            -Content @'
[CmdletBinding()]
param(
    [string]$Prefix = '',
    [string]$CommandSeparator = '',
    [string]$ArtifactUrl = 'https://example.invalid/MowPSKit.ps1',
    [string]$EntryPointPath = $PSCommandPath,
    [switch]$VersionOnly
)

Microsoft.PowerShell.Utility\Set-Variable -Name MowPSKitVersion -Value '1.0.0' -Option Constant -Scope Local

if ($VersionOnly) {
    return $MowPSKitVersion
}

& $global:MowSetupBoundaryLoader `
    -Prefix $Prefix `
    -CommandSeparator $CommandSeparator `
    -EntryPointPath $EntryPointPath `
    -Bundle @{
        Version = $MowPSKitVersion
        BuildVersion = $MowPSKitVersion
        Units = @()
        Resources = @{}
        SetupUrl = 'https://example.invalid/setup.ps1'
    } `
    -ArtifactUrl $ArtifactUrl
'@

        $metadata = [ordered]@{
            Product = 'MowPSKit'
            Version = '1.0.0'
            InstallPath = $entryPointPath
            ProfilePaths = @($profilePath)
            ArtifactUrl = 'https://example.invalid/MowPSKit.ps1'
            InstalledAt = '2000-01-01T00:00:00.0000000Z'
        } | ConvertTo-Json

        $null = Write-MowTestFile `
            -Root $root `
            -RelativePath 'install.json' `
            -Content $metadata

        $null = Write-MowTestFile `
            -Root (Split-Path $root -Parent) `
            -RelativePath 'profile.ps1' `
            -Content @'
# existing profile
# >>> MowPSKit >>>
& 'fixture MowPSKit.ps1'
# <<< MowPSKit <<<
'@

        function global:Invoke-RestMethod {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)]
                [string]$Uri
            )

            $global:MowSetupBoundaryDownloadCount++

            if ($Uri -match '/MowPSKit\.ps1(?:\?|$)') {
                return $global:MowSetupBoundaryArtifactSource
            }

            return $global:MowSetupBoundarySource
        }

        # A compiled runtime outside an installation reloads from ArtifactUrl.
        & $fixtureLoader `
            -Prefix '' `
            -CommandSeparator '' `
            -Bundle @{
                Version = '1.0.0'
                BuildVersion = '1.0.0'
                Units = @()
                Resources = @{}
                SetupUrl = 'https://example.invalid/setup.ps1'
            } `
            -ArtifactUrl 'https://example.invalid/MowPSKit.ps1'

        & 'mow.install'

        Assert-MowSequenceEqual `
            -Actual $global:MowSetupBoundaryActions `
            -Expected @('Install') `
            -Message 'Ephemeral mow.install did not invoke the root setup with Install.'

        $remoteReloadOutput = @(
            & 'mow.reload' 6>&1
        ) -join [Environment]::NewLine

        Assert-MowEqual `
            -Actual (& 'mow.ver').Version `
            -Expected '2.0.0' `
            -Message 'Ephemeral compiled reload did not activate the remote artifact.'

        Assert-MowTrue `
            -Condition ($remoteReloadOutput -match 'reloaded from remote artifact') `
            -Message 'Ephemeral compiled reload did not report the remote artifact route.'

        Reset-MowTestRuntime

        # A compiled runtime with matching install metadata is Installed.
        & $fixtureLoader `
            -Prefix '' `
            -CommandSeparator '' `
            -EntryPointPath $entryPointPath `
            -Bundle @{
                Version = '1.0.0'
                BuildVersion = '1.0.0'
                Units = @()
                Resources = @{}
                SetupUrl = 'https://example.invalid/setup.ps1'
            } `
            -ArtifactUrl 'https://example.invalid/MowPSKit.ps1'

        $versionInfo = & 'mow.ver'

        Assert-MowEqual `
            -Actual $versionInfo.Mode `
            -Expected 'Installed' `
            -Message 'Installed runtime metadata was not detected.'

        Assert-MowEqual `
            -Actual $versionInfo.BuildMode `
            -Expected 'Compiled' `
            -Message 'Installed runtime did not retain Compiled build mode.'

        $downloadsBeforeInstalledReload = $global:MowSetupBoundaryDownloadCount
        $installedReloadOutput = @(
            & 'mow.reload' 6>&1
        ) -join [Environment]::NewLine

        Assert-MowEqual `
            -Actual $global:MowSetupBoundaryDownloadCount `
            -Expected $downloadsBeforeInstalledReload `
            -Message 'Installed reload made an unexpected network request.'

        Assert-MowTrue `
            -Condition ($installedReloadOutput -match 'reloaded from installed file') `
            -Message 'Installed reload did not report the installed file route.'

        & 'mow.install'
        & 'mow.update'

        Assert-MowSequenceEqual `
            -Actual $global:MowSetupBoundaryActions `
            -Expected @('Install', 'Install', 'Update') `
            -Message 'Installed management commands used the wrong setup actions.'

        foreach ($installedCall in @(
            $global:MowSetupBoundaryCalls[1]
            $global:MowSetupBoundaryCalls[2]
        )) {
            Assert-MowEqual `
                -Actual $installedCall.InstallDir `
                -Expected $root `
                -Message 'Installed management did not preserve its custom install directory.'
            Assert-MowEqual `
                -Actual $installedCall.ProfilePath `
                -Expected $profilePath `
                -Message 'Installed management did not preserve its recorded Profile path.'
        }

        $downloadsBeforeUninstall = $global:MowSetupBoundaryDownloadCount

        & 'mow.uninstall'

        Assert-MowEqual `
            -Actual $global:MowSetupBoundaryDownloadCount `
            -Expected $downloadsBeforeUninstall `
            -Message 'mow.uninstall made an unexpected network request.'

        Assert-MowFalse `
            -Condition ([System.IO.File]::Exists($entryPointPath)) `
            -Message 'mow.uninstall left the installed runtime file behind.'

        Assert-MowFalse `
            -Condition ([System.IO.File]::Exists($metadataPath)) `
            -Message 'mow.uninstall left installation metadata behind.'

        Assert-MowTrue `
            -Condition ([System.IO.File]::Exists($fixtureLoader)) `
            -Message 'mow.uninstall deleted an unrelated file from a shared install directory.'

        Assert-MowEqual `
            -Actual @(
                Microsoft.PowerShell.Core\Get-Module `
                    -Name $moduleName `
                    -All
            ).Count `
            -Expected 0 `
            -Message 'mow.uninstall left the runtime loaded.'

        $profileAfterUninstall = Get-Content `
            -LiteralPath $profilePath `
            -Raw `
            -Encoding UTF8

        Assert-MowEqual `
            -Actual $profileAfterUninstall.Trim() `
            -Expected '# existing profile' `
            -Message 'mow.uninstall did not remove only the managed profile block.'
    }
    finally {
        Remove-Item `
            -LiteralPath 'Function:\global:Invoke-RestMethod' `
            -Force `
            -ErrorAction SilentlyContinue

        if ($oldInvokeRestMethod) {
            Set-Item `
                -LiteralPath 'Function:\global:Invoke-RestMethod' `
                -Value $oldInvokeRestMethod.ScriptBlock
        }

        foreach ($variableName in @(
            'MowSetupBoundaryLoader'
            'MowSetupBoundaryEntryPoint'
            'MowSetupBoundaryDownloadCount'
            'MowSetupBoundarySource'
            'MowSetupBoundaryArtifactSource'
            'MowSetupBoundaryActions'
            'MowSetupBoundaryCalls'
        )) {
            Remove-Variable `
                -Name $variableName `
                -Scope Global `
                -ErrorAction SilentlyContinue
        }

        Remove-MowLoaderFixture -SourceRoot $root
    }
}


# ============================================================
# 8. Build: source/compiled parity, resources, encoding
# ============================================================

Invoke-MowTest 'Build output, Source/Compiled parity, resources, and determinism' {
    $root = New-MowBuildFixture
    $callerRoot = New-MowTestRoot -Name 'build-caller'
    $oldGitHubActions = $env:GITHUB_ACTIONS
    $oldGitHubSha = $env:GITHUB_SHA
    $oldGitHubRunNumber = $env:GITHUB_RUN_NUMBER

    try {
        $fixtureLoader = Join-Path $root 'src\loader.ps1'
        $fixtureBuild = Join-Path $root 'scripts\build.ps1'
        $artifactPath = Join-Path $root 'dist\MowPSKit.ps1'

        # Source Mode snapshot.
        & $fixtureLoader `
            -Prefix '' `
            -CommandSeparator '' `
            -SourceRoot (Join-Path $root 'src')

        $sourceCommands = Get-MowExportedNames
        $sourceRun = & 'run.Run'
        $sourceResource = & 'run.Get-Resource'
        $sourceVersion = & 'mow.ver'

        Assert-MowEqual `
            -Actual $sourceVersion.Mode `
            -Expected 'Ephemeral' `
            -Message 'Fixture source runtime did not use Ephemeral mode.'

        Assert-MowEqual `
            -Actual $sourceVersion.BuildMode `
            -Expected 'Source' `
            -Message 'Fixture source runtime did not use Source build mode.'

        Assert-MowEqual `
            -Actual $sourceVersion.Version `
            -Expected '9.8.7' `
            -Message 'Source Mode did not read the root version.txt.'


        Assert-MowEqual `
            -Actual $sourceVersion.SetupUrl `
            -Expected 'https://example.invalid/MowPSKit/setup.ps1' `
            -Message 'Source Mode did not read Build.SetupUrl from mowpskit.psd1.'

        & 'mow.unload'

        # CI metadata must not change an artifact built from identical input.
        $env:GITHUB_ACTIONS = 'true'
        $env:GITHUB_SHA = '1111111111111111111111111111111111111111'
        $env:GITHUB_RUN_NUMBER = '1'

        # Invoke the build outside the fixture repository. The embedded commit
        # must still come from the fixture project root.
        Push-Location $callerRoot

        try {
            & $fixtureBuild
        }
        finally {
            Pop-Location
        }

        Assert-MowTrue `
            -Condition ([System.IO.File]::Exists($artifactPath)) `
            -Message 'build.ps1 did not create the configured artifact.'

        $firstBuildBytes = [System.IO.File]::ReadAllBytes($artifactPath)

        $hasUtf8Bom = (
            $firstBuildBytes.Length -ge 3 -and
            $firstBuildBytes[0] -eq 0xEF -and
            $firstBuildBytes[1] -eq 0xBB -and
            $firstBuildBytes[2] -eq 0xBF
        )

        Assert-MowFalse `
            -Condition $hasUtf8Bom `
            -Message 'Artifact contains a UTF-8 BOM.'

        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $artifactText = $strictUtf8.GetString($firstBuildBytes)

        Assert-MowFalse `
            -Condition ($artifactText -match "(?<!`r)`n") `
            -Message 'Artifact contains LF that is not part of CRLF.'

        Assert-MowFalse `
            -Condition ($artifactText -match "`r(?!`n)") `
            -Message 'Artifact contains CR that is not part of CRLF.'

        $tokens = $null
        $parseErrors = $null

        [void][System.Management.Automation.Language.Parser]::ParseInput(
            $artifactText,
            [ref]$tokens,
            [ref]$parseErrors
        )

        Assert-MowEqual `
            -Actual $parseErrors.Count `
            -Expected 0 `
            -Message 'Generated artifact contains PowerShell syntax errors.'

        Assert-MowTrue `
            -Condition (
                $artifactText -match
                "(?m)^\s*Microsoft\.PowerShell\.Utility\\Set-Variable\s+-Name\s+MowPSKitVersion\s+-Value\s+'9\.8\.7'\s+-Option\s+Constant\s+-Scope\s+Local\s*$"
            ) `
            -Message 'Generated artifact did not embed version.txt as the MowPSKitVersion Constant.'

        # Build again. With identical source/config/Git state the artifact
        # should be byte-for-byte identical.
        $env:GITHUB_SHA = '2222222222222222222222222222222222222222'
        $env:GITHUB_RUN_NUMBER = '999'

        Push-Location $callerRoot

        try {
            & $fixtureBuild
        }
        finally {
            Pop-Location
        }

        $secondBuildBytes = [System.IO.File]::ReadAllBytes($artifactPath)

        Assert-MowEqual `
            -Actual ([Convert]::ToBase64String($secondBuildBytes)) `
            -Expected ([Convert]::ToBase64String($firstBuildBytes)) `
            -Message 'Two identical builds produced different artifact bytes.'

        $versionOnly = & $artifactPath -VersionOnly

        Assert-MowEqual `
            -Actual $versionOnly `
            -Expected '9.8.7' `
            -Message 'Artifact -VersionOnly did not return the embedded product version.'

        Assert-MowEqual `
            -Actual @(Get-Module -Name $moduleName -All).Count `
            -Expected 0 `
            -Message 'Artifact -VersionOnly unexpectedly loaded a runtime module.'

        # Compiled build running outside an installation is Ephemeral.
        & $artifactPath

        $compiledCommands = Get-MowExportedNames
        $compiledRun = & 'run.Run'
        $compiledResource = & 'run.Get-Resource'
        $compiledVersion = & 'mow.ver'

        Assert-MowSequenceEqual `
            -Actual $compiledCommands `
            -Expected $sourceCommands `
            -Message 'Source Mode and Compiled Mode export different command surfaces.'

        Assert-MowEqual `
            -Actual $compiledRun `
            -Expected $sourceRun `
            -Message 'Source Mode and Compiled Mode execute different function behavior.'

        Assert-MowEqual `
            -Actual $compiledResource `
            -Expected $sourceResource `
            -Message 'Bundled resource bytes differ from Source Mode resource bytes.'

        Assert-MowEqual `
            -Actual $compiledResource `
            -Expected 'AAECA/7/' `
            -Message 'The binary resource was not preserved byte-for-byte.'

        Assert-MowEqual `
            -Actual $compiledVersion.Mode `
            -Expected 'Ephemeral' `
            -Message 'Built artifact did not report Ephemeral runtime mode.'

        Assert-MowEqual `
            -Actual $compiledVersion.BuildMode `
            -Expected 'Compiled' `
            -Message 'Built artifact did not report Compiled build mode.'

        Assert-MowEqual `
            -Actual $compiledVersion.Version `
            -Expected $sourceVersion.Version `
            -Message 'Source and Compiled Mode release versions differ.'


        Assert-MowEqual `
            -Actual $compiledVersion.SetupUrl `
            -Expected $sourceVersion.SetupUrl `
            -Message 'Compiled Mode did not preserve Build.SetupUrl from the build config.'

        Assert-MowEqual `
            -Actual $compiledVersion.BuildVersion `
            -Expected $sourceVersion.Version `
            -Message "Unexpected BuildVersion: $($compiledVersion.BuildVersion)"

        & 'mow.unload'
    }
    finally {
        $env:GITHUB_ACTIONS = $oldGitHubActions
        $env:GITHUB_SHA = $oldGitHubSha
        $env:GITHUB_RUN_NUMBER = $oldGitHubRunNumber

        Remove-MowTestRoot -Path $callerRoot
        Remove-MowTestRoot -Path $root
    }
}


# ============================================================
# 9. Build safety rules
# ============================================================

Invoke-MowTest 'Builder rejects output inside src' {
    $root = New-MowBuildFixture

    try {
        Write-MowBuildConfig `
            -Root $root `
            -OutputPath 'src\artifact.ps1'

        $fixtureBuild = Join-Path $root 'scripts\build.ps1'

        Push-Location $root

        try {
            Assert-MowThrows `
                -Action {
                    & $fixtureBuild
                } `
                -Pattern 'cannot be written inside src' `
                -Message 'Builder accepted an output path inside src.'
        }
        finally {
            Pop-Location
        }
    }
    finally {
        Remove-MowTestRoot -Path $root
    }
}


# ============================================================
# 10. Setup execution policy and transaction rollback
# ============================================================

Invoke-MowTest 'Setup handles blocked profile execution policies before file changes' {
    $root = New-MowTestRoot -Name 'setup-policy'
    $mockedCommands = @(
        'Get-ExecutionPolicy'
        'Set-ExecutionPolicy'
        'Read-Host'
        'Invoke-RestMethod'
    )
    $originalFunctions = @{}

    foreach ($commandName in $mockedCommands) {
        $existingFunction = Get-Item `
            -LiteralPath "Function:\global:$commandName" `
            -ErrorAction SilentlyContinue

        if ($existingFunction) {
            $originalFunctions[$commandName] = $existingFunction.ScriptBlock
        }
    }

    try {
        $global:MowSetupEffectivePolicy = 'Restricted'
        $global:MowSetupPolicyList = @(
            [pscustomobject]@{
                Scope = 'MachinePolicy'
                ExecutionPolicy = 'Undefined'
            }
            [pscustomobject]@{
                Scope = 'UserPolicy'
                ExecutionPolicy = 'Undefined'
            }
        )
        $global:MowSetupPolicyResponse = 'Y'
        $global:MowSetupReadHostCalls = 0
        $global:MowSetupSetPolicyCalls = 0
        $global:MowSetupDownloadCalls = 0
        $global:MowSetupSetPolicyArguments = $null

        function global:Get-ExecutionPolicy {
            param(
                [switch]$List
            )

            if ($List) {
                return $global:MowSetupPolicyList
            }

            return $global:MowSetupEffectivePolicy
        }

        function global:Read-Host {
            param(
                [string]$Prompt
            )

            $global:MowSetupReadHostCalls++

            return $global:MowSetupPolicyResponse
        }

        function global:Set-ExecutionPolicy {
            param(
                [string]$Scope,
                [string]$ExecutionPolicy,
                [switch]$Force
            )

            $global:MowSetupSetPolicyCalls++
            $global:MowSetupSetPolicyArguments = [pscustomobject]@{
                Scope = $Scope
                ExecutionPolicy = $ExecutionPolicy
                Force = $Force.IsPresent
            }
            $global:MowSetupEffectivePolicy = 'RemoteSigned'
        }

        function global:Invoke-RestMethod {
            param(
                [string]$Uri,
                [string]$OutFile
            )

            $global:MowSetupDownloadCalls++

            $artifact = @'
[CmdletBinding()]
param(
    [switch]$VersionOnly
)

Microsoft.PowerShell.Utility\Set-Variable -Name MowPSKitVersion -Value '1.0.0' -Option Constant -Scope Local

if ($VersionOnly) {
    return $MowPSKitVersion
}

throw 'Policy fixture artifact executed.'
'@

            [System.IO.File]::WriteAllText(
                $OutFile,
                $artifact,
                (New-Object System.Text.UTF8Encoding($false))
            )
        }

        $acceptedInstallDir = Join-Path $root 'accepted-install'

        Assert-MowThrows `
            -Action {
                & $setupPath `
                    -Action Install `
                    -ArtifactUrl 'https://example.invalid/MowPSKit.ps1' `
                    -InstallDir $acceptedInstallDir `
                    -ProfilePath (Join-Path $root 'accepted-profile.ps1') `
                    -Force
            } `
            -Pattern 'Policy fixture artifact executed' `
            -Message 'Setup did not continue after the policy change was accepted.'

        Assert-MowEqual `
            -Actual $global:MowSetupReadHostCalls `
            -Expected 1 `
            -Message 'Setup did not ask once before changing the execution policy.'
        Assert-MowEqual `
            -Actual $global:MowSetupSetPolicyCalls `
            -Expected 1 `
            -Message 'Setup did not change the accepted policy exactly once.'
        Assert-MowEqual `
            -Actual $global:MowSetupSetPolicyArguments.Scope `
            -Expected 'CurrentUser' `
            -Message 'Setup changed the wrong execution-policy scope.'
        Assert-MowEqual `
            -Actual $global:MowSetupSetPolicyArguments.ExecutionPolicy `
            -Expected 'RemoteSigned' `
            -Message 'Setup selected the wrong execution policy.'
        Assert-MowTrue `
            -Condition $global:MowSetupSetPolicyArguments.Force `
            -Message 'Setup did not suppress the second built-in policy prompt.'
        Assert-MowEqual `
            -Actual $global:MowSetupDownloadCalls `
            -Expected 1 `
            -Message 'Setup did not reach the download after fixing the policy.'
        Assert-MowFalse `
            -Condition ([System.IO.Directory]::Exists($acceptedInstallDir)) `
            -Message 'Failed setup left the newly created installation directory.'

        $global:MowSetupEffectivePolicy = 'Restricted'
        $global:MowSetupPolicyResponse = 'N'
        $global:MowSetupReadHostCalls = 0
        $global:MowSetupSetPolicyCalls = 0
        $global:MowSetupDownloadCalls = 0
        $declinedInstallDir = Join-Path $root 'declined-install'

        Assert-MowThrows `
            -Action {
                & $setupPath `
                    -Action Install `
                    -ArtifactUrl 'https://example.invalid/MowPSKit.ps1' `
                    -InstallDir $declinedInstallDir `
                    -ProfilePath (Join-Path $root 'declined-profile.ps1') `
                    -Force
            } `
            -Pattern 'cancelled before any files were changed' `
            -Message 'Setup did not stop when the policy change was declined.'

        Assert-MowEqual `
            -Actual $global:MowSetupSetPolicyCalls `
            -Expected 0 `
            -Message 'Setup changed the policy after the user declined.'
        Assert-MowEqual `
            -Actual $global:MowSetupDownloadCalls `
            -Expected 1 `
            -Message 'Setup did not download exactly one artifact before the policy decision.'
        Assert-MowFalse `
            -Condition ([System.IO.Directory]::Exists($declinedInstallDir)) `
            -Message 'Setup created the installation directory after a decline.'

        $global:MowSetupEffectivePolicy = 'Restricted'
        $global:MowSetupPolicyList = @(
            [pscustomobject]@{
                Scope = 'MachinePolicy'
                ExecutionPolicy = 'Restricted'
            }
        )
        $global:MowSetupPolicyResponse = 'Y'
        $global:MowSetupReadHostCalls = 0
        $global:MowSetupSetPolicyCalls = 0
        $global:MowSetupDownloadCalls = 0
        $managedInstallDir = Join-Path $root 'managed-install'

        Assert-MowThrows `
            -Action {
                & $setupPath `
                    -Action Install `
                    -ArtifactUrl 'https://example.invalid/MowPSKit.ps1' `
                    -InstallDir $managedInstallDir `
                    -ProfilePath (Join-Path $root 'managed-profile.ps1') `
                    -Force
            } `
            -Pattern 'MachinePolicy' `
            -Message 'Setup did not stop for a managed blocking policy.'

        Assert-MowEqual `
            -Actual $global:MowSetupReadHostCalls `
            -Expected 0 `
            -Message 'Setup prompted despite a managed blocking policy.'
        Assert-MowEqual `
            -Actual $global:MowSetupSetPolicyCalls `
            -Expected 0 `
            -Message 'Setup tried to override a managed execution policy.'
        Assert-MowEqual `
            -Actual $global:MowSetupDownloadCalls `
            -Expected 1 `
            -Message 'Setup did not limit the managed-policy path to one artifact download.'
        Assert-MowFalse `
            -Condition ([System.IO.Directory]::Exists($managedInstallDir)) `
            -Message 'Setup created the installation directory for a managed policy.'
    }
    finally {
        foreach ($commandName in $mockedCommands) {
            Remove-Item `
                -LiteralPath "Function:\global:$commandName" `
                -Force `
                -ErrorAction SilentlyContinue

            if ($originalFunctions.ContainsKey($commandName)) {
                Set-Item `
                    -LiteralPath "Function:\global:$commandName" `
                    -Value $originalFunctions[$commandName]
            }
        }

        foreach ($variableName in @(
            'MowSetupEffectivePolicy'
            'MowSetupPolicyList'
            'MowSetupPolicyResponse'
            'MowSetupReadHostCalls'
            'MowSetupSetPolicyCalls'
            'MowSetupDownloadCalls'
            'MowSetupSetPolicyArguments'
        )) {
            Remove-Variable `
                -Name $variableName `
                -Scope Global `
                -ErrorAction SilentlyContinue
        }

        Remove-MowTestRoot -Path $root
    }
}


Invoke-MowTest 'Setup version decisions, transaction rollback, and installed metadata' {
    $root = New-MowTestRoot -Name 'setup-rollback'
    $runtimeRoot = New-MowLoaderFixture -Name 'setup-runtime'
    $oldInvokeRestMethod = Get-Item `
        -LiteralPath 'Function:\global:Invoke-RestMethod' `
        -ErrorAction SilentlyContinue

    try {
        $installDir = Join-Path $root 'install'
        $installPath = Join-Path $installDir 'MowPSKit.ps1'
        $metadataPath = Join-Path $installDir 'install.json'
        $profilePath = Join-Path $root 'profile\profile.ps1'
        $badArtifactPath = Join-Path $root 'bad-artifact.ps1'
        $goodArtifactPath = Join-Path $root 'good-artifact.ps1'
        $lowerArtifactPath = Join-Path $root 'lower-artifact.ps1'

        [void][System.IO.Directory]::CreateDirectory($installDir)
        [void][System.IO.Directory]::CreateDirectory(
            (Split-Path $profilePath -Parent)
        )

        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)

        [System.IO.File]::WriteAllText(
            $installPath,
            (
                "Microsoft.PowerShell.Utility\Set-Variable " +
                "-Name MowPSKitVersion -Value '1.0.0' " +
                "-Option Constant -Scope Local`r`n"
            ),
            $utf8
        )
        [System.IO.File]::WriteAllText(
            $metadataPath,
            '{"old":true}',
            $utf8
        )
        [System.IO.File]::WriteAllText(
            $profilePath,
            "# existing profile`r`n",
            $utf8
        )
        [System.IO.File]::WriteAllText(
            $badArtifactPath,
            (
                "Microsoft.PowerShell.Utility\Set-Variable " +
                "-Name MowPSKitVersion -Value '2.0.0' " +
                "-Option Constant -Scope Local`r`n" +
                "Remove-Item Function:\Restore-MowFileSnapshot -Force " +
                "-ErrorAction SilentlyContinue`r`n" +
                "throw 'Fixture artifact load failed.'`r`n"
            ),
            $utf8
        )

        $installBefore = [System.IO.File]::ReadAllBytes($installPath)
        $metadataBefore = [System.IO.File]::ReadAllBytes($metadataPath)
        $profileBefore = [System.IO.File]::ReadAllBytes($profilePath)

        $null = Write-MowTestFile `
            -Root $runtimeRoot `
            -RelativePath 'functions\old.ps1' `
            -Content @'
$MowExports = 'Get-OldRuntimeValue'

function Get-OldRuntimeValue {
    'old runtime'
}
'@

        & (Join-Path $runtimeRoot 'loader.ps1') `
            -SourceRoot $runtimeRoot

        $oldModule = Get-Module -Name $moduleName -ErrorAction Stop
        $global:MowSetupTestArtifactPath = $badArtifactPath
        $global:MowSetupTestDownloadCount = 0

        function global:Invoke-RestMethod {
            param(
                [Parameter(Mandatory)]
                [string]$Uri,

                [Parameter(Mandatory)]
                [string]$OutFile
            )

            if ($Uri -notmatch '/MowPSKit\.ps1(?:\?|$)') {
                throw "Setup downloaded an unexpected URL: $Uri"
            }

            $global:MowSetupTestDownloadCount++

            Copy-Item `
                -LiteralPath $global:MowSetupTestArtifactPath `
                -Destination $OutFile `
                -Force
        }

        Assert-MowThrows `
            -Action {
                & $setupPath -Action Uninstall -Force
            } `
            -Message 'setup.ps1 accepted an action other than Install or Update.'

        Assert-MowThrows `
            -Action {
                & $setupPath `
                    -Action Update `
                    -ArtifactUrl 'https://example.invalid/MowPSKit.ps1' `
                    -InstallDir $installDir `
                    -ProfilePath $profilePath `
                    -Force
            } `
            -Pattern 'Fixture artifact load failed' `
            -Message 'A runtime-invalid update did not fail.'

        Assert-MowEqual `
            -Actual $global:MowSetupTestDownloadCount `
            -Expected 1 `
            -Message 'Failed update did not download exactly one artifact.'

        Assert-MowEqual `
            -Actual ([Convert]::ToBase64String(
                [System.IO.File]::ReadAllBytes($installPath)
            )) `
            -Expected ([Convert]::ToBase64String($installBefore)) `
            -Message 'Failed setup did not restore the installed artifact bytes.'

        Assert-MowEqual `
            -Actual ([Convert]::ToBase64String(
                [System.IO.File]::ReadAllBytes($metadataPath)
            )) `
            -Expected ([Convert]::ToBase64String($metadataBefore)) `
            -Message 'Failed setup did not restore metadata bytes.'

        Assert-MowEqual `
            -Actual ([Convert]::ToBase64String(
                [System.IO.File]::ReadAllBytes($profilePath)
            )) `
            -Expected ([Convert]::ToBase64String($profileBefore)) `
            -Message 'Failed setup did not restore profile bytes.'

        $currentModule = Get-Module -Name $moduleName -ErrorAction Stop

        Assert-MowTrue `
            -Condition ([object]::ReferenceEquals($oldModule, $currentModule)) `
            -Message 'Failed setup replaced or unloaded the previous runtime.'

        Assert-MowEqual `
            -Actual (& 'old.Get-OldRuntimeValue') `
            -Expected 'old runtime' `
            -Message 'The previous runtime stopped working after setup rollback.'

        $stagedFiles = @(
            Get-ChildItem `
                -LiteralPath $installDir `
                -File `
                -Filter '*.download'
        )

        Assert-MowEqual `
            -Actual $stagedFiles.Count `
            -Expected 0 `
            -Message 'Setup left staged download files after rollback.'

        $fixtureLoaderLiteral = (Join-Path $runtimeRoot 'loader.ps1').Replace(
            "'",
            "''"
        )
        $obsoleteInstallPath = Join-Path $root 'obsolete\MowPSKit.ps1'
        $obsoleteInstallLiteral = $obsoleteInstallPath.Replace("'", "''")
        $expectedInstallLiteral = $installPath.Replace("'", "''")

        [System.IO.File]::WriteAllText(
            $profilePath,
            (
                "# existing profile`r`n" +
                "# >>> MowPSKit >>>`r`n" +
                "if (Test-Path -LiteralPath '$obsoleteInstallLiteral') { " +
                "& '$obsoleteInstallLiteral' }`r`n" +
                "# <<< MowPSKit <<<`r`n"
            ),
            $utf8
        )

        $goodArtifact = @"
[CmdletBinding()]
param(
    [string]`$Prefix = '',
    [string]`$CommandSeparator = '',
    [string]`$ArtifactUrl = 'https://example.invalid/MowPSKit.ps1',
    [string]`$EntryPointPath = `$PSCommandPath,
    [switch]`$VersionOnly
)

Microsoft.PowerShell.Utility\Set-Variable -Name MowPSKitVersion -Value '2.0.0' -Option Constant -Scope Local

if (`$VersionOnly) {
    return `$MowPSKitVersion
}

& '$fixtureLoaderLiteral' ``
    -Prefix `$Prefix ``
    -CommandSeparator `$CommandSeparator ``
    -EntryPointPath `$EntryPointPath ``
    -Bundle @{
        Version = `$MowPSKitVersion
        BuildVersion = `$MowPSKitVersion
        Units = @()
        Resources = @{}
        SetupUrl = 'https://example.invalid/setup.ps1'
    } ``
    -ArtifactUrl `$ArtifactUrl
"@

        [System.IO.File]::WriteAllText(
            $goodArtifactPath,
            $goodArtifact,
            $utf8
        )

        $global:MowSetupTestArtifactPath = $goodArtifactPath

        & $setupPath `
            -Action Install `
            -ArtifactUrl 'https://example.invalid/MowPSKit.ps1' `
            -InstallDir $installDir `
            -ProfilePath $profilePath `
            -Force

        Assert-MowEqual `
            -Actual ([Convert]::ToBase64String(
                [System.IO.File]::ReadAllBytes($installPath)
            )) `
            -Expected ([Convert]::ToBase64String(
                [System.IO.File]::ReadAllBytes($goodArtifactPath)
            )) `
            -Message 'Successful setup did not install the downloaded artifact.'

        $profileText = [System.IO.File]::ReadAllText($profilePath, $utf8)

        Assert-MowTrue `
            -Condition ($profileText.Contains('# >>> MowPSKit >>>')) `
            -Message 'Successful setup did not add the profile block.'

        Assert-MowTrue `
            -Condition ($profileText.Contains(
                "if (Test-Path -LiteralPath '$expectedInstallLiteral') { " +
                "& '$expectedInstallLiteral' }"
            )) `
            -Message 'Successful setup did not refresh the managed Profile install path.'

        Assert-MowFalse `
            -Condition ($profileText.Contains($obsoleteInstallLiteral)) `
            -Message 'Successful setup retained an obsolete managed Profile install path.'

        Assert-MowFalse `
            -Condition ([System.IO.File]::Exists(
                (Join-Path $installDir 'setup.ps1')
            )) `
            -Message 'Successful setup copied setup.ps1 into the installation directory.'

        $installedMetadata = Get-Content `
            -LiteralPath $metadataPath `
            -Raw `
            -Encoding UTF8 |
                ConvertFrom-Json

        Assert-MowEqual `
            -Actual $installedMetadata.ArtifactUrl `
            -Expected 'https://example.invalid/MowPSKit.ps1' `
            -Message 'Successful setup wrote incorrect installation metadata.'

        Assert-MowEqual `
            -Actual $installedMetadata.Version `
            -Expected '2.0.0' `
            -Message 'Successful setup wrote incorrect version metadata.'

        Assert-MowFalse `
            -Condition (
                $installedMetadata.PSObject.Properties.Name -contains
                'SetupUrl'
            ) `
            -Message 'Installation metadata retained the obsolete SetupUrl field.'

        $installedVersion = & 'mow.ver'

        Assert-MowEqual `
            -Actual $installedVersion.Mode `
            -Expected 'Installed' `
            -Message 'Successful setup did not load Installed runtime mode.'

        Assert-MowEqual `
            -Actual $installedVersion.BuildMode `
            -Expected 'Compiled' `
            -Message 'Successful setup did not load Compiled build mode.'

        Assert-MowEqual `
            -Actual $installedVersion.Version `
            -Expected '2.0.0' `
            -Message 'Successful setup did not load the embedded product version.'

        $installedBytes = [System.IO.File]::ReadAllBytes($installPath)
        $sameVersionOutput = @(
            & $setupPath `
                -Action Update `
                -ArtifactUrl 'https://example.invalid/MowPSKit.ps1' `
                -InstallDir $installDir `
                -ProfilePath $profilePath `
                -Force `
                6>&1
        ) -join [Environment]::NewLine

        Assert-MowTrue `
            -Condition ($sameVersionOutput -match 'already up to date') `
            -Message 'Setup did not report an equal installed version as current.'

        [System.IO.File]::WriteAllText(
            $lowerArtifactPath,
            (
                "Microsoft.PowerShell.Utility\Set-Variable " +
                "-Name MowPSKitVersion -Value '1.5.0' " +
                "-Option Constant -Scope Local`r`n"
            ),
            $utf8
        )

        $global:MowSetupTestArtifactPath = $lowerArtifactPath
        $lowerVersionOutput = @(
            & $setupPath `
                -Action Update `
                -ArtifactUrl 'https://example.invalid/MowPSKit.ps1' `
                -InstallDir $installDir `
                -ProfilePath $profilePath `
                -Force `
                6>&1
        ) -join [Environment]::NewLine

        Assert-MowTrue `
            -Condition ($lowerVersionOutput -match 'Downgrade skipped') `
            -Message 'Setup did not reject a lower remote version.'

        Assert-MowEqual `
            -Actual ([Convert]::ToBase64String(
                [System.IO.File]::ReadAllBytes($installPath)
            )) `
            -Expected ([Convert]::ToBase64String($installedBytes)) `
            -Message 'Equal or lower remote version changed the installed artifact.'

        $downloadsBeforeUninstall = $global:MowSetupTestDownloadCount

        & 'mow.uninstall'

        Assert-MowEqual `
            -Actual $global:MowSetupTestDownloadCount `
            -Expected $downloadsBeforeUninstall `
            -Message 'Runtime uninstall downloaded a remote file.'

        Assert-MowFalse `
            -Condition ([System.IO.Directory]::Exists($installDir)) `
            -Message 'Uninstall left the installation directory behind.'

        $profileAfterUninstall = [System.IO.File]::ReadAllText(
            $profilePath,
            $utf8
        )

        Assert-MowEqual `
            -Actual $profileAfterUninstall `
            -Expected "# existing profile`r`n" `
            -Message 'Uninstall did not preserve the original profile content.'
    }
    finally {
        Remove-Item `
            -LiteralPath 'Function:\global:Invoke-RestMethod' `
            -Force `
            -ErrorAction SilentlyContinue

        if ($oldInvokeRestMethod) {
            Set-Item `
                -LiteralPath 'Function:\global:Invoke-RestMethod' `
                -Value $oldInvokeRestMethod.ScriptBlock
        }

        foreach ($variableName in @(
            'MowSetupTestArtifactPath'
            'MowSetupTestDownloadCount'
        )) {
            Remove-Variable `
                -Name $variableName `
                -Scope Global `
                -ErrorAction SilentlyContinue
        }

        Reset-MowTestRuntime
        Remove-MowLoaderFixture -SourceRoot $runtimeRoot
        Remove-MowTestRoot -Path $root
    }
}


# ============================================================
# 11. Source normalization
# ============================================================

Invoke-MowTest 'normalize-source enforces UTF-8 no BOM and CRLF without touching excluded files' {
    $root = New-MowTestRoot -Name 'normalize'

    try {
        foreach ($directory in @(
            'configs'
            'scripts'
            'src'
            'src\ignored'
        )) {
            [void][System.IO.Directory]::CreateDirectory(
                (Join-Path $root $directory)
            )
        }

        Copy-Item `
            -LiteralPath $normalizePath `
            -Destination (Join-Path $root 'scripts\normalize-source.ps1')

        $normalizeConfig = @'
@{
    General = @{
        Name = 'MowPSKit'
        Prefix = ''
        CommandSeparator = ''
    }

    Build = @{
        SourcePath = 'src'
        OutputPath = 'dist\MowPSKit.ps1'
        ArtifactUrl = ''
        SetupUrl = ''
    }

    Normalize = @{
        Path = 'src'
        Encoding = 'UTF8NoBOM'
        LineEnding = 'CRLF'

        Extensions = @(
            '.ps1'
            '.txt'
        )

        ExcludeDirs = @(
            'ignored'
        )
    }
}
'@

        $null = Write-MowTestFile `
            -Root $root `
            -RelativePath 'configs\mowpskit.psd1' `
            -Content $normalizeConfig

        $samplePath = Join-Path $root 'src\sample.ps1'
        $ignoredPath = Join-Path $root 'src\ignored\skip.ps1'
        $binaryPath = Join-Path $root 'src\untouched.bin'

        $utf8Bom = New-Object System.Text.UTF8Encoding($true)

        [System.IO.File]::WriteAllText(
            $samplePath,
            "one  `ntwo`t`rthree`r`nfour",
            $utf8Bom
        )

        [System.IO.File]::WriteAllText(
            $ignoredPath,
            "ignored`nfile",
            $utf8Bom
        )

        [System.IO.File]::WriteAllBytes(
            $binaryPath,
            [byte[]]@(0xEF, 0xBB, 0xBF, 0x00, 0xFF)
        )

        $ignoredBefore = [Convert]::ToBase64String(
            [System.IO.File]::ReadAllBytes($ignoredPath)
        )

        $binaryBefore = [Convert]::ToBase64String(
            [System.IO.File]::ReadAllBytes($binaryPath)
        )

        & (Join-Path $root 'scripts\normalize-source.ps1')

        $sampleBytes = [System.IO.File]::ReadAllBytes($samplePath)

        $sampleHasBom = (
            $sampleBytes.Length -ge 3 -and
            $sampleBytes[0] -eq 0xEF -and
            $sampleBytes[1] -eq 0xBB -and
            $sampleBytes[2] -eq 0xBF
        )

        Assert-MowFalse `
            -Condition $sampleHasBom `
            -Message 'normalize-source did not remove the UTF-8 BOM.'

        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $sampleText = $strictUtf8.GetString($sampleBytes)

        Assert-MowFalse `
            -Condition ($sampleText -match "(?<!`r)`n") `
            -Message 'normalize-source left a lone LF.'

        Assert-MowFalse `
            -Condition ($sampleText -match "`r(?!`n)") `
            -Message 'normalize-source left a lone CR.'

        Assert-MowEqual `
            -Actual $sampleText `
            -Expected "one`r`ntwo`r`nthree`r`nfour`r`n" `
            -Message 'normalize-source did not trim whitespace or add exactly one final newline.'

        Assert-MowEqual `
            -Actual ([Convert]::ToBase64String(
                [System.IO.File]::ReadAllBytes($ignoredPath)
            )) `
            -Expected $ignoredBefore `
            -Message 'normalize-source modified a file inside an excluded directory.'

        Assert-MowEqual `
            -Actual ([Convert]::ToBase64String(
                [System.IO.File]::ReadAllBytes($binaryPath)
            )) `
            -Expected $binaryBefore `
            -Message 'normalize-source modified a file with an unlisted extension.'
    }
    finally {
        Remove-MowTestRoot -Path $root
    }
}


# ============================================================
# Summary
# ============================================================

Write-Host
Write-Host 'MowPSKit Framework Test Summary' -ForegroundColor Cyan
Write-Host '--------------------------------'

$passed = @(
    $script:TestResults |
        Where-Object { $_.Passed }
).Count

$failed = @(
    $script:TestResults |
        Where-Object { -not $_.Passed }
).Count

foreach ($result in $script:TestResults) {
    $status = if ($result.Passed) {
        'PASS'
    }
    else {
        'FAIL'
    }

    Write-Host ('{0,-4}  {1}' -f $status, $result.Name)
}

Write-Host
Write-Host ("Passed : {0}" -f $passed)
Write-Host ("Failed : {0}" -f $failed)
Write-Host ("Total  : {0}" -f $script:TestResults.Count)

if ($failed -gt 0) {
    throw "$failed MowPSKit framework test(s) failed."
}

Write-Host
Write-Host 'ALL TESTS PASSED.' -ForegroundColor Green
