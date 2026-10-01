$MowExports = 'all'


function kill-adobe {
    param(
        [Alias('f')]
        [switch]$Force
    )

    if ($Force) {
        Get-Process |
            Where-Object {
                $_.Path -like '*\Adobe\*' -or
                $_.Company -like '*Adobe*'
            } |
            Stop-Process -Force -ErrorAction SilentlyContinue

        return
    }

    @(
        'AdobeIPCBroker'
        'Creative Cloud'
        'CCXProcess'
        'CoreSync'
        'Adobe Desktop Service'
        'AdobeGCInvokerUtility'
        'AdobeCollabSync'
    ) |
        ForEach-Object {
            Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue
        }
}