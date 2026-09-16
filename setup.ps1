[CmdletBinding()]
param(
    [ValidateSet('Install', 'Update')]
    [string]$Action = 'Install',

    [ValidateNotNullOrEmpty()]
    [string]$ArtifactUrl = 'https://raw.githubusercontent.com/steveh8758/MowPSKit/main/dist/MowPSKit.ps1',

    [ValidateNotNullOrEmpty()]
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'MowPSKit'),

    [ValidateNotNullOrEmpty()]
    [string]$ProfilePath = $PROFILE.CurrentUserAllHosts,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$ProductName = 'MowPSKit'

$InstallPath = Join-Path $InstallDir 'MowPSKit.ps1'
$MetadataPath = Join-Path $InstallDir 'install.json'

$ProfileStart = '# >>> MowPSKit >>>'
$ProfileEnd = '# <<< MowPSKit <<<'
$escapedInstallPath = $InstallPath.Replace("'", "''")
$ProfileLoader = "if (Test-Path -LiteralPath '$escapedInstallPath') { & '$escapedInstallPath' }"


function Get-MowTextEncoding {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    if ($Bytes.Length -eq 0) {
        return [System.Text.UTF8Encoding]::new($false)
    }

    if (
        $Bytes.Length -ge 3 -and
        $Bytes[0] -eq 0xEF -and
        $Bytes[1] -eq 0xBB -and
        $Bytes[2] -eq 0xBF
    ) {
        return [System.Text.UTF8Encoding]::new($true)
    }

    if (
        $Bytes.Length -ge 2 -and
        $Bytes[0] -eq 0xFF -and
        $Bytes[1] -eq 0xFE
    ) {
        return [System.Text.UnicodeEncoding]::new($false, $true)
    }

    if (
        $Bytes.Length -ge 2 -and
        $Bytes[0] -eq 0xFE -and
        $Bytes[1] -eq 0xFF
    ) {
        return [System.Text.UnicodeEncoding]::new($true, $true)
    }

    try {
        $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
        $null = $strictUtf8.GetString($Bytes)

        return [System.Text.UTF8Encoding]::new($false)
    }
    catch {
        return [System.Text.Encoding]::Default
    }
}


function Read-MowTextFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return [pscustomobject]@{
            Text = ''
            Encoding = [System.Text.UTF8Encoding]::new($false)
        }
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $encoding = Get-MowTextEncoding -Bytes $bytes
    $text = $encoding.GetString($bytes)

    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
        $text = $text.Substring(1)
    }

    return [pscustomobject]@{
        Text = $text
        Encoding = $encoding
    }
}


function Write-MowTextFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory)]
        [System.Text.Encoding]$Encoding
    )

    [System.IO.File]::WriteAllText(
        $Path,
        $Text,
        $Encoding
    )
}


function Get-MowFileSnapshot {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $exists = [System.IO.File]::Exists($Path)
    $bytes = if ($exists) {
        [System.IO.File]::ReadAllBytes($Path)
    }
    else {
        [byte[]]@()
    }

    return [pscustomobject]@{
        Exists = $exists
        Bytes = $bytes
    }
}


function Test-MowDownloadedPowerShell {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Label
    )

    $downloadBytes = [System.IO.File]::ReadAllBytes($Path)
    $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)

    try {
        $downloadText = $strictUtf8.GetString($downloadBytes)
    }
    catch {
        throw "Downloaded $Label is not valid UTF-8: $($_.Exception.Message)"
    }

    if (
        $downloadText.Length -gt 0 -and
        $downloadText[0] -eq [char]0xFEFF
    ) {
        $downloadText = $downloadText.Substring(1)
    }

    $tokens = $null
    $parseErrors = $null

    [System.Management.Automation.Language.Parser]::ParseInput(
        $downloadText,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null

    if ($parseErrors.Count -eq 0) {
        return
    }

    $message = (
        $parseErrors |
            ForEach-Object {
                $_.Message
            }
    ) -join [Environment]::NewLine

    throw "Downloaded $Label failed PowerShell syntax validation:`n$message"
}


