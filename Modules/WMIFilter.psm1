#Requires -Version 5.1
<#
.SYNOPSIS
    WMI-Filter-Management via ActiveDirectory-Modul (msWMI-Som Objekte).
.DESCRIPTION
    WMI-Filter sind AD-Objekte unter CN=SOM,CN=WMIPolicy,CN=System,<DomainDN>
    vom Typ msWMI-Som. Erstellt via New-ADObject statt GPMC COM (robuster).

    Query-Format msWMI-Parm2:
      <FilterCount>;<IDLength>;<ID>;<QueryLength>;WQL;<Namespace>;<Query>;
      Mehrere Filter werden mit mehreren Bloecken verkettet.
#>

function Test-ADModule {
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        throw "ActiveDirectory Modul fehlt (RSAT-AD-PowerShell installieren)."
    }
    Import-Module ActiveDirectory -ErrorAction Stop
}

function ConvertTo-WQLQuery {
    <#
    .SYNOPSIS
        Generiert WQL-Query aus Filter-Typ + Muster.
    .PARAMETER Type
        'Prefix' | 'Pattern' | 'List' | 'Custom'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Prefix','Pattern','List','Custom')]
        [string]$Type,

        [Parameter(Mandatory)][string]$Value
    )
    switch ($Type) {
        'Prefix'  { return "SELECT * FROM Win32_ComputerSystem WHERE Name LIKE '$($Value.TrimEnd('%'))%'" }
        'Pattern' { return "SELECT * FROM Win32_ComputerSystem WHERE Name LIKE '$Value'" }
        'List'    {
            $names = $Value -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            if ($names.Count -eq 0) { throw 'Leere Name-Liste' }
            $ors = ($names | ForEach-Object { "Name = '$_'" }) -join ' OR '
            return "SELECT * FROM Win32_ComputerSystem WHERE $ors"
        }
        'Custom'  { return $Value }
    }
}

function Format-WMIFilterQueryParm2 {
    <#
    .SYNOPSIS
        Encodet WQL-Query in das AD-msWMI-Parm2 Format.
    .DESCRIPTION
        Format: "1;3;<NSLen>;<QLen>;WQL;<Namespace>;<Query>;"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [string]$Namespace = 'root\CIMv2'
    )
    # WQL erwartet einfache Anfuehrungszeichen - doppelte konvertieren
    $Query = $Query -replace '"', "'"
    $nsLen = $Namespace.Length
    $qLen  = $Query.Length
    return '1;3;{0};{1};WQL;{2};{3};' -f $nsLen, $qLen, $Namespace, $Query
}

function Get-WMIFilterContainer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DomainFQDN,
        [string]$Server
    )
    Test-ADModule
    $domain = if ($Server) { Get-ADDomain -Server $Server } else { Get-ADDomain -Identity $DomainFQDN }
    return "CN=SOM,CN=WMIPolicy,CN=System,$($domain.DistinguishedName)"
}

function Get-WMIFilter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DomainFQDN,
        [string]$Server,
        [string]$Name
    )
    Test-ADModule
    $container = Get-WMIFilterContainer -DomainFQDN $DomainFQDN -Server $Server
    $params = @{
        SearchBase = $container
        LDAPFilter = '(objectClass=msWMI-Som)'
        Properties = 'msWMI-Name','msWMI-Parm1','msWMI-Parm2','msWMI-ID','msWMI-Author','whenCreated','whenChanged'
    }
    if ($Server) { $params.Server = $Server }
    $objs = Get-ADObject @params -ErrorAction Stop
    $result = foreach ($o in $objs) {
        [PSCustomObject]@{
            Name              = $o.'msWMI-Name'
            Id                = $o.'msWMI-ID'
            Description       = $o.'msWMI-Parm1'
            QueryRaw          = $o.'msWMI-Parm2'
            Author            = $o.'msWMI-Author'
            Created           = $o.whenCreated
            Modified          = $o.whenChanged
            DistinguishedName = $o.DistinguishedName
        }
    }
    if ($Name) { $result = $result | Where-Object { $_.Name -eq $Name } }
    return $result
}

function New-WMIFilter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DomainFQDN,
        [string]$Server,
        [Parameter(Mandatory)][string]$Name,
        [string]$Description = '',
        [Parameter(Mandatory)][string]$Query,
        [string]$Namespace = 'root\CIMv2'
    )
    Test-ADModule
    # Duplikat-Check
    $existing = Get-WMIFilter -DomainFQDN $DomainFQDN -Server $Server -Name $Name
    if ($existing) { throw "WMI-Filter '$Name' existiert bereits (Id: $($existing.Id))." }

    $container = Get-WMIFilterContainer -DomainFQDN $DomainFQDN -Server $Server
    $id        = '{' + [Guid]::NewGuid().ToString().ToUpper() + '}'
    $parm2     = Format-WMIFilterQueryParm2 -Query $Query -Namespace $Namespace
    $author    = "$env:USERNAME@$env:USERDNSDOMAIN"
    if (-not $env:USERDNSDOMAIN) { $author = "$env:USERDOMAIN\$env:USERNAME" }

    # String-Format wie Windows-GPMC: yyyyMMddHHmmss.ffffff-000 (6-stellige Bruchteilsekunden + Timezone-Offset)
    $nowStr = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss.ffffff') + '-000'
    $attrs = @{
        'msWMI-Name'         = $Name
        'msWMI-Parm1'        = $Description
        'msWMI-Parm2'        = $parm2
        'msWMI-ID'           = $id
        'msWMI-Author'       = $author
        'msWMI-ChangeDate'   = $nowStr
        'msWMI-CreationDate' = $nowStr
        'showInAdvancedViewOnly' = $true
    }
    $params = @{
        Name           = $id
        Type           = 'msWMI-Som'
        Path           = $container
        OtherAttributes = $attrs
    }
    if ($Server) { $params.Server = $Server }
    $null = New-ADObject @params -ErrorAction Stop

    return (Get-WMIFilter -DomainFQDN $DomainFQDN -Server $Server -Name $Name)
}

