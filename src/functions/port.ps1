$MowExports = 'all'


function fp([int]$Port) {
    <#
    .SYNOPSIS
    Shows processes listening on a local TCP port.

    .DESCRIPTION
    Queries listening TCP connections for the specified local port and builds one row per matching connection containing the local address, local port, owning process ID, process name, and command line.

    The function uses Test-Pipeline with $MyInvocation to choose its output mode. When Test-Pipeline reports that the function is being used in a pipeline, the generated row objects are written directly to the pipeline. Otherwise, the results are rendered using Write-Text and Write-Table.

    If no listening connection is found, the function returns without producing rows. In non-pipeline mode, it first reports that the port is free by calling Write-Status.

    Errors from Get-NetTCPConnection and Get-Process are suppressed. Errors from Get-CimInstance are not explicitly suppressed or caught and can therefore be reported by PowerShell.

    Process names can be empty when Get-Process cannot resolve an owning process. Command-line information is obtained separately through Win32_Process.

    This function depends on Get-NetTCPConnection, Get-CimInstance with the Win32_Process class, and the custom Test-Pipeline, Write-Status, Write-Text, and Write-Table commands being available.

    .PARAMETER Port
    Specifies the local TCP port to inspect.

    The parameter is an Int32 and has no explicit validation or range restriction in the function. If omitted, its value is the default Int32 value of 0.

    .EXAMPLE
    fp 3000

    Displays the processes listening on local TCP port 3000 using the function's formatted table output.

    .EXAMPLE
    fp 8080 | Select-Object ProcessName, CommandLine

    When Test-Pipeline identifies pipeline usage, returns the matching connection rows as objects so their properties can be processed by other PowerShell commands.

    .EXAMPLE
    fp 5432

    Checks TCP port 5432. If no listening connection is found, reports that the port is free in non-pipeline mode.
    #>
    $piped = Test-Pipeline $MyInvocation

    $conn = Get-NetTCPConnection `
        -LocalPort $Port `
        -State Listen `
        -ErrorAction SilentlyContinue

    if (-not $conn) {
        if (-not $piped) {
            Write-Status `
                -Type Success `
                -Message "Port $Port is free."
        }

        return
    }

    $rows = $conn |
        Select-Object `
            LocalAddress,
            LocalPort,
            OwningProcess,
            @{
                Name = 'ProcessName'
                Expression = {
                    (
                        Get-Process `
                            -Id $_.OwningProcess `
                            -ErrorAction SilentlyContinue
                    ).ProcessName
                }
            },
            @{
                Name = 'CommandLine'
                Expression = {
                    (
                        Get-CimInstance `
                            Win32_Process `
                            -Filter "ProcessId = $($_.OwningProcess)"
                    ).CommandLine
                }
            }

    if ($piped) {
        $rows
        return
    }

    Write-Text `
        -Text 'Listening on port ', "$Port", ':' `
        -Color DarkGray, Cyan, DarkGray `
        -Style None, Bold, None `
        -LinesAfter 1

    $rows |
        Write-Table `
            -Color @{
                LocalPort   = 'Cyan'
                ProcessName = 'Yellow'
            } `
            -Align @{
                LocalPort     = 'Right'
                OwningProcess = 'Right'
            }
    Write-Text ""
}


function kp([int]$Port) {
    <#
    .SYNOPSIS
    Forcibly terminates processes listening on a local TCP port.

    .DESCRIPTION
    Finds listening TCP connections for the specified local port, extracts their unique owning process IDs, and attempts to terminate each process with Stop-Process -Force.

    Each process is handled independently. A successful termination is reported with Write-Status. If Stop-Process fails, the exception is caught, an error status is reported, and processing continues with any remaining process IDs.

    If no process IDs are returned, the function reports that the port is free and returns.

    Get-NetTCPConnection errors are suppressed with -ErrorAction SilentlyContinue. As a result, if the connection query fails and produces no process IDs, the function follows the same path as when no listener exists and reports that the port is free.

    This function has the side effect of forcibly terminating every distinct process owning a listening connection returned for the specified local port.

    The function depends on Get-NetTCPConnection and the custom Write-Status command being available.

    .PARAMETER Port
    Specifies the local TCP port whose listening processes are to be terminated.

    The parameter is an Int32 and has no explicit validation or range restriction in the function. If omitted, its value is the default Int32 value of 0.

    .EXAMPLE
    kp 3000

    Finds every distinct process listening on local TCP port 3000 and forcibly terminates each one.

    .EXAMPLE
    kp 8080

    Attempts to terminate all processes listening on port 8080. If a process cannot be terminated, reports the failure and continues processing any other matching process IDs.

    .EXAMPLE
    kp 5432

    Checks for listeners on port 5432. If no owning process IDs are returned, reports that the port is free.
    #>
    $processIds = Get-NetTCPConnection `
        -LocalPort $Port `
        -State Listen `
        -ErrorAction SilentlyContinue |
        Select-Object `
            -ExpandProperty OwningProcess `
            -Unique

    if (-not $processIds) {
        Write-Status `
            -Type Success `
            -Message "Port $Port is free."

        return
    }

    foreach ($processId in $processIds) {
        try {
            Stop-Process `
                -Id $processId `
                -Force `
                -ErrorAction Stop

            Write-Status `
                -Type Success `
                -Message "Killed PID $processId on port $Port."
        }
        catch {
            Write-Status `
                -Type Error `
                -Message "Failed to kill PID ${processId}: $($_.Exception.Message)"
        }
    }
}