function ConvertTo-MowVersion {
    param(
        [Parameter(Mandatory)]
        [string]$Version
    )

    if (
        $Version -notmatch
        '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$'
    ) {
        throw "Invalid MowPSKit version '$Version'. Use X.Y.Z, for example 1.0.0."
    }

    try {
        return [version]$Version
    }
    catch {
        throw "MowPSKit version '$Version' contains a number that is too large."
    }
}


function Compare-MowVersion {
    param(
        [Parameter(Mandatory)]
        [string]$Left,

        [Parameter(Mandatory)]
        [string]$Right
    )

    $leftVersion = ConvertTo-MowVersion -Version $Left
    $rightVersion = ConvertTo-MowVersion -Version $Right

    return $leftVersion.CompareTo($rightVersion)
}


function Get-MowArtifactVersion {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)

    try {
        $content = $strictUtf8.GetString($bytes)
    }
    catch {
        throw "MowPSKit artifact is not valid UTF-8: $($_.Exception.Message)"
    }

    if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) {
        $content = $content.Substring(1)
    }

    $constantPattern = "(?m)^\s*Microsoft\.PowerShell\.Utility\\Set-Variable\s+-Name\s+MowPSKitVersion\s+-Value\s+'([^']+)'\s+-Option\s+Constant\s+-Scope\s+Local\s*$"
    $matches = [regex]::Matches($content, $constantPattern)
    $legacyVersionFormat = $false

    if ($matches.Count -eq 0) {
        # Compatibility with artifacts generated before MowPSKitVersion became a Constant.
        $legacyPattern = "(?m)^\s*Version\s*=\s*'([^']+)'\s*$"
        $matches = [regex]::Matches($content, $legacyPattern)
        $legacyVersionFormat = $true
    }

    if ($matches.Count -ne 1) {
        throw 'MowPSKit artifact must contain exactly one embedded product version.'
    }

    $version = [string]$matches[0].Groups[1].Value

    if ($legacyVersionFormat -and $version.Contains('+')) {
        $version = @($version -split '\+', 2)[0]
    }

    $null = ConvertTo-MowVersion -Version $version

    return $version
}


function Confirm-MowOperation {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Install', 'Update')]
        [string]$Operation,

        [Parameter(Mandatory)]
        [string]$RemoteVersion,

        [AllowEmptyString()]
        [string]$InstalledVersion = ''
    )

    if ($Force) {
        return $true
    }

    $prompt = if ($Operation -eq 'Install') {
        "Install MowPSKit $RemoteVersion? [y/N]"
    }
    else {
        "Update MowPSKit from $InstalledVersion to $RemoteVersion? [y/N]"
    }

    [string]$response = Read-Host $prompt
    return $response.Trim().ToLowerInvariant() -in @('y', 'yes')
}


