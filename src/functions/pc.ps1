$MowExports = 'info'


function ConvertTo-PcGigabytes {
    <#
    .SYNOPSIS
    Converts a byte value to gigabytes for the PC hardware report.
    #>
    param (
        [AllowNull()]
        [object]$Bytes
    )

    if ($null -eq $Bytes) {
        return $null
    }

    try {
        return [Math]::Round(([double]$Bytes / 1GB), 2)
    }
    catch {
        return $null
    }
}


function ConvertTo-PcDateString {
    <#
    .SYNOPSIS
    Converts CIM/WMI date values to yyyy-MM-dd.
    #>
    param (
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [datetime]) {
        return $Value.ToString('yyyy-MM-dd')
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    try {
        $date = [System.Management.ManagementDateTimeConverter]::ToDateTime($text)
        return $date.ToString('yyyy-MM-dd')
    }
    catch {
        try {
            $date = [datetime]::Parse($text)
            return $date.ToString('yyyy-MM-dd')
        }
        catch {
            return $text
        }
    }
}


function ConvertFrom-PcMonitorString {
    <#
    .SYNOPSIS
    Converts a WmiMonitorID character array to text.
    #>
    param (
        [AllowNull()]
        [object[]]$Value
    )

    if (-not $Value) {
        return $null
    }

    $characters = @(
        $Value |
            Where-Object { [int]$_ -ne 0 } |
            ForEach-Object { [char][int]$_ }
    )

    if ($characters.Count -eq 0) {
        return $null
    }

    return (-join $characters).Trim()
}


function Resolve-PcBoardVendor {
    <#
    .SYNOPSIS
    Resolves common PCI subsystem vendor IDs to board-vendor names.
    #>
    param (
        [AllowNull()]
        [string]$SubsystemVendor
    )

    if ([string]::IsNullOrWhiteSpace($SubsystemVendor)) {
        return $null
    }

    switch ($SubsystemVendor.ToUpperInvariant()) {
        '1043' { return 'ASUS' }
        '1458' { return 'GIGABYTE' }
        '1462' { return 'MSI' }
        '1849' { return 'ASRock' }
        '196E' { return 'PNY' }
        '19DA' { return 'ZOTAC' }
        '1DA2' { return 'SAPPHIRE' }
        '1569' { return 'Palit' }
        '1682' { return 'XFX' }
        '3842' { return 'EVGA' }
        default { return $null }
    }
}


function ConvertTo-PcIntegerOrNull {
    <#
    .SYNOPSIS
    Converts a numeric text value to Int64 when possible.
    #>
    param (
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text) -or $text -match '^N/A$') {
        return $null
    }

    $number = 0L
    if (
        [long]::TryParse(
            $text,
            [System.Globalization.NumberStyles]::Integer,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$number
        )
    ) {
        return $number
    }

    return $null
}


