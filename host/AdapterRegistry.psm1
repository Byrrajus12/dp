Set-StrictMode -Version Latest

function New-AdapterRegistry {
    return @{}
}

function Register-HostAdapter {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Registry,

        [Parameter(Mandatory = $true)]
        [hashtable] $Adapter
    )

    foreach ($member in @('Name', 'Context', 'Start', 'Stop', 'Poll', 'HandleCommand')) {
        if (-not $Adapter.ContainsKey($member)) {
            throw "Adapter is missing required member '$member'."
        }
    }

    $name = [string] $Adapter.Name
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw 'Adapter Name cannot be empty.'
    }
    if ($Registry.ContainsKey($name)) {
        throw "Adapter '$name' is already registered."
    }

    $Registry[$name] = $Adapter
}

function Invoke-HostMessageRoute {
    param(
        [Parameter(Mandatory = $true)][hashtable] $Registry,
        [Parameter(Mandatory = $true)] $Message
    )

    $typeProperty = $Message.PSObject.Properties['type']
    $targetProperty = $Message.PSObject.Properties['target']
    if ($null -eq $typeProperty -or [string]::IsNullOrWhiteSpace([string] $typeProperty.Value)) {
        throw 'Incoming message is missing type.'
    }
    if ($null -eq $targetProperty -or [string]::IsNullOrWhiteSpace([string] $targetProperty.Value)) {
        return $null
    }

    $target = [string] $targetProperty.Value
    if (-not $Registry.ContainsKey($target)) {
        throw "No adapter is registered for target '$target'."
    }

    $adapter = $Registry[$target]
    return & $adapter.HandleCommand $adapter.Context $Message
}

Export-ModuleMember -Function @(
    'New-AdapterRegistry',
    'Register-HostAdapter',
    'Invoke-HostMessageRoute'
)