function Add-MowProfileBlock {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $profileDir = Split-Path $Path -Parent

    if (-not (Test-Path $profileDir)) {
        New-Item `
            -ItemType Directory `
            -Path $profileDir `
            -Force |
            Out-Null
    }

    $file = Read-MowTextFile -Path $Path
    $text = $file.Text
    $newLine = if ($text.Contains("`r`n")) {
        "`r`n"
    }
    elseif ($text.Contains("`n")) {
        "`n"
    }
    else {
        [Environment]::NewLine
    }
    $managedBlock = @(
        $ProfileStart
        $ProfileLoader
        $ProfileEnd
    ) -join $newLine
    $managedBlock += $newLine
    $profilePattern = '(?ms)^[ \t]*# >>> MowPSKit >>>[ \t]*\r?\n.*?^[ \t]*# <<< MowPSKit <<<[ \t]*(?:\r?\n)?'
    $managedMatches = [regex]::Matches($text, $profilePattern)

    if ($managedMatches.Count -gt 1) {
        throw "Profile '$Path' contains more than one MowPSKit managed block."
    }

    if ($managedMatches.Count -eq 1) {
        $managedMatch = $managedMatches[0]
        $updatedText = $text.Substring(0, $managedMatch.Index) +
            $managedBlock +
            $text.Substring($managedMatch.Index + $managedMatch.Length)

        if ($updatedText -eq $text) {
            return
        }

        Write-MowTextFile `
            -Path $Path `
            -Text $updatedText `
            -Encoding $file.Encoding
        return
    }

    if (
        $text.Contains($ProfileStart) -or
        $text.Contains($ProfileEnd)
    ) {
        throw "Profile '$Path' contains an incomplete MowPSKit managed block."
    }

    if ($text.Length -gt 0 -and -not $text.EndsWith($newLine)) {
        $text += $newLine
    }

    $text += $managedBlock

    Write-MowTextFile `
        -Path $Path `
        -Text $text `
        -Encoding $file.Encoding
}


function Confirm-MowProfileExecutionPolicy {
    $effectivePolicy = [string](Get-ExecutionPolicy)

    if ($effectivePolicy -notin @('Restricted', 'AllSigned')) {
        return
    }

    $managedPolicy = Get-ExecutionPolicy -List |
        Where-Object {
            $_.Scope -in @('MachinePolicy', 'UserPolicy') -and
            [string]$_.ExecutionPolicy -in @('Restricted', 'AllSigned')
        } |
        Select-Object -First 1

    if ($managedPolicy) {
        throw (
            "PowerShell profile scripts are blocked by $($managedPolicy.Scope) " +
            "($($managedPolicy.ExecutionPolicy)). MowPSKit was not installed and " +
            'the managed execution policy was not changed.'
        )
    }

    Write-Warning (
        "The effective PowerShell execution policy is $effectivePolicy, so the " +
        'MowPSKit profile loader cannot run.'
    )

    [string]$response = Read-Host (
        'Set the CurrentUser execution policy to RemoteSigned? [y/N]'
    )

    if ($response.Trim().ToLowerInvariant() -notin @('y', 'yes')) {
        throw (
            'MowPSKit installation was cancelled before any files were changed. ' +
            'Set the CurrentUser execution policy to RemoteSigned, then run setup again.'
        )
    }

    Set-ExecutionPolicy `
        -Scope CurrentUser `
        -ExecutionPolicy RemoteSigned `
        -Force

    $updatedPolicy = [string](Get-ExecutionPolicy)

    if ($updatedPolicy -in @('Restricted', 'AllSigned')) {
        throw (
            "The effective PowerShell execution policy is still $updatedPolicy. " +
            'MowPSKit was not installed.'
        )
    }
}


function Invoke-MowInstallOrUpdate {
    $profilePath = $ProfilePath
    $isInstalled = [System.IO.File]::Exists($InstallPath)

    if ($Action -eq 'Update' -and -not $isInstalled) {
        Write-Host 'MowPSKit is not installed. Run mow.install first.'
        return
    }

    $installDirExisted = [System.IO.Directory]::Exists($InstallDir)
    $installSucceeded = $false
    $transactionId = [guid]::NewGuid().ToString('N')
    $tempPath = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        "MowPSKit.$transactionId.download"
    $metadataTempPath = Join-Path $InstallDir "install.$transactionId.download"
    $transactionStarted = $false
    $operation = 'Install'
    $installedVersion = ''

    try {
        Write-Host 'Downloading MowPSKit...'

        Invoke-RestMethod `
            -Uri $ArtifactUrl `
            -OutFile $tempPath

        Test-MowDownloadedPowerShell `
            -Path $tempPath `
            -Label 'artifact'

        $remoteVersion = Get-MowArtifactVersion -Path $tempPath

        if ($isInstalled) {
            $operation = 'Update'
            $installedVersion = Get-MowArtifactVersion -Path $InstallPath
            $comparison = Compare-MowVersion `
                -Left $remoteVersion `
                -Right $installedVersion

            if ($comparison -eq 0) {
                Write-Host "MowPSKit $installedVersion is already up to date."
                return
            }

            if ($comparison -lt 0) {
                Write-Host (
                    "Installed MowPSKit $installedVersion is newer than remote " +
                    "$remoteVersion. Downgrade skipped."
                )
                return
            }
        }

        if (-not (Confirm-MowOperation `
            -Operation $operation `
            -RemoteVersion $remoteVersion `
            -InstalledVersion $installedVersion)) {
            Write-Host "MowPSKit $($operation.ToLowerInvariant()) cancelled."
            return
        }

        if ($operation -eq 'Install') {
            Confirm-MowProfileExecutionPolicy
        }

        New-Item `
            -ItemType Directory `
            -Path $InstallDir `
            -Force |
            Out-Null

        $profilePaths = @($profilePath)

        if (Test-Path $MetadataPath) {
            try {
                $oldMetadata = Get-Content `
                    -Path $MetadataPath `
                    -Raw |
                    ConvertFrom-Json

                if ($oldMetadata.ProfilePaths) {
                    $profilePaths += @($oldMetadata.ProfilePaths)
                }
                elseif ($oldMetadata.ProfilePath) {
                    $profilePaths += @($oldMetadata.ProfilePath)
                }
            }
            catch {
                Write-Warning 'Existing installation metadata could not be read. It will be replaced.'
            }
        }

        $profilePaths = @(
            $profilePaths |
                Where-Object {
                    $_
                } |
                Select-Object -Unique
        )

        $metadata = [ordered]@{
            Product = $ProductName
            Version = $remoteVersion
            InstallPath = $InstallPath
            ProfilePaths = $profilePaths
            ArtifactUrl = $ArtifactUrl
            InstalledAt = (Get-Date).ToString('o')
        }

        $metadataJson = $metadata |
            ConvertTo-Json

        [System.IO.File]::WriteAllText(
            $metadataTempPath,
            $metadataJson,
            [System.Text.UTF8Encoding]::new($false)
        )

        $installSnapshot = Get-MowFileSnapshot -Path $InstallPath
        $metadataSnapshot = Get-MowFileSnapshot -Path $MetadataPath
        $profileSnapshot = Get-MowFileSnapshot -Path $profilePath
        $runtimeModulesBefore = @(
            Microsoft.PowerShell.Core\Get-Module `
                -Name $ProductName `
                -All
        )
        $transactionStarted = $true

        Move-Item `
            -LiteralPath $tempPath `
            -Destination $InstallPath `
            -Force

        Add-MowProfileBlock -Path $profilePath

        Move-Item `
            -LiteralPath $metadataTempPath `
            -Destination $MetadataPath `
            -Force

        & $InstallPath

        $runtimeModulesAfter = @(
            Microsoft.PowerShell.Core\Get-Module `
                -Name $ProductName `
                -All
        )
        $reusedOldRuntime = $false

        foreach ($oldRuntime in $runtimeModulesBefore) {
            foreach ($newRuntime in $runtimeModulesAfter) {
                if ([object]::ReferenceEquals($oldRuntime, $newRuntime)) {
                    $reusedOldRuntime = $true
                }
            }
        }

        if (
            $runtimeModulesAfter.Count -ne 1 -or
            $reusedOldRuntime
        ) {
            throw 'Downloaded artifact did not load exactly one new MowPSKit runtime module.'
        }

        $runtimeVersion = & 'mow.ver'

        if (
            [string]$runtimeVersion.Version -ne $remoteVersion -or
            [string]$runtimeVersion.Mode -ne 'Installed' -or
            [string]$runtimeVersion.BuildMode -ne 'Compiled'
        ) {
            throw (
                'Downloaded artifact loaded with unexpected runtime metadata. ' +
                "Version=$($runtimeVersion.Version); " +
                "Mode=$($runtimeVersion.Mode); " +
                "BuildMode=$($runtimeVersion.BuildMode)."
            )
        }

        $installSucceeded = $true
        $completedOperation = if ($operation -eq 'Update') {
            'updated'
        }
        else {
            'installed'
        }

        Write-Host ''
        Write-Host "MowPSKit $completedOperation."
        Write-Host "  Version : $remoteVersion"
        Write-Host "  Path    : $InstallPath"
        Write-Host "  Profile : $profilePath"
    }
    catch {
        $installError = $_
        $rollbackErrors = [System.Collections.Generic.List[string]]::new()

        if ($transactionStarted) {
            $installFileRestored = $false

            foreach ($rollback in @(
                [pscustomobject]@{
                    Path = $InstallPath
                    Snapshot = $installSnapshot
                }
                [pscustomobject]@{
                    Path = $MetadataPath
                    Snapshot = $metadataSnapshot
                }
                [pscustomobject]@{
                    Path = $profilePath
                    Snapshot = $profileSnapshot
                }
            )) {
                try {
                    if ($rollback.Snapshot.Exists) {
                        $parent = Split-Path $rollback.Path -Parent

                        if (-not [System.IO.Directory]::Exists($parent)) {
                            [void][System.IO.Directory]::CreateDirectory($parent)
                        }

                        [System.IO.File]::WriteAllBytes(
                            $rollback.Path,
                            [byte[]]$rollback.Snapshot.Bytes
                        )
                    }
                    elseif ([System.IO.File]::Exists($rollback.Path)) {
                        Remove-Item -LiteralPath $rollback.Path -Force
                    }

                    if ($rollback.Path -eq $InstallPath) {
                        $installFileRestored = $true
                    }
                }
                catch {
                    $rollbackErrors.Add(
                        "Failed to restore '$($rollback.Path)': $($_.Exception.Message)"
                    )
                }
            }

            $currentRuntimes = @(
                Microsoft.PowerShell.Core\Get-Module `
                    -Name $ProductName `
                    -All
            )
            $previousRuntimeStillLoaded = if (
                $runtimeModulesBefore.Count -eq 0
            ) {
                $currentRuntimes.Count -eq 0
            }
            else {
                $stillLoaded = (
                    $runtimeModulesBefore.Count -eq $currentRuntimes.Count
                )

                foreach ($previousRuntime in $runtimeModulesBefore) {
                    $matchingRuntimeFound = $false

                    foreach ($currentRuntime in $currentRuntimes) {
                        if ([object]::ReferenceEquals(
                            $previousRuntime,
                            $currentRuntime
                        )) {
                            $matchingRuntimeFound = $true
                        }
                    }

                    if (-not $matchingRuntimeFound) {
                        $stillLoaded = $false
                    }
                }

                $stillLoaded
            }

            if (-not $previousRuntimeStillLoaded) {
                foreach ($currentRuntime in $currentRuntimes) {
                    Microsoft.PowerShell.Core\Remove-Module `
                        -ModuleInfo $currentRuntime `
                        -Force `
                        -ErrorAction SilentlyContinue
                }

                if (
                    $installSnapshot.Exists -and
                    $installFileRestored
                ) {
                    try {
                        & $InstallPath

                        $restoredRuntimes = @(
                            Microsoft.PowerShell.Core\Get-Module `
                                -Name $ProductName `
                                -All
                        )

                        if ($restoredRuntimes.Count -ne 1) {
                            throw 'The previous runtime did not reload exactly once.'
                        }

                        if (-not [string]::IsNullOrWhiteSpace($installedVersion)) {
                            $restoredVersion = & 'mow.ver'

                            if (
                                [string]$restoredVersion.Version -ne
                                    $installedVersion
                            ) {
                                throw (
                                    'The restored runtime version does not match ' +
                                    "the restored file ($installedVersion)."
                                )
                            }
                        }
                    }
                    catch {
                        $rollbackErrors.Add(
                            "Failed to reload the restored runtime: $($_.Exception.Message)"
                        )
                    }
                }
            }
        }

        if ($rollbackErrors.Count -gt 0) {
            throw (
                "MowPSKit installation failed: $($installError.Exception.Message)" +
                [Environment]::NewLine +
                'Rollback also failed:' +
                [Environment]::NewLine +
                ($rollbackErrors -join [Environment]::NewLine)
            )
        }

        throw $installError
    }
    finally {
        foreach ($stagedPath in @(
            $tempPath
            $metadataTempPath
        )) {
            if (-not [System.IO.File]::Exists($stagedPath)) {
                continue
            }

            Remove-Item `
                -LiteralPath $stagedPath `
                -Force `
                -ErrorAction SilentlyContinue
        }

        if (
            -not $installSucceeded -and
            -not $installDirExisted -and
            [System.IO.Directory]::Exists($InstallDir) -and
            [System.IO.Directory]::GetFileSystemEntries($InstallDir).Count -eq 0
        ) {
            [System.IO.Directory]::Delete($InstallDir)
        }
    }
}


switch ($Action) {
    'Install' {
        Invoke-MowInstallOrUpdate
    }

    'Update' {
        Invoke-MowInstallOrUpdate
    }
}
