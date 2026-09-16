[CmdletBinding(DefaultParameterSetName = 'Source')]
param(
    [AllowEmptyString()]
    [string]$Prefix = '',

    [Alias('Separator')]
    [AllowEmptyString()]
    [string]$CommandSeparator = '',

    [Parameter(ParameterSetName = 'Source')]
    [string]$SourceRoot = $PSScriptRoot,

    [Parameter(Mandatory, ParameterSetName = 'Bundle')]
    [System.Collections.IDictionary]$Bundle,

    [string]$EntryPointPath = '',

    [Parameter(ParameterSetName = 'Bundle')]
    [AllowEmptyString()]
    [string]$ArtifactUrl = ''
)

$loaderVersion = '2.2.0'
$categoryOrder = @('core', 'internal', 'functions')
$utf8 = New-Object System.Text.UTF8Encoding($false, $true)

if ([string]::IsNullOrWhiteSpace($Prefix)) {
    $Prefix = ''
}
elseif ($Prefix -notmatch '^[A-Za-z0-9_]+$') {
    throw "Invalid MowPSKit prefix '$Prefix'. Use only letters, numbers, or underscores."
}

if ($CommandSeparator -match '[\r\n]') {
    throw 'MowPSKit CommandSeparator cannot contain a line break.'
}

function Get-MowRelativePath {
    param(
        [Parameter(Mandatory)]
        [string]$BasePath,

        [Parameter(Mandatory)]
        [string]$FullPath
    )

    return $FullPath.Substring($BasePath.Length).TrimStart('\', '/')
}

function Get-MowSourceText {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        return [System.IO.File]::ReadAllText($Path, $utf8)
    }
    catch {
        throw "Failed to read '$Path' as UTF-8: $($_.Exception.Message)"
    }
}


function Test-MowHttpUrl {
    param(
        [AllowEmptyString()]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return
    }

    $uri = $null

    if (
        -not [System.Uri]::TryCreate(
            $Url,
            [System.UriKind]::Absolute,
            [ref]$uri
        ) -or
        $uri.Scheme -notin @('http', 'https')
    ) {
        throw "$Label must be empty or an absolute HTTP/HTTPS URL."
    }
}

function Get-MowReleaseVersion {
    param(
        [AllowNull()]
        [string]$BuildVersion
    )

    if ([string]::IsNullOrWhiteSpace($BuildVersion)) {
        return 'unknown'
    }

    return @($BuildVersion -split '\+', 2)[0]
}


function Get-MowSourceSettings {
    param(
        [Parameter(Mandatory)]
        [string]$ResolvedSourceRoot
    )

    $projectRoot = Split-Path $ResolvedSourceRoot -Parent
    $configPath = Join-Path $projectRoot 'configs\mowpskit.psd1'
    $versionPath = Join-Path $projectRoot 'version.txt'

    if (-not [System.IO.File]::Exists($versionPath)) {
        throw "MowPSKit version file not found: $versionPath"
    }

    $version = (Get-MowSourceText -Path $versionPath).Trim()

    if (
        [string]::IsNullOrWhiteSpace($version) -or
        $version -match '[\r\n]' -or
        $version -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$'
    ) {
        throw "Invalid MowPSKit version.txt value '$version'."
    }

    if (-not [System.IO.File]::Exists($configPath)) {
        return [pscustomobject]@{
            Version = $version
            SetupUrl = ''
        }
    }

    try {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
    }
    catch {
        throw "Failed to read MowPSKit config '$configPath': $($_.Exception.Message)"
    }

    $setupUrl = ''

    if (
        $config.ContainsKey('Build') -and
        $config.Build -is [System.Collections.IDictionary] -and
        $config.Build.ContainsKey('SetupUrl')
    ) {
        $setupUrl = [string]$config.Build.SetupUrl
    }

    Test-MowHttpUrl `
        -Url $setupUrl `
        -Label 'Build.SetupUrl'

    return [pscustomobject]@{
        Version = $version
        SetupUrl = $setupUrl
    }
}

function New-MowUnitDefinition {
    param(
        [Parameter(Mandatory)]
        [string]$Category,

        [Parameter(Mandatory)]
        [string]$RelativePath,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )

    $normalizedPath = $RelativePath.Replace('\', '/')

    if (
        [System.IO.Path]::IsPathRooted($normalizedPath) -or
        $normalizedPath -match '(^|/)\.\.(/|$)' -or
        -not $normalizedPath.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        throw "Invalid MowPSKit Source Unit path '$RelativePath'."
    }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $Content,
        [ref]$tokens,
        [ref]$parseErrors
    )

    if ($parseErrors.Count -gt 0) {
        $details = @(
            foreach ($parseError in $parseErrors) {
                '{0}:{1}:{2}: {3}' -f (
                    $normalizedPath,
                    $parseError.Extent.StartLineNumber,
                    $parseError.Extent.StartColumnNumber,
                    $parseError.Message
                )
            }
        ) -join [Environment]::NewLine

        throw "MowPSKit syntax validation failed:$([Environment]::NewLine)$details"
    }

    $functionNames = @(
        foreach ($statement in $ast.EndBlock.Statements) {
            if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                $statement.Name
            }
        }
    )

    $seenNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($functionName in $functionNames) {
        if ($functionName.Contains(':')) {
            throw "Scope-qualified function '$functionName' is not allowed in '$normalizedPath'."
        }

        if (-not $seenNames.Add($functionName)) {
            throw "MowPSKit Source Unit '$normalizedPath' defines '$functionName' more than once."
        }
    }

    return [pscustomobject]@{
        Category = $Category.ToLowerInvariant()
        RelativePath = $normalizedPath
        Content = $Content
        FunctionNames = $functionNames
    }
}