function Remove-WMIFilter {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$DomainFQDN,
        [string]$Server,
        [Parameter(Mandatory)][string]$Name
    )
    Test-ADModule
    $f = Get-WMIFilter -DomainFQDN $DomainFQDN -Server $Server -Name $Name
    if (-not $f) { throw "WMI-Filter '$Name' nicht gefunden." }
    if ($PSCmdlet.ShouldProcess($f.DistinguishedName, 'Remove-ADObject')) {
        $params = @{ Identity = $f.DistinguishedName; Confirm = $false }
        if ($Server) { $params.Server = $Server }
        Remove-ADObject @params -ErrorAction Stop
    }
}

function Remove-WMIFilterByPrefix {
    <#
    .SYNOPSIS
        Entfernt alle WMI-Filter mit einem bestimmten Name-Prefix.
        Nuetzlich zum Cleanup alter kaputter Filter.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$DomainFQDN,
        [string]$Server,
        [Parameter(Mandatory)][string]$Prefix
    )
    Test-ADModule
    $filters = Get-WMIFilter -DomainFQDN $DomainFQDN -Server $Server |
               Where-Object { $_.Name -like "$Prefix*" }
    $removed = @()
    foreach ($f in $filters) {
        $params = @{ Identity = $f.DistinguishedName; Confirm = $false }
        if ($Server) { $params.Server = $Server }
        try {
            Remove-ADObject @params -ErrorAction Stop
            $removed += $f.Name
        } catch {
            Write-Warning "Remove $($f.Name): $_"
        }
    }
    return $removed
}

function Set-WMIFilterOnGPO {
    <#
    .SYNOPSIS
        Verknuepft WMI-Filter mit GPO via Set-ADObject auf gPCWQLFilter.
        GPMC-COM-Wege (SearchWMIFilters.Item / GetWMIFilter) sind in PS fragil.
    .PARAMETER WMIFilterName
        Name. Null/leer = Filter entfernen (gPCWQLFilter clearen).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DomainFQDN,
        [string]$Server,
        [Parameter(Mandatory)][string]$GPOName,
        [string]$WMIFilterName
    )
    Test-ADModule
    Import-Module GroupPolicy -ErrorAction Stop

    $gpoParams = @{ Name = $GPOName; Domain = $DomainFQDN }
    if ($Server) { $gpoParams.Server = $Server }
    $gpo = Get-GPO @gpoParams -ErrorAction Stop

    $gpoDN = "CN={$($gpo.Id.Guid)},CN=Policies,CN=System," +
             ('DC=' + ($DomainFQDN -replace '\.', ',DC='))

    $adParams = @{ Identity = $gpoDN }
    if ($Server) { $adParams.Server = $Server }

    if (-not $WMIFilterName) {
        # Clear
        Set-ADObject @adParams -Clear gPCWQLFilter -ErrorAction Stop
        return
    }

    $f = Get-WMIFilter -DomainFQDN $DomainFQDN -Server $Server -Name $WMIFilterName
    if (-not $f) { throw "WMI-Filter '$WMIFilterName' nicht in AD gefunden." }

    # Format: [DomainFQDN;{FilterGUID};0]  - $f.Id enthaelt bereits {GUID}
    $value = '[{0};{1};0]' -f $DomainFQDN, $f.Id

    Set-ADObject @adParams -Replace @{ gPCWQLFilter = $value } -ErrorAction Stop

    # Verify
    Start-Sleep -Milliseconds 300
    $verifyParams = @{ Identity = $gpoDN; Properties = 'gPCWQLFilter' }
    if ($Server) { $verifyParams.Server = $Server }
    $check = Get-ADObject @verifyParams
    if (-not $check.gPCWQLFilter -or $check.gPCWQLFilter -notmatch [regex]::Escape($f.Id)) {
        throw "gPCWQLFilter-Set hat nicht persistiert."
    }
}

# Funktionen exportieren (nur wenn als Modul geladen; bei dot-source automatisch sichtbar)
if ($ExecutionContext.SessionState.Module) {
Export-ModuleMember -Function Test-ADModule, ConvertTo-WQLQuery, Remove-WMIFilterByPrefix, `
                              Format-WMIFilterQueryParm2, `
                              Get-WMIFilterContainer, Get-WMIFilter, `
                              New-WMIFilter, Remove-WMIFilter, `
                              Set-WMIFilterOnGPO
}
