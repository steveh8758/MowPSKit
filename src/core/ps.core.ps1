

function Test-Pipeline {
    <#
    .SYNOPSIS
    Checks whether the caller has downstream pipeline output.

    .DESCRIPTION
    Determines whether the calling command is connected to another command
    through the PowerShell pipeline.

    .PARAMETER Invocation
    The caller's $MyInvocation object.

    .OUTPUTS
    System.Boolean
    #>
    param(
        [System.Management.Automation.InvocationInfo]$Invocation
    )

    return (
        $Invocation.PipelineLength -gt 1 -and
        $Invocation.PipelinePosition -lt $Invocation.PipelineLength
    )
}