function Get-MowLocalInput {
    param(
        [Parameter(Mandatory)]
        [string]$RootPath
    )

    if (-not [System.IO.Directory]::Exists($RootPath)) {
        throw "MowPSKit source root was not found: $RootPath"
    }

    $resolvedRoot = [System.IO.Path]::GetFullPath($RootPath).TrimEnd('\', '/')
    $units = [System.Collections.Generic.List[object]]::new()

    foreach ($category in $categoryOrder) {
        $categoryRoot = Join-Path $resolvedRoot $category

        if (-not [System.IO.Directory]::Exists($categoryRoot)) {
            continue
        }

        $paths = @(
            Get-ChildItem -LiteralPath $categoryRoot -File -Filter '*.ps1' -Recurse |
                ForEach-Object {
                    Get-MowRelativePath -BasePath $categoryRoot -FullPath $_.FullName
                }
        )

        [System.Array]::Sort(
            [string[]]$paths,
            [System.StringComparer]::OrdinalIgnoreCase
        )

        foreach ($relativePath in $paths) {
            $fullPath = Join-Path $categoryRoot $relativePath
            $units.Add(
                (New-MowUnitDefinition `
                    -Category $category `
                    -RelativePath $relativePath `
                    -Content (Get-MowSourceText -Path $fullPath))
            )
        }
    }

    $resources = [ordered]@{}
    $resourcesRoot = Join-Path $resolvedRoot 'resources'

    if ([System.IO.Directory]::Exists($resourcesRoot)) {
        $resourcePaths = @(
            Get-ChildItem -LiteralPath $resourcesRoot -File -Recurse |
                ForEach-Object {
                    Get-MowRelativePath -BasePath $resourcesRoot -FullPath $_.FullName
                }
        )

        [System.Array]::Sort(
            [string[]]$resourcePaths,
            [System.StringComparer]::OrdinalIgnoreCase
        )

        foreach ($relativePath in $resourcePaths) {
            $normalizedPath = $relativePath.Replace('\', '/')
            $resources[$normalizedPath] = [System.IO.File]::ReadAllBytes(
                (Join-Path $resourcesRoot $relativePath)
            )
        }
    }

    $sourceSettings = Get-MowSourceSettings `
        -ResolvedSourceRoot $resolvedRoot

    return [pscustomobject]@{
        BuildMode = 'Source'
        Version = $sourceSettings.Version
        BuildVersion = $sourceSettings.Version
        Units = $units.ToArray()
        Resources = $resources
        SourceRoot = $resolvedRoot
        LoaderPath = Join-Path $resolvedRoot 'loader.ps1'
        EntryPointPath = $EntryPointPath
        ArtifactUrl = ''
        SetupUrl = $sourceSettings.SetupUrl
    }
}

function Get-MowBundleInput {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$BundleData
    )

    if (-not $BundleData.Contains('Units')) {
        throw "The MowPSKit bundle does not contain a 'Units' collection."
    }

    $units = [System.Collections.Generic.List[object]]::new()

    foreach ($unit in @($BundleData['Units'])) {
        if ($null -eq $unit) {
            throw 'The MowPSKit bundle contains a null Source Unit.'
        }

        $category = [string]$unit.Category

        if ($category -notin $categoryOrder) {
            throw "Invalid MowPSKit Source Unit category '$category'."
        }

        $units.Add(
            (New-MowUnitDefinition `
                -Category $category `
                -RelativePath ([string]$unit.RelativePath) `
                -Content ([string]$unit.Content))
        )
    }

    $resources = [ordered]@{}

    if ($BundleData.Contains('Resources')) {
        $resourceInput = $BundleData['Resources']

        if ($null -ne $resourceInput) {
            foreach ($key in $resourceInput.Keys) {
                $normalizedPath = ([string]$key).Replace('\', '/')

                if (
                    [System.IO.Path]::IsPathRooted($normalizedPath) -or
                    $normalizedPath -match '(^|/)\.\.(/|$)'
                ) {
                    throw "Invalid MowPSKit resource path '$key'."
                }

                $resources[$normalizedPath] = [byte[]]$resourceInput[$key]
            }
        }
    }

    $version = 'unknown'
    $buildVersion = 'unknown'
    $hasBuildVersion = $false

    if ($BundleData.Contains('BuildVersion')) {
        $candidateBuildVersion = [string]$BundleData['BuildVersion']

        if (-not [string]::IsNullOrWhiteSpace($candidateBuildVersion)) {
            $buildVersion = $candidateBuildVersion
            $hasBuildVersion = $true
        }
    }

    if ($BundleData.Contains('Version')) {
        $candidateVersion = [string]$BundleData['Version']

        if (-not [string]::IsNullOrWhiteSpace($candidateVersion)) {
            if ($hasBuildVersion) {
                $version = $candidateVersion
            }
            else {
                # Backward compatibility: older bundles stored the build
                # version in Bundle.Version.
                $buildVersion = $candidateVersion
                $version = Get-MowReleaseVersion `
                    -BuildVersion $candidateVersion
            }
        }
    }

    if ($version -eq 'unknown' -and $hasBuildVersion) {
        $version = Get-MowReleaseVersion `
            -BuildVersion $buildVersion
    }

    $setupUrl = ''

    if ($BundleData.Contains('SetupUrl')) {
        $setupUrl = [string]$BundleData['SetupUrl']

        Test-MowHttpUrl `
            -Url $setupUrl `
            -Label 'Bundle.SetupUrl'
    }

    return [pscustomobject]@{
        BuildMode = 'Compiled'
        Version = $version
        BuildVersion = $buildVersion
        Units = $units.ToArray()
        Resources = $resources
        SourceRoot = ''
        LoaderPath = ''
        EntryPointPath = $EntryPointPath
        ArtifactUrl = $ArtifactUrl
        SetupUrl = $setupUrl
    }
}

function Get-MowRuntimeMode {
    param(
        [Parameter(Mandatory)]
        [string]$BuildMode,

        [AllowEmptyString()]
        [string]$RuntimeEntryPointPath
    )

    if (
        $BuildMode -ne 'Compiled' -or
        [string]::IsNullOrWhiteSpace($RuntimeEntryPointPath)
    ) {
        return 'Ephemeral'
    }

    try {
        $resolvedEntryPoint = [System.IO.Path]::GetFullPath(
            $RuntimeEntryPointPath
        )
    }
    catch {
        return 'Ephemeral'
    }

    $installDirectory = Split-Path $resolvedEntryPoint -Parent
    $metadataPath = Join-Path $installDirectory 'install.json'

    if ([System.IO.File]::Exists($metadataPath)) {
        try {
            $metadata = Get-Content `
                -LiteralPath $metadataPath `
                -Raw `
                -ErrorAction Stop |
                ConvertFrom-Json `
                    -ErrorAction Stop

            if (
                [string]$metadata.Product -eq 'MowPSKit' -and
                -not [string]::IsNullOrWhiteSpace(
                    [string]$metadata.InstallPath
                ) -and
                $resolvedEntryPoint.Equals(
                    [System.IO.Path]::GetFullPath(
                        [string]$metadata.InstallPath
                    ),
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            ) {
                return 'Installed'
            }
        }
        catch {
            # A broken metadata file must not turn an arbitrary script into an installation.
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $defaultInstallPath = [System.IO.Path]::GetFullPath(
            (Join-Path $env:LOCALAPPDATA 'MowPSKit\MowPSKit.ps1')
        )

        if (
            $resolvedEntryPoint.Equals(
                $defaultInstallPath,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            return 'Installed'
        }
    }

    return 'Ephemeral'
}

if ($PSCmdlet.ParameterSetName -eq 'Source') {
    $runtimeInput = Get-MowLocalInput -RootPath $SourceRoot
}
else {
    $runtimeInput = Get-MowBundleInput -BundleData $Bundle
}

$runtimeMode = Get-MowRuntimeMode `
    -BuildMode $runtimeInput.BuildMode `
    -RuntimeEntryPointPath $runtimeInput.EntryPointPath

$oldModules = @(
    Microsoft.PowerShell.Core\Get-Module -Name 'MowPSKit' -All
)

$reloadAction = {
    param(
        [string]$RuntimeMode,
        [string]$BuildMode,
        [string]$ReloadPrefix,
        [string]$ReloadSeparator,
        [string]$ReloadSourceRoot,
        [string]$ReloadLoaderPath,
        [string]$ReloadEntryPointPath,
        [string]$ReloadArtifactUrl
    )

    if ($RuntimeMode -eq 'Installed') {
        if (
            [string]::IsNullOrWhiteSpace($ReloadEntryPointPath) -or
            -not [System.IO.File]::Exists($ReloadEntryPointPath)
        ) {
            throw 'The installed MowPSKit runtime file is missing.'
        }

        & $ReloadEntryPointPath `
            -Prefix $ReloadPrefix `
            -CommandSeparator $ReloadSeparator

        Write-Host "MowPSKit reloaded from installed file: $ReloadEntryPointPath"
        return
    }

    if ($BuildMode -eq 'Source') {
        & $ReloadLoaderPath `
            -Prefix $ReloadPrefix `
            -CommandSeparator $ReloadSeparator `
            -SourceRoot $ReloadSourceRoot `
            -EntryPointPath $ReloadEntryPointPath

        Write-Host "MowPSKit reloaded from source loader: $ReloadLoaderPath"
        return
    }

    if ([string]::IsNullOrWhiteSpace($ReloadArtifactUrl)) {
        throw 'This compiled artifact has no ArtifactUrl. Set Build.ArtifactUrl in configs\mowpskit.psd1 and rebuild.'
    }

    $urlSeparator = '?'

    if ($ReloadArtifactUrl.Contains('?')) {
        $urlSeparator = '&'
    }

    $requestUrl = '{0}{1}_={2}' -f (
        $ReloadArtifactUrl,
        $urlSeparator,
        (Get-Date -Format 'yyyyMMddHHmmssfff')
    )
    $artifactSource = Invoke-RestMethod -Uri $requestUrl -ErrorAction Stop
    $artifactScript = [scriptblock]::Create([string]$artifactSource)

    & $artifactScript `
        -Prefix $ReloadPrefix `
        -CommandSeparator $ReloadSeparator `
        -ArtifactUrl $ReloadArtifactUrl `
        -EntryPointPath ''

    Write-Host "MowPSKit reloaded from remote artifact: $ReloadArtifactUrl"
}

$setupAction = {
    param(
        [string]$SetupUrl,
        [string]$Action,
        [AllowEmptyString()]
        [string]$InstalledDirectory
    )

    $urlSeparator = '?'

    if ($SetupUrl.Contains('?')) {
        $urlSeparator = '&'
    }

    $requestUrl = '{0}{1}_={2}' -f (
        $SetupUrl,
        $urlSeparator,
        (Get-Date -Format 'yyyyMMddHHmmssfff')
    )
    $setupSource = Invoke-RestMethod `
        -Uri $requestUrl `
        -ErrorAction Stop
    $setupScript = [scriptblock]::Create([string]$setupSource)
    $setupArguments = @{
        Action = $Action
    }

    if (-not [string]::IsNullOrWhiteSpace($InstalledDirectory)) {
        $setupArguments.InstallDir = $InstalledDirectory
        $metadataPath = Join-Path $InstalledDirectory 'install.json'

        if ([System.IO.File]::Exists($metadataPath)) {
            try {
                $metadata = Get-Content `
                    -LiteralPath $metadataPath `
                    -Raw `
                    -ErrorAction Stop |
                    ConvertFrom-Json `
                        -ErrorAction Stop
                $profileCandidates = @($metadata.ProfilePaths) +
                    @($metadata.ProfilePath)
                $profilePath = @(
                    $profileCandidates |
                        Where-Object {
                            -not [string]::IsNullOrWhiteSpace([string]$_)
                        } |
                        Select-Object -First 1
                )

                if ($profilePath.Count -eq 1) {
                    $setupArguments.ProfilePath = [string]$profilePath[0]
                }
            }
            catch {
                # Root setup will retain its default ProfilePath if legacy
                # installation metadata cannot be read.
            }
        }
    }

    & $setupScript @setupArguments
}

$localUninstallAction = {
    param(
        [AllowEmptyString()]
        [string]$EntryPointPath,

        [AllowEmptyString()]
        [string]$DefaultProfilePath,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSModuleInfo]$RuntimeModule
    )

    if ([string]::IsNullOrWhiteSpace($EntryPointPath)) {
        throw 'The installed MowPSKit runtime path is unavailable.'
    }

    $resolvedEntryPoint = [System.IO.Path]::GetFullPath($EntryPointPath)
    $installDirectory = [System.IO.Path]::GetFullPath(
        (Split-Path $resolvedEntryPoint -Parent)
    )
    $directoryRoot = [System.IO.Path]::GetPathRoot($installDirectory)

    if (
        [string]::IsNullOrWhiteSpace($installDirectory) -or
        $installDirectory.TrimEnd('\', '/').Equals(
            $directoryRoot.TrimEnd('\', '/'),
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "Refusing to remove unsafe installation directory '$installDirectory'."
    }

    $metadataPath = Join-Path $installDirectory 'install.json'
    $profilePaths = [System.Collections.Generic.List[string]]::new()
    $legacySetupPath = ''

    if ([System.IO.File]::Exists($metadataPath)) {
        try {
            $metadata = Get-Content `
                -LiteralPath $metadataPath `
                -Raw `
                -ErrorAction Stop |
                ConvertFrom-Json `
                    -ErrorAction Stop

            foreach ($profilePath in @($metadata.ProfilePaths)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$profilePath)) {
                    $profilePaths.Add([string]$profilePath)
                }
            }

            if (
                $profilePaths.Count -eq 0 -and
                -not [string]::IsNullOrWhiteSpace(
                    [string]$metadata.ProfilePath
                )
            ) {
                $profilePaths.Add([string]$metadata.ProfilePath)
            }

            if (
                -not [string]::IsNullOrWhiteSpace(
                    [string]$metadata.SetupPath
                )
            ) {
                try {
                    $setupCandidate = [System.IO.Path]::GetFullPath(
                        [string]$metadata.SetupPath
                    )
                    $setupParent = [System.IO.Path]::GetFullPath(
                        (Split-Path $setupCandidate -Parent)
                    )

                    if (
                        $setupParent.Equals(
                            $installDirectory,
                            [System.StringComparison]::OrdinalIgnoreCase
                        ) -and
                        [System.IO.Path]::GetFileName($setupCandidate) -eq
                            'setup.ps1'
                    ) {
                        $legacySetupPath = $setupCandidate
                    }
                }
                catch {
                    # Ignore an unsafe or malformed legacy setup path.
                }
            }
        }
        catch {
            Write-Warning 'Could not read installation metadata. Using the current PowerShell profile.'
        }
    }

    if (
        $profilePaths.Count -eq 0 -and
        -not [string]::IsNullOrWhiteSpace($DefaultProfilePath)
    ) {
        $profilePaths.Add($DefaultProfilePath)
    }

    foreach ($profilePath in @($profilePaths | Select-Object -Unique)) {
        if (-not [System.IO.File]::Exists($profilePath)) {
            continue
        }

        $bytes = [System.IO.File]::ReadAllBytes($profilePath)
        $encoding = $null

        if (
            $bytes.Length -ge 3 -and
            $bytes[0] -eq 0xEF -and
            $bytes[1] -eq 0xBB -and
            $bytes[2] -eq 0xBF
        ) {
            $encoding = New-Object System.Text.UTF8Encoding($true)
        }
        elseif (
            $bytes.Length -ge 2 -and
            $bytes[0] -eq 0xFF -and
            $bytes[1] -eq 0xFE
        ) {
            $encoding = New-Object System.Text.UnicodeEncoding($false, $true)
        }
        elseif (
            $bytes.Length -ge 2 -and
            $bytes[0] -eq 0xFE -and
            $bytes[1] -eq 0xFF
        ) {
            $encoding = New-Object System.Text.UnicodeEncoding($true, $true)
        }
        else {
            try {
                $encoding = New-Object System.Text.UTF8Encoding($false, $true)
                $null = $encoding.GetString($bytes)
                $encoding = New-Object System.Text.UTF8Encoding($false)
            }
            catch {
                $encoding = [System.Text.Encoding]::Default
            }
        }

        $profileText = $encoding.GetString($bytes)

        if (
            $profileText.Length -gt 0 -and
            $profileText[0] -eq [char]0xFEFF
        ) {
            $profileText = $profileText.Substring(1)
        }

        $profilePattern = '(?ms)^[ \t]*# >>> MowPSKit >>>[ \t]*\r?\n.*?^[ \t]*# <<< MowPSKit <<<[ \t]*(?:\r?\n)?'
        $updatedProfile = [regex]::Replace(
            $profileText,
            $profilePattern,
            ''
        )

        if ($updatedProfile -ne $profileText) {
            [System.IO.File]::WriteAllText(
                $profilePath,
                $updatedProfile,
                $encoding
            )
        }
    }

    foreach ($ownedPath in @(
        $resolvedEntryPoint
        $metadataPath
        $legacySetupPath
    )) {
        if (
            [string]::IsNullOrWhiteSpace($ownedPath) -or
            -not [System.IO.File]::Exists($ownedPath)
        ) {
            continue
        }

        Remove-Item `
            -LiteralPath $ownedPath `
            -Force `
            -ErrorAction Stop
    }

    if (
        [System.IO.Directory]::Exists($installDirectory) -and
        [System.IO.Directory]::GetFileSystemEntries($installDirectory).Count -eq 0
    ) {
        [System.IO.Directory]::Delete($installDirectory)
    }

    Write-Host 'MowPSKit uninstalled locally.'

    Microsoft.PowerShell.Core\Remove-Module `
        -ModuleInfo $RuntimeModule `
        -Force `
        -ErrorAction SilentlyContinue
}

$unloadAction = {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.PSModuleInfo]$RuntimeModule
    )

    Microsoft.PowerShell.Core\Remove-Module `
        -ModuleInfo $RuntimeModule `
        -Force `
        -ErrorAction SilentlyContinue
}

$runtimeContext = [pscustomobject]@{
    Prefix = $Prefix
    CommandSeparator = $CommandSeparator
    LoaderVersion = $loaderVersion
    Mode = $runtimeMode
    BuildMode = $runtimeInput.BuildMode
    Version = $runtimeInput.Version
    BuildVersion = $runtimeInput.BuildVersion
    Units = $runtimeInput.Units
    Resources = $runtimeInput.Resources
    SourceRoot = $runtimeInput.SourceRoot
    LoaderPath = $runtimeInput.LoaderPath
    EntryPointPath = $runtimeInput.EntryPointPath
    ArtifactUrl = $runtimeInput.ArtifactUrl
    SetupUrl = $runtimeInput.SetupUrl
    DefaultProfilePath = [string]$PROFILE.CurrentUserAllHosts
    ReloadAction = $reloadAction
    SetupAction = $setupAction
    LocalUninstallAction = $localUninstallAction
    UnloadAction = $unloadAction
}

$newModule = New-Module `
    -Name 'MowPSKit' `
    -Function @() `
    -ArgumentList $runtimeContext `
    -ScriptBlock {
    param($Context)

    function Resolve-MowMetadata {
        param(
            [AllowNull()]
            [object]$Value,

            [Parameter(Mandatory)]
            [string[]]$DefinedNames,

            [Parameter(Mandatory)]
            [string]$MetadataName,

            [Parameter(Mandatory)]
            [string]$SourcePath
        )

        if ($null -eq $Value) {
            return
        }

        $items = @($Value)

        if ($items.Count -eq 0) {
            return
        }

        if (
            $items.Count -eq 1 -and
            $items[0] -is [string] -and
            ([string]$items[0]).Equals('all', [System.StringComparison]::OrdinalIgnoreCase)
        ) {
            $DefinedNames
            return
        }

        $definedLookup = [System.Collections.Generic.Dictionary[string, string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )

        foreach ($definedName in $DefinedNames) {
            $definedLookup[$definedName] = $definedName
        }

        $seen = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )

        foreach ($item in $items) {
            if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$item)) {
                throw "Metadata '$MetadataName' in '$SourcePath' must contain only function names or 'all'."
            }

            $name = [string]$item

            if ($name.Equals('all', [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Metadata '$MetadataName' in '$SourcePath' cannot combine 'all' with other names."
            }

            if (-not $definedLookup.ContainsKey($name)) {
                throw "Function '$name' listed in '$MetadataName' was not defined by '$SourcePath'."
            }

            if (-not $seen.Add($name)) {
                throw "Metadata '$MetadataName' in '$SourcePath' contains duplicate function '$name'."
            }

            $definedLookup[$name]
        }
    }

    function Get-MowNamespace {
        param(
            [Parameter(Mandatory)]
            [string]$RelativePath
        )

        $withoutExtension = $RelativePath.Substring(0, $RelativePath.Length - 4)
        return $withoutExtension.Replace('\', '.').Replace('/', '.')
    }

    function Set-MowBoundFunction {
        param(
            [Parameter(Mandatory)]
            [System.Management.Automation.PSModuleInfo]$DestinationModule,

            [Parameter(Mandatory)]
            [string]$Name,

            [Parameter(Mandatory)]
            [scriptblock]$FunctionScriptBlock
        )

        $setter = $DestinationModule.NewBoundScriptBlock({
            param($FunctionName, $BoundScriptBlock)

            Microsoft.PowerShell.Management\Set-Item `
                -LiteralPath ('Function:script:{0}' -f $FunctionName) `
                -Value $BoundScriptBlock `
                -Force
        })

        & $setter $Name $FunctionScriptBlock
    }

    $script:MowPrefix = [string]$Context.Prefix
    $script:MowCommandSeparator = [string]$Context.CommandSeparator
    $script:MowLoaderVersion = [string]$Context.LoaderVersion
    $script:MowMode = [string]$Context.Mode
    $script:MowBuildMode = [string]$Context.BuildMode
    Microsoft.PowerShell.Utility\Set-Variable `
        -Name MowVersion `
        -Value ([string]$Context.Version) `
        -Option Constant `
        -Scope Script
    $script:MowBuildVersion = [string]$Context.BuildVersion
    $script:MowSourceRoot = [string]$Context.SourceRoot
    $script:MowLoaderPath = [string]$Context.LoaderPath
    $script:MowEntryPointPath = [string]$Context.EntryPointPath
    $script:MowArtifactUrl = [string]$Context.ArtifactUrl
    $script:MowSetupUrl = [string]$Context.SetupUrl
    $script:MowDefaultProfilePath = [string]$Context.DefaultProfilePath
    $script:MowReloadAction = $Context.ReloadAction
    $script:MowSetupAction = $Context.SetupAction
    $script:MowLocalUninstallAction = $Context.LocalUninstallAction
    $script:MowUnloadAction = $Context.UnloadAction
    $script:MowResources = $Context.Resources
    $script:MowUnitModules = [System.Collections.Generic.List[object]]::new()
    $script:MowLoadedAt = Get-Date

    $unitRecords = [System.Collections.Generic.List[object]]::new()
    $generationId = [guid]::NewGuid().ToString('N')
    $unitIndex = 0

    foreach ($definition in $Context.Units) {
        $unitIndex++
        $unitContext = [pscustomobject]@{
            Definition = $definition
            Resources = $Context.Resources
        }

        $unitModule = New-Module `
            -Name ('MowPSKit.Unit.{0}.{1:D4}' -f $generationId, $unitIndex) `
            -Function @() `
            -ArgumentList $unitContext `
            -ScriptBlock {
                param($UnitContext)

                $MowInternal = $null
                $MowExports = $null
                $script:MowSourcePath = [string]$UnitContext.Definition.RelativePath
                $script:MowResources = $UnitContext.Resources
                $sourceScript = [scriptblock]::Create(
                    [string]$UnitContext.Definition.Content
                )
                $discardedOutput = . $sourceScript
            }

        $script:MowUnitModules.Add($unitModule)

        $inspector = $unitModule.NewBoundScriptBlock({
            param($FunctionNames)

            $blocks = [System.Collections.Generic.Dictionary[string, scriptblock]]::new(
                [System.StringComparer]::OrdinalIgnoreCase
            )

            foreach ($functionName in $FunctionNames) {
                $command = Microsoft.PowerShell.Core\Get-Command `
                    -Name $functionName `
                    -CommandType Function, Filter `
                    -ErrorAction Stop

                $blocks[$functionName] = $command.ScriptBlock
            }

            $internalVariable = Microsoft.PowerShell.Utility\Get-Variable `
                -Name 'MowInternal' `
                -Scope Script `
                -ErrorAction SilentlyContinue

            $exportsVariable = Microsoft.PowerShell.Utility\Get-Variable `
                -Name 'MowExports' `
                -Scope Script `
                -ErrorAction SilentlyContinue

            [pscustomobject]@{
                Internal = if ($null -eq $internalVariable) {
                    $null
                }
                else {
                    $internalVariable.Value
                }
                Exports = if ($null -eq $exportsVariable) {
                    $null
                }
                else {
                    $exportsVariable.Value
                }
                FunctionBlocks = $blocks
            }
        })

        $inspection = & $inspector $definition.FunctionNames
        $internalNames = @(
            Resolve-MowMetadata `
                -Value $inspection.Internal `
                -DefinedNames $definition.FunctionNames `
                -MetadataName '$MowInternal' `
                -SourcePath $definition.RelativePath
        )
        $exportNames = @(
            Resolve-MowMetadata `
                -Value $inspection.Exports `
                -DefinedNames $definition.FunctionNames `
                -MetadataName '$MowExports' `
                -SourcePath $definition.RelativePath
        )

        $definedLookup = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )

        foreach ($functionName in $definition.FunctionNames) {
            $null = $definedLookup.Add($functionName)
        }

        if ($definition.Category -eq 'core') {
            $sharedNames = @($definition.FunctionNames)
        }
        else {
            $sharedNames = $internalNames
        }

        $unitRecords.Add([pscustomobject]@{
            Definition = $definition
            Module = $unitModule
            FunctionBlocks = $inspection.FunctionBlocks
            DefinedLookup = $definedLookup
            SharedNames = $sharedNames
            ExportNames = $exportNames
        })
    }

    $sharedOwners = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($record in $unitRecords) {
        foreach ($sharedName in $record.SharedNames) {
            if ($sharedOwners.ContainsKey($sharedName)) {
                $existingPath = $sharedOwners[$sharedName].Definition.RelativePath
                throw "MowPSKit internal function collision: '$sharedName' in '$existingPath' and '$($record.Definition.RelativePath)'."
            }

            $sharedOwners[$sharedName] = $record
        }
    }

    $reservedNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $null = $reservedNames.Add('mow.help')
    $null = $reservedNames.Add('mow.ver')
    $null = $reservedNames.Add('mow.reload')
    $null = $reservedNames.Add('mow.install')
    $null = $reservedNames.Add('mow.update')
    $null = $reservedNames.Add('mow.uninstall')
    $null = $reservedNames.Add('mow.unload')

    $publicOwners = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($record in $unitRecords) {
        $namespace = Get-MowNamespace -RelativePath $record.Definition.RelativePath

        foreach ($exportName in $record.ExportNames) {
            $baseName = '{0}.{1}' -f $namespace, $exportName

            if ([string]::IsNullOrEmpty($script:MowPrefix)) {
                $publicName = $baseName
            }
            else {
                $publicName = '{0}{1}{2}' -f (
                    $script:MowPrefix,
                    $script:MowCommandSeparator,
                    $baseName
                )
            }

            if ($reservedNames.Contains($publicName)) {
                throw "MowPSKit public command '$publicName' is reserved."
            }

            if ($publicOwners.ContainsKey($publicName)) {
                $existing = $publicOwners[$publicName]
                throw "MowPSKit public command collision: '$publicName' from '$($existing.Record.Definition.RelativePath)' and '$($record.Definition.RelativePath)'."
            }

            $publicOwners[$publicName] = [pscustomobject]@{
                Record = $record
                FunctionName = $exportName
            }
        }
    }

    foreach ($consumer in $unitRecords) {
        foreach ($sharedName in $sharedOwners.Keys) {
            if ($consumer.DefinedLookup.Contains($sharedName)) {
                continue
            }

            $provider = $sharedOwners[$sharedName]
            Set-MowBoundFunction `
                -DestinationModule $consumer.Module `
                -Name $sharedName `
                -FunctionScriptBlock $provider.FunctionBlocks[$sharedName]
        }
    }

    foreach ($publicName in $publicOwners.Keys) {
        $owner = $publicOwners[$publicName]
        Microsoft.PowerShell.Management\Set-Item `
            -LiteralPath ('Function:script:{0}' -f $publicName) `
            -Value $owner.Record.FunctionBlocks[$owner.FunctionName] `
            -Force
    }

    function mow.help {
        [CmdletBinding()]
        param()

        $descriptions = @{
            'mow.help'      = 'Show available MowPSKit commands.'
            'mow.ver'       = 'Show MowPSKit version information.'
            'mow.reload'    = 'Reload MowPSKit.'
            'mow.install'   = 'Install MowPSKit for the current user.'
            'mow.update'    = 'Update the installed MowPSKit.'
            'mow.uninstall' = 'Uninstall MowPSKit for the current user.'
            'mow.unload'    = 'Unload MowPSKit.'
        }

        $commands = @(
            $publicOwners.Keys
            'mow.help'
            'mow.ver'
            'mow.reload'
            'mow.install'
            'mow.update'
            'mow.uninstall'
            'mow.unload'
        )

        $commands |
            Sort-Object |
            ForEach-Object {
                $description = $descriptions[$_]

                if (-not $description) {
                    $description = (Get-Help $_ -ErrorAction SilentlyContinue).Synopsis
                }

                [pscustomobject]@{
                    Command     = $_
                    Description = $description
                }
            }
    }

    function mow.ver {
        [CmdletBinding()]
        param()

        $prefix = if ([string]::IsNullOrEmpty($script:MowPrefix)) {
            '<none>'
        }
        else {
            $script:MowPrefix
        }

        $separator = if ([string]::IsNullOrEmpty($script:MowCommandSeparator)) {
            '<none>'
        }
        else {
            $script:MowCommandSeparator
        }

        [pscustomobject]@{
            Product       = 'MowPSKit'
            Version       = $script:MowVersion
            LoaderVersion = $script:MowLoaderVersion
            Mode          = $script:MowMode
            BuildMode     = $script:MowBuildMode
            BuildVersion  = $script:MowBuildVersion
            Prefix        = $prefix
            Separator     = $separator
            SetupUrl      = $script:MowSetupUrl
            LoadedAt      = $script:MowLoadedAt
        }
    }

    function mow.reload {
        [CmdletBinding()]
        param()

        try {
            & $script:MowReloadAction `
                $script:MowMode `
                $script:MowBuildMode `
                $script:MowPrefix `
                $script:MowCommandSeparator `
                $script:MowSourceRoot `
                $script:MowLoaderPath `
                $script:MowEntryPointPath `
                $script:MowArtifactUrl
        }
        catch {
            Write-Error "MowPSKit reload failed: $($_.Exception.Message)"
        }
    }

    function Invoke-MowSetup {
        param(
            [Parameter(Mandatory)]
            [ValidateSet('Install', 'Update')]
            [string]$Action
        )

        if ([string]::IsNullOrWhiteSpace($script:MowSetupUrl)) {
            throw 'MowPSKit SetupUrl is not configured. Set Build.SetupUrl in configs\mowpskit.psd1 and rebuild.'
        }

        try {
            $installedDirectory = ''

            if (
                $script:MowMode -eq 'Installed' -and
                -not [string]::IsNullOrWhiteSpace($script:MowEntryPointPath)
            ) {
                $installedDirectory = Split-Path `
                    ([System.IO.Path]::GetFullPath($script:MowEntryPointPath)) `
                    -Parent
            }

            & $script:MowSetupAction `
                $script:MowSetupUrl `
                $Action `
                $installedDirectory
        }
        catch {
            throw "MowPSKit setup failed: $($_.Exception.Message)"
        }
    }

    function mow.install {
        [CmdletBinding()]
        param()

        Invoke-MowSetup -Action Install
    }

    function mow.update {
        [CmdletBinding()]
        param()

        if ($script:MowMode -ne 'Installed') {
            Write-Host 'MowPSKit is not installed. Run mow.install first.'
            return
        }

        Invoke-MowSetup -Action Update
    }

    function mow.uninstall {
        [CmdletBinding()]
        param()

        if ($script:MowMode -ne 'Installed') {
            Write-Host 'MowPSKit is not installed.'
            return
        }

        try {
            $currentModule = $ExecutionContext.SessionState.Module
            & $script:MowLocalUninstallAction `
                $script:MowEntryPointPath `
                $script:MowDefaultProfilePath `
                $currentModule
        }
        catch {
            throw "MowPSKit uninstall failed: $($_.Exception.Message)"
        }
    }

    function mow.unload {
        [CmdletBinding()]
        param()

        $currentModule = $ExecutionContext.SessionState.Module
        Write-Host 'MowPSKit unloaded.'
        & $script:MowUnloadAction $currentModule
    }

    $ExecutionContext.SessionState.Module.OnRemove = {
        foreach ($unitModule in $script:MowUnitModules) {
            Microsoft.PowerShell.Core\Remove-Module `
                -ModuleInfo $unitModule `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    $publicFunctionNames = @($publicOwners.Keys)
    $publicFunctionNames += @(
        'mow.help'
        'mow.ver'
        'mow.reload'
        'mow.install'
        'mow.update'
        'mow.uninstall'
        'mow.unload'
    )

    Microsoft.PowerShell.Core\Export-ModuleMember -Function $publicFunctionNames
    }

try {
    Microsoft.PowerShell.Core\Import-Module `
        -ModuleInfo $newModule `
        -Global `
        -Force `
        -DisableNameChecking `
        -ErrorAction Stop
}
catch {
    Microsoft.PowerShell.Core\Remove-Module `
        -ModuleInfo $newModule `
        -Force `
        -ErrorAction SilentlyContinue

    throw "Failed to import the new MowPSKit runtime: $($_.Exception.Message)"
}

foreach ($oldModule in $oldModules) {
    if ($oldModule -ne $newModule) {
        Microsoft.PowerShell.Core\Remove-Module `
            -ModuleInfo $oldModule `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

$prefixDisplay = '<none>'

if (-not [string]::IsNullOrEmpty($Prefix)) {
    $prefixDisplay = "$Prefix$CommandSeparator"
}

Write-Host ('{0} MowPSKit loaded.' -f [char]0x2713) -ForegroundColor Green
Write-Host ("  Prefix     : $prefixDisplay")
Write-Host ('  Management : mow.help  mow.ver  mow.reload  mow.install  mow.update  mow.uninstall  mow.unload')