function Get-PcNvidiaInfo {
    <#
    .SYNOPSIS
    Gets extended NVIDIA GPU information through nvidia-smi when available.
    #>
    [CmdletBinding()]
    param()

    $command = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
    if (-not $command) {
        $command = Get-Command 'nvidia-smi' -ErrorAction SilentlyContinue
    }

    if (-not $command) {
        return @()
    }

    $commandPath = if ($command.Path) {
        $command.Path
    }
    elseif ($command.Source) {
        $command.Source
    }
    else {
        $command.Name
    }

    $query = @(
        'name'
        'driver_version'
        'vbios_version'
        'memory.total'
        'pci.bus_id'
        'clocks.current.graphics'
        'clocks.current.memory'
        'clocks.max.graphics'
        'clocks.max.memory'
    ) -join ','

    try {
        $rows = @(
            & $commandPath `
                "--query-gpu=$query" `
                '--format=csv,noheader,nounits' `
                2>$null
        )
    }
    catch {
        return @()
    }

    $result = @()

    foreach ($row in $rows) {
        if ([string]::IsNullOrWhiteSpace([string]$row)) {
            continue
        }

        $columns = @(
            ([string]$row) -split '\s*,\s*' |
                ForEach-Object { $_.Trim() }
        )

        if ($columns.Count -lt 9) {
            continue
        }

        $result += [PSCustomObject][ordered]@{
            name         = $columns[0]
            driver       = $columns[1]
            vbios        = $columns[2]
            vram_mb      = ConvertTo-PcIntegerOrNull $columns[3]
            bus_id       = $columns[4]
            core_mhz     = ConvertTo-PcIntegerOrNull $columns[5]
            mem_mhz      = ConvertTo-PcIntegerOrNull $columns[6]
            max_core_mhz = ConvertTo-PcIntegerOrNull $columns[7]
            max_mem_mhz  = ConvertTo-PcIntegerOrNull $columns[8]
        }
    }

    return @($result)
}


function Get-PcHardwareData {
    <#
    .SYNOPSIS
    Collects the complete PC hardware data used by all report formats.

    .DESCRIPTION
    Collects system, CPU, GPU, PCI, memory, motherboard, BIOS, storage,
    volume, monitor, Windows, battery, and optional NVIDIA information once.
    Raw and derived values are kept in one shared object so RAW, Markdown,
    and JSON output are generated from the same report data.
    #>
    [CmdletBinding()]
    param()

    if ($env:OS -ne 'Windows_NT') {
        throw 'info is supported on Windows only.'
    }

    $reportTimestamp = [DateTimeOffset]::Now.ToString(
        'o',
        [System.Globalization.CultureInfo]::InvariantCulture
    )

    $computerSystem = Get-CimInstance `
        -ClassName Win32_ComputerSystem `
        -ErrorAction Stop

    $processorItems = @(
        Get-CimInstance `
            -ClassName Win32_Processor `
            -ErrorAction Stop
    )

    $processor = if ($processorItems.Count -gt 0) {
        $processorItems[0]
    }
    else {
        $null
    }

    $system = [PSCustomObject][ordered]@{
        maker  = $computerSystem.Manufacturer
        model  = $computerSystem.Model
        type   = $computerSystem.SystemType
        ram_gb = ConvertTo-PcGigabytes $computerSystem.TotalPhysicalMemory
    }

    $cpu = if ($processor) {
        [PSCustomObject][ordered]@{
            name    = $processor.Name
            maker   = $processor.Manufacturer
            cores   = [int]$processor.NumberOfCores
            threads = [int]$processor.NumberOfLogicalProcessors
            max_mhz = [int]$processor.MaxClockSpeed
        }
    }
    else {
        $null
    }

    $videoControllers = @(
        Get-CimInstance `
            -ClassName Win32_VideoController `
            -ErrorAction SilentlyContinue
    )

    $gpuBasic = @()

    foreach ($video in $videoControllers) {
        $vendorId = $null
        if ($video.PNPDeviceID -match 'VEN_([0-9A-Fa-f]{4})') {
            $vendorId = $Matches[1].ToUpperInvariant()
        }

        $vendor = switch ($vendorId) {
            '10DE' { 'NVIDIA' }
            '1002' { 'AMD' }
            '1022' { 'AMD' }
            '8086' { 'Intel' }
            default {
                if ($video.AdapterCompatibility) {
                    [string]$video.AdapterCompatibility
                }
                else {
                    $null
                }
            }
        }

        $mode = $null
        if (
            $null -ne $video.CurrentHorizontalResolution -and
            $null -ne $video.CurrentVerticalResolution
        ) {
            if ($null -ne $video.CurrentBitsPerPixel) {
                $colors = [Math]::Pow(2, [double]$video.CurrentBitsPerPixel)
                $mode = '{0} x {1} x {2} colors' -f (
                    $video.CurrentHorizontalResolution,
                    $video.CurrentVerticalResolution,
                    $colors.ToString('0', [System.Globalization.CultureInfo]::InvariantCulture)
                )
            }
            else {
                $mode = '{0} x {1}' -f (
                    $video.CurrentHorizontalResolution,
                    $video.CurrentVerticalResolution
                )
            }
        }

        $gpuBasic += [PSCustomObject][ordered]@{
            name        = $video.Name
            vendor      = $vendor
            ven_id      = $vendorId
            driver      = $video.DriverVersion
            driver_date = ConvertTo-PcDateString $video.DriverDate
            chip        = $video.VideoProcessor
            mode        = $mode
            vram_gb     = ConvertTo-PcGigabytes $video.AdapterRAM
            pnp_id      = $video.PNPDeviceID
        }
    }

    $displayClassGuid = '{4d36e968-e325-11ce-bfc1-08002be10318}'
    $displayDevices = @(
        Get-CimInstance `
            -ClassName Win32_PnPEntity `
            -ErrorAction SilentlyContinue |
            Where-Object {
                $_.PNPDeviceID -like 'PCI\VEN_*' -and
                (
                    $_.ClassGuid -eq $displayClassGuid -or
                    $_.PNPClass -eq 'Display'
                )
            }
    )

    $gpuPci = @()

    foreach ($device in $displayDevices) {
        $instanceId = [string]$device.PNPDeviceID
        $vendorId = $null
        $deviceId = $null
        $subsystemId = $null
        $subsystemModel = $null
        $subsystemVendor = $null

        if ($instanceId -match 'VEN_([0-9A-Fa-f]{4})') {
            $vendorId = $Matches[1].ToUpperInvariant()
        }

        if ($instanceId -match 'DEV_([0-9A-Fa-f]{4})') {
            $deviceId = $Matches[1].ToUpperInvariant()
        }

        if ($instanceId -match 'SUBSYS_([0-9A-Fa-f]{8})') {
            $subsystemId = $Matches[1].ToUpperInvariant()
            $subsystemModel = $subsystemId.Substring(0, 4)
            $subsystemVendor = $subsystemId.Substring(4, 4)
        }

        $vendor = switch ($vendorId) {
            '10DE' { 'NVIDIA' }
            '1002' { 'AMD' }
            '1022' { 'AMD' }
            '8086' { 'Intel' }
            default { $device.Manufacturer }
        }

        $hardwareIds = @($device.HardwareID)
        $hardwareId = if ($hardwareIds.Count -gt 0) {
            $hardwareIds[0]
        }
        else {
            $null
        }

        $gpuPci += [PSCustomObject][ordered]@{
            name         = $device.Name
            status       = $device.Status
            vendor       = $vendor
            ven_id       = $vendorId
            dev_id       = $deviceId
            subsys_id    = $subsystemId
            subsys_model = $subsystemModel
            subsys_ven   = $subsystemVendor
            board_vendor = Resolve-PcBoardVendor $subsystemVendor
            hw_id        = $hardwareId
            instance_id  = $instanceId
            hw_ids       = @($hardwareIds)
        }
    }

    $memoryModules = @(
        Get-CimInstance `
            -ClassName Win32_PhysicalMemory `
            -ErrorAction SilentlyContinue
    )

    $ram = @()
    foreach ($module in $memoryModules) {
        $configuredSpeed = if ($null -ne $module.ConfiguredClockSpeed) {
            [int]$module.ConfiguredClockSpeed
        }
        elseif ($null -ne $module.Speed) {
            [int]$module.Speed
        }
        else {
            $null
        }

        $ram += [PSCustomObject][ordered]@{
            maker     = if ($module.Manufacturer) { $module.Manufacturer.Trim() } else { $null }
            part      = if ($module.PartNumber) { $module.PartNumber.Trim() } else { $null }
            size_gb   = ConvertTo-PcGigabytes $module.Capacity
            speed_mhz = if ($null -ne $module.Speed) { [int]$module.Speed } else { $null }
            clock_mhz = $configuredSpeed
        }
    }

    $ramTotal = 0.0
    foreach ($module in $ram) {
        if ($null -ne $module.size_gb) {
            $ramTotal += [double]$module.size_gb
        }
    }

    $ramSummary = [PSCustomObject][ordered]@{
        module_count    = $ram.Count
        total_module_gb = [Math]::Round($ramTotal, 2)
    }

    $baseBoard = Get-CimInstance `
        -ClassName Win32_BaseBoard `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    $board = if ($baseBoard) {
        [PSCustomObject][ordered]@{
            maker   = $baseBoard.Manufacturer
            model   = $baseBoard.Product
            version = $baseBoard.Version
        }
    }
    else {
        $null
    }

    $biosItem = Get-CimInstance `
        -ClassName Win32_BIOS `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    $bios = if ($biosItem) {
        [PSCustomObject][ordered]@{
            maker   = $biosItem.Manufacturer
            version = $biosItem.SMBIOSBIOSVersion
            date    = ConvertTo-PcDateString $biosItem.ReleaseDate
        }
    }
    else {
        $null
    }

    $physicalDisks = @()
    try {
        $physicalDisks = @(
            Get-PhysicalDisk -ErrorAction Stop |
                Sort-Object DeviceId
        )
    }
    catch {
        $physicalDisks = @()
    }

    $storageDisks = @()
    foreach ($disk in $physicalDisks) {
        $status = @(
            $disk.OperationalStatus |
                ForEach-Object { [string]$_ }
        )

        $storageDisks += [PSCustomObject][ordered]@{
            name   = $disk.FriendlyName
            type   = [string]$disk.MediaType
            bus    = [string]$disk.BusType
            size_gb = ConvertTo-PcGigabytes $disk.Size
            health = [string]$disk.HealthStatus
            status = @($status)
        }
    }

    $diskDrives = @(
        Get-CimInstance `
            -ClassName Win32_DiskDrive `
            -ErrorAction SilentlyContinue |
            Sort-Object Index
    )

    $storageModels = @()
    foreach ($disk in $diskDrives) {
        $storageModels += [PSCustomObject][ordered]@{
            model   = $disk.Model
            bus     = $disk.InterfaceType
            type    = $disk.MediaType
            size_gb = ConvertTo-PcGigabytes $disk.Size
        }
    }

    if ($storageDisks.Count -eq 0) {
        foreach ($disk in $diskDrives) {
            $storageDisks += [PSCustomObject][ordered]@{
                name    = $disk.Model
                type    = $disk.MediaType
                bus     = $disk.InterfaceType
                size_gb = ConvertTo-PcGigabytes $disk.Size
                health  = $null
                status  = @()
            }
        }
    }

    $logicalDisks = @(
        Get-CimInstance `
            -ClassName Win32_LogicalDisk `
            -Filter 'DriveType = 3' `
            -ErrorAction SilentlyContinue |
            Sort-Object DeviceID
    )

    $volumes = @()
    foreach ($volume in $logicalDisks) {
        $sizeGb = ConvertTo-PcGigabytes $volume.Size
        $freeGb = ConvertTo-PcGigabytes $volume.FreeSpace
        $usedPercent = $null

        if ($null -ne $volume.Size -and [double]$volume.Size -gt 0) {
            $usedPercent = [Math]::Round(
                (([double]$volume.Size - [double]$volume.FreeSpace) / [double]$volume.Size) * 100,
                1
            )
        }

        $drive = if ($volume.DeviceID) {
            ([string]$volume.DeviceID).TrimEnd(':')
        }
        else {
            $null
        }

        $volumes += [PSCustomObject][ordered]@{
            drive        = $drive
            label        = if ($null -ne $volume.VolumeName) { [string]$volume.VolumeName } else { '' }
            fs           = $volume.FileSystem
            size_gb      = $sizeGb
            free_gb      = $freeGb
            used_percent = $usedPercent
        }
    }

    $monitorItems = @()
    try {
        $monitorItems = @(
            Get-CimInstance `
                -Namespace 'root\wmi' `
                -ClassName WmiMonitorID `
                -ErrorAction Stop |
                Where-Object { $_.Active -ne $false }
        )
    }
    catch {
        $monitorItems = @()
    }

    $monitors = @()
    foreach ($monitor in $monitorItems) {
        $monitors += [PSCustomObject][ordered]@{
            maker = ConvertFrom-PcMonitorString $monitor.ManufacturerName
            model = ConvertFrom-PcMonitorString $monitor.UserFriendlyName
        }
    }

    $osItem = Get-CimInstance `
        -ClassName Win32_OperatingSystem `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    $os = if ($osItem) {
        [PSCustomObject][ordered]@{
            name    = $osItem.Caption
            version = $osItem.Version
            build   = $osItem.BuildNumber
            arch    = $osItem.OSArchitecture
        }
    }
    else {
        $null
    }

    $batteryItems = @(
        Get-CimInstance `
            -ClassName Win32_Battery `
            -ErrorAction SilentlyContinue
    )

    $battery = $null
    if ($batteryItems.Count -gt 0) {
        $battery = @()
        foreach ($item in $batteryItems) {
            $battery += [PSCustomObject][ordered]@{
                name                       = $item.Name
                status                     = $item.Status
                estimated_charge_remaining = $item.EstimatedChargeRemaining
            }
        }
    }

    $nvidia = @(Get-PcNvidiaInfo)

    return [PSCustomObject][ordered]@{
        report_timestamp = $reportTimestamp
        system           = $system
        cpu              = $cpu
        gpu              = [PSCustomObject][ordered]@{
            basic  = @($gpuBasic)
            pci    = @($gpuPci)
            nvidia = @($nvidia)
        }
        ram              = @($ram)
        ram_summary      = $ramSummary
        board            = $board
        bios             = $bios
        storage          = [PSCustomObject][ordered]@{
            disks  = @($storageDisks)
            models = @($storageModels)
        }
        volumes          = @($volumes)
        monitors         = @($monitors)
        os               = $os
        battery          = $battery
    }
}


function Format-PcDisplayValue {
    <#
    .SYNOPSIS
    Formats empty report values as a readable unknown value.
    #>
    param (
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return '未知'
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return '未知'
    }

    return $text
}


function Format-PcNumber {
    <#
    .SYNOPSIS
    Formats report numbers using invariant-culture separators.
    #>
    param (
        [AllowNull()]
        [object]$Value,

        [int]$Decimals = 2
    )

    if ($null -eq $Value) {
        return '未知'
    }

    try {
        $format = 'N{0}' -f $Decimals
        return ([double]$Value).ToString(
            $format,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }
    catch {
        return Format-PcDisplayValue $Value
    }
}


function ConvertTo-PcRaw {
    <#
    .SYNOPSIS
    Converts PC hardware data to plain-text RAW output.
    #>
    param (
        [Parameter(Mandatory)]
        [object]$Data
    )

    $lines = @()

    $lines += 'PC 硬體資訊'
    $lines += ''
    $lines += "report_timestamp: $($Data.report_timestamp)"
    $lines += ''
    $lines += '快速摘要'
    $lines += "CPU: $(Format-PcDisplayValue $Data.cpu.name)"

    foreach ($gpu in @($Data.gpu.basic)) {
        $lines += "GPU: $(Format-PcDisplayValue $gpu.name) ($(Format-PcDisplayValue $gpu.vendor))"
    }

    $lines += "RAM: $(Format-PcNumber $Data.ram_summary.total_module_gb 2) GB / $($Data.ram_summary.module_count) 條"

    foreach ($disk in @($Data.storage.disks)) {
        $lines += "儲存裝置: $(Format-PcDisplayValue $disk.name) / $(Format-PcNumber $disk.size_gb 2) GB / $(Format-PcDisplayValue $disk.bus)"
    }

    if ($Data.os) {
        $lines += "系統: $(Format-PcDisplayValue $Data.os.name) / $(Format-PcDisplayValue $Data.os.arch)"
    }

    $lines += ''
    $lines += '電腦整體資訊'
    $lines += "製造商: $(Format-PcDisplayValue $Data.system.maker)"
    $lines += "型號: $(Format-PcDisplayValue $Data.system.model)"
    $lines += "系統類型: $(Format-PcDisplayValue $Data.system.type)"
    $lines += "系統記憶體總量: $(Format-PcNumber $Data.system.ram_gb 2) GB"

    $lines += ''
    $lines += '處理器 CPU'
    if ($Data.cpu) {
        $lines += "CPU 1: $(Format-PcDisplayValue $Data.cpu.name)"
        $lines += "  製造商: $(Format-PcDisplayValue $Data.cpu.maker)"
        $lines += "  實體核心: $(Format-PcDisplayValue $Data.cpu.cores) 核"
        $lines += "  邏輯處理器: $(Format-PcDisplayValue $Data.cpu.threads) 執行緒"
        $lines += "  WMI 標示最高時脈: $(Format-PcNumber $Data.cpu.max_mhz 0) MHz"
    }
    else {
        $lines += '未取得 CPU 資訊'
    }

    $lines += ''
    $lines += '顯示卡 GPU'
    $gpuIndex = 0
    foreach ($gpu in @($Data.gpu.basic)) {
        $gpuIndex++
        $lines += "顯示卡 ${gpuIndex}: $(Format-PcDisplayValue $gpu.name)"
        $lines += "  GPU 廠牌: $(Format-PcDisplayValue $gpu.vendor)"
        $lines += "  PCI Vendor ID: $(Format-PcDisplayValue $gpu.ven_id)"
        $lines += "  驅動版本: $(Format-PcDisplayValue $gpu.driver)"
        $lines += "  驅動日期: $(Format-PcDisplayValue $gpu.driver_date)"
        $lines += "  GPU 處理器: $(Format-PcDisplayValue $gpu.chip)"
        $lines += "  目前影像模式: $(Format-PcDisplayValue $gpu.mode)"
        $lines += "  WMI 回報顯示記憶體: $(Format-PcNumber $gpu.vram_gb 2) GB"
        $lines += "  PNP Device ID: $(Format-PcDisplayValue $gpu.pnp_id)"
    }

    $lines += ''
    $lines += 'PCI / 顯示卡板卡識別'
    $pciIndex = 0
    foreach ($gpu in @($Data.gpu.pci)) {
        $pciIndex++
        $lines += "裝置 ${pciIndex}: $(Format-PcDisplayValue $gpu.name)"
        $lines += "  GPU 晶片廠牌: $(Format-PcDisplayValue $gpu.vendor)"
        $lines += "  狀態: $(Format-PcDisplayValue $gpu.status)"
        $lines += "  PCI Vendor ID: $(Format-PcDisplayValue $gpu.ven_id)"
        $lines += "  PCI Device ID: $(Format-PcDisplayValue $gpu.dev_id)"
        $lines += "  Subsystem ID: $(Format-PcDisplayValue $gpu.subsys_id)"
        $lines += "  Subsystem Model: $(Format-PcDisplayValue $gpu.subsys_model)"
        $lines += "  Subsystem Vendor: $(Format-PcDisplayValue $gpu.subsys_ven)"
        $lines += "  板卡 / OEM 廠牌判定: $(Format-PcDisplayValue $gpu.board_vendor)"
        $lines += "  Hardware ID: $(Format-PcDisplayValue $gpu.hw_id)"
        $lines += "  Instance ID: $(Format-PcDisplayValue $gpu.instance_id)"
        $lines += '  Hardware IDs:'

        if (@($gpu.hw_ids).Count -eq 0) {
            $lines += '    未知'
        }
        else {
            foreach ($hardwareId in @($gpu.hw_ids)) {
                $lines += "    $hardwareId"
            }
        }
    }

    $lines += ''
    $lines += 'NVIDIA 額外資訊'
    if (@($Data.gpu.nvidia).Count -eq 0) {
        $lines += '未取得 NVIDIA 額外資訊'
    }
    else {
        $nvidiaIndex = 0
        foreach ($gpu in @($Data.gpu.nvidia)) {
            $nvidiaIndex++
            $lines += "NVIDIA GPU ${nvidiaIndex}: $(Format-PcDisplayValue $gpu.name)"
            $lines += "  驅動版本: $(Format-PcDisplayValue $gpu.driver)"
            $lines += "  VBIOS: $(Format-PcDisplayValue $gpu.vbios)"
            $lines += "  顯示記憶體: $(Format-PcNumber $gpu.vram_mb 0) MB"
            $lines += "  PCI Bus ID: $(Format-PcDisplayValue $gpu.bus_id)"
            $lines += "  目前核心時脈: $(Format-PcNumber $gpu.core_mhz 0) MHz"
            $lines += "  目前記憶體時脈: $(Format-PcNumber $gpu.mem_mhz 0) MHz"
            $lines += "  最大核心時脈: $(Format-PcNumber $gpu.max_core_mhz 0) MHz"
            $lines += "  最大記憶體時脈: $(Format-PcNumber $gpu.max_mem_mhz 0) MHz"
        }
    }

    $lines += ''
    $lines += '記憶體 RAM'
    $ramIndex = 0
    foreach ($module in @($Data.ram)) {
        $ramIndex++
        $lines += "RAM $ramIndex"
        $lines += "  品牌: $(Format-PcDisplayValue $module.maker)"
        $lines += "  型號 / Part Number: $(Format-PcDisplayValue $module.part)"
        $lines += "  容量: $(Format-PcNumber $module.size_gb 2) GB"
        $lines += "  標示速度: $(Format-PcNumber $module.speed_mhz 0) MHz"
        $lines += "  目前設定速度: $(Format-PcNumber $module.clock_mhz 0) MHz"
    }
    $lines += "RAM 模組數量: $($Data.ram_summary.module_count) 條"
    $lines += "RAM 模組容量加總: $(Format-PcNumber $Data.ram_summary.total_module_gb 2) GB"

    $lines += ''
    $lines += '主機板'
    if ($Data.board) {
        $lines += "品牌: $(Format-PcDisplayValue $Data.board.maker)"
        $lines += "型號: $(Format-PcDisplayValue $Data.board.model)"
        $lines += "版本: $(Format-PcDisplayValue $Data.board.version)"
    }
    else {
        $lines += '未取得主機板資訊'
    }

    $lines += ''
    $lines += 'BIOS / UEFI'
    if ($Data.bios) {
        $lines += "廠商: $(Format-PcDisplayValue $Data.bios.maker)"
        $lines += "BIOS 版本: $(Format-PcDisplayValue $Data.bios.version)"
        $lines += "發布日期: $(Format-PcDisplayValue $Data.bios.date)"
    }
    else {
        $lines += '未取得 BIOS / UEFI 資訊'
    }

    $lines += ''
    $lines += '儲存裝置'
    $lines += ''
    $lines += '實體磁碟'
    $diskIndex = 0
    foreach ($disk in @($Data.storage.disks)) {
        $diskIndex++
        $lines += "  磁碟 ${diskIndex}: $(Format-PcDisplayValue $disk.name)"
        $lines += "    類型: $(Format-PcDisplayValue $disk.type)"
        $lines += "    匯流排: $(Format-PcDisplayValue $disk.bus)"
        $lines += "    容量: $(Format-PcNumber $disk.size_gb 2) GB"
        $lines += "    健康狀態: $(Format-PcDisplayValue $disk.health)"

        $statusText = if (@($disk.status).Count -gt 0) {
            @($disk.status) -join ', '
        }
        else {
            '未知'
        }
        $lines += "    運作狀態: $statusText"
    }

    $lines += ''
    $lines += 'Windows 磁碟型號'
    $modelIndex = 0
    foreach ($disk in @($Data.storage.models)) {
        $modelIndex++
        $lines += "  磁碟 ${modelIndex}: $(Format-PcDisplayValue $disk.model)"
        $lines += "    介面: $(Format-PcDisplayValue $disk.bus)"
        $lines += "    媒體類型: $(Format-PcDisplayValue $disk.type)"
        $lines += "    容量: $(Format-PcNumber $disk.size_gb 2) GB"
    }

    $lines += ''
    $lines += '磁碟分割區 / 磁碟機'
    foreach ($volume in @($Data.volumes)) {
        $labelSuffix = if ([string]::IsNullOrWhiteSpace([string]$volume.label)) {
            ''
        }
        else {
            " $($volume.label)"
        }

        $lines += "  $($volume.drive):$labelSuffix"
        $lines += "    檔案系統: $(Format-PcDisplayValue $volume.fs)"
        $lines += "    總容量: $(Format-PcNumber $volume.size_gb 2) GB"
        $lines += "    剩餘空間: $(Format-PcNumber $volume.free_gb 2) GB"
        $lines += "    已使用: $(Format-PcNumber $volume.used_percent 1)%"
    }

    $lines += ''
    $lines += '螢幕'
    if (@($Data.monitors).Count -eq 0) {
        $lines += '未取得螢幕資訊'
    }
    else {
        $monitorIndex = 0
        foreach ($monitor in @($Data.monitors)) {
            $monitorIndex++
            $lines += "螢幕 ${monitorIndex}: $(Format-PcDisplayValue $monitor.maker) $(Format-PcDisplayValue $monitor.model)"
        }
    }

    $lines += ''
    $lines += 'Windows'
    if ($Data.os) {
        $lines += "系統: $(Format-PcDisplayValue $Data.os.name)"
        $lines += "版本: $(Format-PcDisplayValue $Data.os.version)"
        $lines += "Build: $(Format-PcDisplayValue $Data.os.build)"
        $lines += "架構: $(Format-PcDisplayValue $Data.os.arch)"
    }
    else {
        $lines += '未取得 Windows 資訊'
    }

    $lines += ''
    $lines += '電池'
    if ($null -eq $Data.battery -or @($Data.battery).Count -eq 0) {
        $lines += '未偵測到電池資訊'
    }
    else {
        $batteryIndex = 0
        foreach ($item in @($Data.battery)) {
            $batteryIndex++
            $lines += "電池 ${batteryIndex}: $(Format-PcDisplayValue $item.name)"
            $lines += "  狀態: $(Format-PcDisplayValue $item.status)"
            $lines += "  預估剩餘電量: $(Format-PcDisplayValue $item.estimated_charge_remaining)%"
        }
    }

    return ($lines -join [Environment]::NewLine)
}


function Write-PcRawConsole {
    <#
    .SYNOPSIS
    Writes RAW PC hardware output to the console with MowPSKit styling.

    .DESCRIPTION
    Renders the same plain-text content returned by ConvertTo-PcRaw without
    changing the report data. Section headings, item headings, labels, values,
    status values, and unavailable values are colored through Write-Text.

    This renderer is used only for console output. RAW file output remains
    plain text and never contains ANSI or console color sequences.

    .PARAMETER Content
    Plain-text RAW report content returned by ConvertTo-PcRaw.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )

    $primarySections = @(
        '快速摘要'
        '電腦整體資訊'
        '處理器 CPU'
        '顯示卡 GPU'
        'PCI / 顯示卡板卡識別'
        'NVIDIA 額外資訊'
        '記憶體 RAM'
        '主機板'
        'BIOS / UEFI'
        '儲存裝置'
        '螢幕'
        'Windows'
        '電池'
    )

    $secondarySections = @(
        '實體磁碟'
        'Windows 磁碟型號'
        '磁碟分割區 / 磁碟機'
    )

    $lines = [regex]::Split($Content, '\r?\n')

    foreach ($line in $lines) {
        if ([string]::IsNullOrEmpty($line)) {
            Write-Text -Text ''
            continue
        }

        if ($line -eq 'PC 硬體資訊') {
            Write-Banner `
                -Text $line `
                -Padding "=."
            continue
        }

        if ($primarySections -contains $line) {
            Write-Separator `
                -Text $line `
                -TextColor DarkYellow `
                -TextStyle Bold+Underline
            continue
        }

        if ($secondarySections -contains $line) {
            Write-Text `
                -Text $line `
                -Color Cyan `
                -Style Bold
            continue
        }

        if (
            $line -match '^(\s*)(CPU \d+|顯示卡 \d+|裝置 \d+|NVIDIA GPU \d+|RAM \d+|磁碟 \d+|螢幕 \d+|電池 \d+)(?::\s*(.*))?$'
        ) {
            $indent = $Matches[1]
            $label = $Matches[2]
            $value = $Matches[3]

            if ([string]::IsNullOrWhiteSpace($value)) {
                Write-Text `
                    -Text "$indent$label" `
                    -Color Cyan `
                    -Style Bold
            }
            else {
                Write-Text `
                    -Text "$indent$label", ': ', $value `
                    -Color Cyan, DarkGray, Magenta `
                    -Style Bold, None, None
            }
            continue
        }

        if ($line -match '^(\s*)([A-Z]:)(.*)$') {
            Write-Text `
                -Text "$($Matches[1])$($Matches[2])", $Matches[3] `
                -Color Cyan, White `
                -Style Bold, None
            continue
        }

        if ($line -match '^(\s*)([^:]+):\s?(.*)$') {
            $indent = $Matches[1]
            $label = $Matches[2]
            $value = $Matches[3]

            $valueColor = [ConsoleColor]::White
            $valueStyle = 'Underline'
            if ($value -match '^(OK|Healthy)$') {
                $valueColor = [ConsoleColor]::Green
                $valueStyle = ''
            }
            elseif ($value -match '^(未知|未取得.*|未偵測.*)$') {
                $valueColor = [ConsoleColor]::gray
                $valueStyle = ''
            }

            Write-Text `
                -Text "$indent$label", ': ', $value `
                -Color Gray, DarkGray, $valueColor `
                -Style Bold, None, $valueStyle
            continue
        }

        if ($line -match '^\s*(未知|未取得.*|未偵測.*)$') {
            Write-Text `
                -Text $line `
                -Color gray
            continue
        }

        if ($line -match '^\s{2,}') {
            Write-Text `
                -Text $line `
                -Color DarkGray
            continue
        }

        Write-Text `
            -Text $line `
            -Color White
    }
    Write-Text
}


function ConvertTo-PcMarkdown {
    <#
    .SYNOPSIS
    Converts PC hardware data to Markdown output.
    #>
    param (
        [Parameter(Mandatory)]
        [object]$Data
    )

    $lines = @()

    $lines += '# PC 硬體資訊中文解讀'
    $lines += ''
    $lines += "- report_timestamp：$($Data.report_timestamp)"
    $lines += ''
    $lines += '## 快速摘要'
    $lines += "- CPU：$(Format-PcDisplayValue $Data.cpu.name)"

    foreach ($gpu in @($Data.gpu.basic)) {
        $lines += "- GPU：$(Format-PcDisplayValue $gpu.name) ($(Format-PcDisplayValue $gpu.vendor))"
    }

    $lines += "- RAM：$(Format-PcNumber $Data.ram_summary.total_module_gb 2) GB / $($Data.ram_summary.module_count) 條"

    foreach ($disk in @($Data.storage.disks)) {
        $lines += "- 儲存裝置：$(Format-PcDisplayValue $disk.name) / $(Format-PcNumber $disk.size_gb 2) GB / $(Format-PcDisplayValue $disk.bus)"
    }

    if ($Data.os) {
        $lines += "- 系統：$(Format-PcDisplayValue $Data.os.name) / $(Format-PcDisplayValue $Data.os.arch)"
    }

    $lines += ''
    $lines += '## 電腦整體資訊'
    $lines += "- 製造商：$(Format-PcDisplayValue $Data.system.maker)"
    $lines += "- 型號：$(Format-PcDisplayValue $Data.system.model)"
    $lines += "- 系統類型：$(Format-PcDisplayValue $Data.system.type)"
    $lines += "- 系統記憶體總量：約 $(Format-PcNumber $Data.system.ram_gb 2) GB"

    $lines += ''
    $lines += '## 處理器 CPU'
    if ($Data.cpu) {
        $lines += "- CPU 1：$(Format-PcDisplayValue $Data.cpu.name)"
        $lines += "  - 製造商：$(Format-PcDisplayValue $Data.cpu.maker)"
        $lines += "  - 實體核心：$(Format-PcDisplayValue $Data.cpu.cores) 核"
        $lines += "  - 邏輯處理器：$(Format-PcDisplayValue $Data.cpu.threads) 執行緒"
        $lines += "  - WMI 標示最高時脈：$(Format-PcNumber $Data.cpu.max_mhz 0) MHz"
    }
    else {
        $lines += '- 未取得 CPU 資訊'
    }

    $lines += ''
    $lines += '## 顯示卡 GPU'
    $gpuIndex = 0
    foreach ($gpu in @($Data.gpu.basic)) {
        $gpuIndex++
        $lines += "- 顯示卡 ${gpuIndex}：$(Format-PcDisplayValue $gpu.name)"
        $lines += "  - GPU 廠牌：$(Format-PcDisplayValue $gpu.vendor)"
        $lines += "  - PCI Vendor ID：$(Format-PcDisplayValue $gpu.ven_id)"
        $lines += "  - 驅動版本：$(Format-PcDisplayValue $gpu.driver)"
        $lines += "  - 驅動日期：$(Format-PcDisplayValue $gpu.driver_date)"
        $lines += "  - GPU 處理器：$(Format-PcDisplayValue $gpu.chip)"
        $lines += "  - 目前影像模式：$(Format-PcDisplayValue $gpu.mode)"
        $lines += "  - WMI 回報顯示記憶體：$(Format-PcNumber $gpu.vram_gb 2) GB"
        $lines += "  - PNP Device ID：$(Format-PcDisplayValue $gpu.pnp_id)"
    }

    $lines += ''
    $lines += '### PCI / 顯示卡板卡識別'
    $pciIndex = 0
    foreach ($gpu in @($Data.gpu.pci)) {
        $pciIndex++
        $lines += "- 裝置 ${pciIndex}：$(Format-PcDisplayValue $gpu.name)"
        $lines += "  - GPU 晶片廠牌：$(Format-PcDisplayValue $gpu.vendor)"
        $lines += "  - 狀態：$(Format-PcDisplayValue $gpu.status)"
        $lines += "  - PCI Vendor ID：$(Format-PcDisplayValue $gpu.ven_id)"
        $lines += "  - PCI Device ID：$(Format-PcDisplayValue $gpu.dev_id)"
        $lines += "  - Subsystem ID：$(Format-PcDisplayValue $gpu.subsys_id)"
        $lines += "  - Subsystem Model：$(Format-PcDisplayValue $gpu.subsys_model)"
        $lines += "  - Subsystem Vendor：$(Format-PcDisplayValue $gpu.subsys_ven)"
        $lines += "  - 板卡 / OEM 廠牌判定：$(Format-PcDisplayValue $gpu.board_vendor)"
        $lines += "  - Hardware ID：$(Format-PcDisplayValue $gpu.hw_id)"
        $lines += "  - Instance ID：$(Format-PcDisplayValue $gpu.instance_id)"
        $lines += '  - Hardware IDs：'

        if (@($gpu.hw_ids).Count -eq 0) {
            $lines += '    - 未知'
        }
        else {
            foreach ($hardwareId in @($gpu.hw_ids)) {
                $lines += "    - $hardwareId"
            }
        }
    }

    $lines += ''
    $lines += '### NVIDIA 額外資訊'
    if (@($Data.gpu.nvidia).Count -eq 0) {
        $lines += '- 未取得 NVIDIA 額外資訊'
    }
    else {
        $nvidiaIndex = 0
        foreach ($gpu in @($Data.gpu.nvidia)) {
            $nvidiaIndex++
            $lines += "- NVIDIA GPU ${nvidiaIndex}：$(Format-PcDisplayValue $gpu.name)"
            $lines += "  - 驅動版本：$(Format-PcDisplayValue $gpu.driver)"
            $lines += "  - VBIOS：$(Format-PcDisplayValue $gpu.vbios)"
            $lines += "  - 顯示記憶體：$(Format-PcNumber $gpu.vram_mb 0) MB"
            $lines += "  - PCI Bus ID：$(Format-PcDisplayValue $gpu.bus_id)"
            $lines += "  - 目前核心時脈：$(Format-PcNumber $gpu.core_mhz 0) MHz"
            $lines += "  - 目前記憶體時脈：$(Format-PcNumber $gpu.mem_mhz 0) MHz"
            $lines += "  - 最大核心時脈：$(Format-PcNumber $gpu.max_core_mhz 0) MHz"
            $lines += "  - 最大記憶體時脈：$(Format-PcNumber $gpu.max_mem_mhz 0) MHz"
        }
    }

    $lines += ''
    $lines += '## 記憶體 RAM'
    $ramIndex = 0
    foreach ($module in @($Data.ram)) {
        $ramIndex++
        $lines += "- RAM $ramIndex"
        $lines += "  - 品牌：$(Format-PcDisplayValue $module.maker)"
        $lines += "  - 型號 / Part Number：$(Format-PcDisplayValue $module.part)"
        $lines += "  - 容量：$(Format-PcNumber $module.size_gb 2) GB"
        $lines += "  - 標示速度：$(Format-PcNumber $module.speed_mhz 0) MHz"
        $lines += "  - 目前設定速度：$(Format-PcNumber $module.clock_mhz 0) MHz"
    }
    $lines += "- RAM 模組數量：$($Data.ram_summary.module_count) 條"
    $lines += "- RAM 模組容量加總：約 $(Format-PcNumber $Data.ram_summary.total_module_gb 2) GB"

    $lines += ''
    $lines += '## 主機板'
    if ($Data.board) {
        $lines += "- 品牌：$(Format-PcDisplayValue $Data.board.maker)"
        $lines += "- 型號：$(Format-PcDisplayValue $Data.board.model)"
        $lines += "- 版本：$(Format-PcDisplayValue $Data.board.version)"
    }
    else {
        $lines += '- 未取得主機板資訊'
    }

    $lines += ''
    $lines += '## BIOS / UEFI'
    if ($Data.bios) {
        $lines += "- 廠商：$(Format-PcDisplayValue $Data.bios.maker)"
        $lines += "- BIOS 版本：$(Format-PcDisplayValue $Data.bios.version)"
        $lines += "- 發布日期：$(Format-PcDisplayValue $Data.bios.date)"
    }
    else {
        $lines += '- 未取得 BIOS / UEFI 資訊'
    }

    $lines += ''
    $lines += '## 儲存裝置'
    $lines += ''
    $lines += '### 實體磁碟'
    $diskIndex = 0
    foreach ($disk in @($Data.storage.disks)) {
        $diskIndex++
        $lines += "- 磁碟 ${diskIndex}：$(Format-PcDisplayValue $disk.name)"
        $lines += "  - 類型：$(Format-PcDisplayValue $disk.type)"
        $lines += "  - 匯流排：$(Format-PcDisplayValue $disk.bus)"
        $lines += "  - 容量：$(Format-PcNumber $disk.size_gb 2) GB"
        $lines += "  - 健康狀態：$(Format-PcDisplayValue $disk.health)"

        $statusText = if (@($disk.status).Count -gt 0) {
            @($disk.status) -join ', '
        }
        else {
            '未知'
        }
        $lines += "  - 運作狀態：$statusText"
    }

    $lines += ''
    $lines += '### Windows 磁碟型號'
    $modelIndex = 0
    foreach ($disk in @($Data.storage.models)) {
        $modelIndex++
        $lines += "- 磁碟 ${modelIndex}：$(Format-PcDisplayValue $disk.model)"
        $lines += "  - 介面：$(Format-PcDisplayValue $disk.bus)"
        $lines += "  - 媒體類型：$(Format-PcDisplayValue $disk.type)"
        $lines += "  - 容量：$(Format-PcNumber $disk.size_gb 2) GB"
    }

    $lines += ''
    $lines += '## 磁碟分割區 / 磁碟機'
    foreach ($volume in @($Data.volumes)) {
        $labelSuffix = if ([string]::IsNullOrWhiteSpace([string]$volume.label)) {
            ''
        }
        else {
            " $($volume.label)"
        }

        $lines += "- $($volume.drive):$labelSuffix"
        $lines += "  - 檔案系統：$(Format-PcDisplayValue $volume.fs)"
        $lines += "  - 總容量：$(Format-PcNumber $volume.size_gb 2) GB"
        $lines += "  - 剩餘空間：$(Format-PcNumber $volume.free_gb 2) GB"
        $lines += "  - 已使用：約 $(Format-PcNumber $volume.used_percent 1)%"
    }

    $lines += ''
    $lines += '## 螢幕'
    if (@($Data.monitors).Count -eq 0) {
        $lines += '- 未取得螢幕資訊'
    }
    else {
        $monitorIndex = 0
        foreach ($monitor in @($Data.monitors)) {
            $monitorIndex++
            $lines += "- 螢幕 ${monitorIndex}：$(Format-PcDisplayValue $monitor.maker) $(Format-PcDisplayValue $monitor.model)"
        }
    }

    $lines += ''
    $lines += '## Windows'
    if ($Data.os) {
        $lines += "- 系統：$(Format-PcDisplayValue $Data.os.name)"
        $lines += "- 版本：$(Format-PcDisplayValue $Data.os.version)"
        $lines += "- Build：$(Format-PcDisplayValue $Data.os.build)"
        $lines += "- 架構：$(Format-PcDisplayValue $Data.os.arch)"
    }
    else {
        $lines += '- 未取得 Windows 資訊'
    }

    $lines += ''
    $lines += '## 電池'
    if ($null -eq $Data.battery -or @($Data.battery).Count -eq 0) {
        $lines += '- 未偵測到電池資訊'
    }
    else {
        $batteryIndex = 0
        foreach ($item in @($Data.battery)) {
            $batteryIndex++
            $lines += "- 電池 ${batteryIndex}：$(Format-PcDisplayValue $item.name)"
            $lines += "  - 狀態：$(Format-PcDisplayValue $item.status)"
            $lines += "  - 預估剩餘電量：$(Format-PcDisplayValue $item.estimated_charge_remaining)%"
        }
    }

    return ($lines -join [Environment]::NewLine)
}


function ConvertTo-PcJson {
    <#
    .SYNOPSIS
    Converts PC hardware data to JSON output.
    #>
    param (
        [Parameter(Mandatory)]
        [object]$Data
    )

    return ($Data | ConvertTo-Json -Depth 12)
}


function Resolve-PcOutputPath {
    <#
    .SYNOPSIS
    Resolves the output file path for the selected report format.

    .DESCRIPTION
    An empty path uses the Desktop. A path whose extension matches the selected
    format is treated as a file path. Every other path is treated as a folder
    and receives the default PC_Hardware file name.
    #>
    param (
        [Parameter(Mandatory)]
        [ValidateSet('raw', 'md', 'json')]
        [string]$Format,

        [AllowEmptyString()]
        [string]$Path = ''
    )

    $extension = switch ($Format) {
        'raw' { '.txt' }
        'md' { '.md' }
        'json' { '.json' }
    }

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $folder = [Environment]::GetFolderPath('Desktop')
        if ([string]::IsNullOrWhiteSpace($folder)) {
            $folder = Join-Path $HOME 'Desktop'
        }

        $folder = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($folder)
        $filePath = Join-Path $folder "PC_Hardware$extension"
    }
    else {
        $resolvedInput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        $inputExtension = [IO.Path]::GetExtension($resolvedInput)

        if ($inputExtension -ieq $extension) {
            $filePath = $resolvedInput
            $folder = Split-Path -Parent $filePath
        }
        else {
            $folder = $resolvedInput
            $filePath = Join-Path $folder "PC_Hardware$extension"
        }
    }

    if (Test-Path -LiteralPath $filePath -PathType Container) {
        throw "Output path is a directory, but the selected format requires a file: $filePath"
    }

    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        New-Item `
            -ItemType Directory `
            -Path $folder `
            -Force `
            -ErrorAction Stop |
            Out-Null
    }

    return $filePath
}


function Write-PcUtf8NoBom {
    <#
    .SYNOPSIS
    Writes report text as UTF-8 without a byte-order mark.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Content, $encoding)
}


function info {
    <#
    .SYNOPSIS
    Shows or saves a complete PC hardware report.

    .DESCRIPTION
    Collects PC hardware and Windows information once and renders the same
    report data as RAW text, Markdown, or JSON.

    Format controls the output format and defaults to raw. Without -File/-f,
    the selected format is written to the console. RAW console output uses
    MowPSKit colors for readability while Markdown and JSON are printed as-is.

    The command also supports the PowerShell success pipeline. When info is
    followed by another pipeline command, the selected report is emitted as
    plain report text instead of being rendered through Write-Text. This keeps
    RAW output free of console colors and allows Markdown and JSON to be passed
    directly to commands such as Set-Clipboard, Set-Content, or ConvertFrom-Json.

    With -File/-f, the selected format is written to a file instead of printing
    the complete report. If no Path is supplied, the file is created on the
    current user's Desktop. When Path has the extension that belongs to the
    selected format, Path is treated as the complete file name. Otherwise,
    Path is treated as a directory and the default PC_Hardware file name is
    used inside that directory.

    RAW files use .txt, Markdown files use .md, and JSON files use .json.
    File output is written as UTF-8 without a BOM. After a successful file
    write, only a standardized success message from Write-Status and the
    resulting path from Write-Text are shown. When -File/-f is used in a
    pipeline, host status output is suppressed and only the resulting file path
    is emitted to the success pipeline.

    The report keeps one report_timestamp value shared by every section and
    includes the combined information used by the RAW, Markdown, and JSON
    representations, including detailed PCI hardware IDs, NVIDIA information
    when nvidia-smi is available, RAM module totals, and volume usage values.

    This function requires Windows and depends on the MowPSKit Write-Text and
    Write-Status commands for console output.

    .PARAMETER Format
    Specifies the report format.

    Accepted values are raw, md, and json. The default is raw.

    raw produces plain text without Markdown syntax. md produces Markdown.
    json produces JSON.

    .PARAMETER File
    Writes the selected Format to a file instead of displaying the complete
    report in the console.

    The short alias is -f.

    When File is present without Path, the report is written to the Desktop.

    .PARAMETER Path
    Specifies an optional output file or directory for -File/-f.

    If the supplied path ends with the extension that belongs to Format, it is
    treated as a file path. Otherwise it is treated as a directory. Missing
    directories are created automatically.

    Path follows normal PowerShell parsing rules. Paths containing spaces must
    therefore be quoted.

    This positional parameter is intended to be used after -f, for example:
    info -f D:\Reports

    .EXAMPLE
    info

    Displays the complete report as RAW text in the console.

    .EXAMPLE
    info -Format md

    Displays the complete report as Markdown in the console.

    .EXAMPLE
    info -Format json

    Displays the complete report as JSON in the console.

    .EXAMPLE
    info -f

    Uses the default raw format and writes PC_Hardware.txt to the Desktop.
    Only the success message and resulting path are displayed.

    .EXAMPLE
    info -Format md -f D:\Reports

    Writes D:\Reports\PC_Hardware.md. The supplied path is treated as a
    directory because it does not end in .md.

    .EXAMPLE
    info -Format json -f D:\Reports\MyPC.json

    Writes the JSON report directly to D:\Reports\MyPC.json.

    .EXAMPLE
    info -Format raw -f "D:\PC Reports\Office-PC.txt"

    Writes RAW text to the specified file. Quotation marks are required here
    because the path contains a space.

    .EXAMPLE
    info | Set-Clipboard

    Sends plain RAW report text through the success pipeline to Set-Clipboard.
    Console colors are not included in the piped value.

    .EXAMPLE
    info -Format json | ConvertFrom-Json

    Sends the JSON report through the success pipeline and parses it back into
    a PowerShell object.

    .EXAMPLE
    info -Format md -f D:\Reports | Get-Item

    Writes D:\Reports\PC_Hardware.md and sends only the resulting path through
    the success pipeline to Get-Item.

    .OUTPUTS
    System.String

    Without -File/-f in a pipeline, outputs the selected report as one string.
    With -File/-f in a pipeline, outputs the resulting file path as one string.
    Direct interactive invocation renders through Write-Text/Write-Status and
    does not write report content to the success pipeline.
    #>
    [CmdletBinding()]
    param (
        [ValidateSet('raw', 'md', 'json')]
        [string]$Format = 'raw',

        [Alias('f')]
        [switch]$File,

        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [string]$Path
    )

    begin {
        $isPipeline = $MyInvocation.PipelineLength -gt 1
    }

    end {
        if ($PSBoundParameters.ContainsKey('Path') -and -not $File) {
            throw 'Path can only be used together with -File or -f.'
        }

        $data = Get-PcHardwareData

        $content = switch ($Format) {
            'raw' {
                ConvertTo-PcRaw $data
            }

            'md' {
                ConvertTo-PcMarkdown $data
            }

            'json' {
                ConvertTo-PcJson $data
            }
        }

        if (-not $File) {
            if ($isPipeline) {
                # Emit one clean string to the success pipeline. Do not use
                # Write-Text here because it is a Write-Host based renderer.
                Write-Output -NoEnumerate $content
                return
            }

            if ($Format -eq 'raw') {
                Write-PcRawConsole -Content $content
            }
            else {
                Write-Text -Text $content
            }
            return
        }

        $outputPath = Resolve-PcOutputPath `
            -Format $Format `
            -Path $Path

        Write-PcUtf8NoBom `
            -Path $outputPath `
            -Content $content

        if ($isPipeline) {
            # File mode pipes only the final path so downstream commands never
            # receive status/decorative console text.
            Write-Output -NoEnumerate $outputPath
            return
        }

        $formatLabel = switch ($Format) {
            'raw' { 'RAW' }
            'md' { 'MD' }
            'json' { 'JSON' }
        }

        Write-Status `
            -Type Success `
            -Message "$formatLabel 產生成功"

        Write-Text `
            -Text $outputPath `
            -Color DarkGray
    }
}
