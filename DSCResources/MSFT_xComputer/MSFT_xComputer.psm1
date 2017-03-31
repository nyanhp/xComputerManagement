#
# xComputer: DSC resource to rename a computer and add it to a domain or
# workgroup.
#

function Get-TargetResource
{
    [OutputType([System.Collections.Hashtable])]
    param
    (
        [parameter(Mandatory)]
        [ValidateLength(1, 15)]
        [ValidateScript( {$_ -inotmatch '[\/\\:*?"<>|]' })]
        [string]
        $Name,
    
        [string]
        $DomainName,

        [string]
        $JoinOU,
        
        [PSCredential]
        $Credential,

        [PSCredential]
        $UnjoinCredential,

        [string]
        $WorkGroupName,

        [string]
        $Description
    )

    $convertToCimCredential = New-CimInstance -ClassName MSFT_Credential -Property @{Username = [string]$Credential.UserName; Password = [string]$null} -Namespace root/microsoft/windows/desiredstateconfiguration -ClientOnly
    $convertToCimUnjoinCredential = New-CimInstance -ClassName MSFT_Credential -Property @{Username = [string]$UnjoinCredential.UserName; Password = [string]$null} -Namespace root/microsoft/windows/desiredstateconfiguration -ClientOnly

    $returnValue = @{
        Name = $env:COMPUTERNAME
        DomainName = GetComputerDomain
        JoinOU = $JoinOU
        CurrentOU = Get-ComputerOU
        Credential = [ciminstance]$convertToCimCredential
        UnjoinCredential = [ciminstance]$convertToCimUnjoinCredential
        WorkGroupName = (Get-WmiObject -Class WIN32_ComputerSystem).WorkGroup
        Description = (Get-CimInstance -ClassName WIN32_OperatingSystem).Description
    }

    $returnValue
}

function Set-TargetResource
{
    param
    (
        [parameter(Mandatory)]
        [ValidateLength(1, 15)]
        [ValidateScript( {$_ -inotmatch '[\/\\:*?"<>|]' })]
        [string]
        $Name,
    
        [string]
        $DomainName,

        [string]
        $JoinOU,
        
        [PSCredential]
        $Credential,

        [PSCredential]
        $UnjoinCredential,

        [string]
        $WorkGroupName,

        [string]
        $Description
    )

    ValidateDomainOrWorkGroup -DomainName $DomainName -WorkGroupName $WorkGroupName
    
    if ($Name -eq 'localhost') 
    {
        $Name = $env:COMPUTERNAME
    }

    if ($Credential) 
    {
        if ($DomainName) 
        {
            if ($DomainName -eq (GetComputerDomain)) 
            {
                # Rename the computer, but stay joined to the domain.
                Rename-Computer -NewName $Name -DomainCredential $Credential -Force
                Write-Verbose -Message "Renamed computer to '$($Name)'."
            }
            else 
            {
                # Rename the computer, and join it to the domain.
                $parameterSet = @{
                    DomainName = $DomainName
                    Credential = $Credential                        
                    Force = $true
                }

                if ($Name -ne $env:COMPUTERNAME) 
                {
                    $parameterSet.Add('NewName', $Name)
                }
                        
                if ($UnjoinCredential) 
                {
                    $parameterSet.Add('UnjoinDomainCredential', $UnjoinCredential)
                }

                if ($JoinOU)
                {
                    $parameterSet.Add('OUPath', $JoinOU)
                }
                    
                Add-Computer @parameterSet
                if ($Name -ne $env:COMPUTERNAME) 
                {
                    Write-Verbose -Message "Renamed computer to '$($Name)' and added to the domain '$($DomainName)."
                }
                else 
                {
                    Write-Verbose -Message "Joined computer '$Name' to the domain '$DomainName"
                }            
            }

            if (-not [string]::IsNullOrWhiteSpace($Description) -and $PSBoundParameters.ContainsKey('PsDscRunAsCredential'))
            {
                # Set description in Active Directory
                $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().GetDirectoryEntry()
                $searcher = [System.DirectoryServices.DirectorySearcher] $domain

                # Set the search filter to an LDAP query for this machine's computer name
                $searcher.Filter = "(sAMAccountName=$Name`$)"            
                $results = $searcher.FindAll()

                $result = $results | Select-Object -First 1
                if ($result.Properties.Contains('description'))
                {
                    $null = $result.Properties['Description'].Add($Description)
                    $null = $result.CommitChanges()
                    Write-Verbose -Message "Successfully set description of computer object to $Description"
                }
            }
        }
        elseif ($WorkGroupName) 
        {
            if ($WorkGroupName -eq (Get-WmiObject -Class win32_computersystem).WorkGroup) 
            {
                # Rename the computer, but stay in the same workgroup.
                Rename-Computer -NewName $Name
                Write-Verbose -Message "Renamed computer to '$($Name)'."
            }
            else 
            {
                $parameterSet = @{
                    Credential = $Credential
                    WorkGroupName = $WorkGroupName
                    Force = $true
                }

                if ($Name -ne $env:COMPUTERNAME) 
                {
                    $parameterSet.Add('NewName', $Name)
                }
                
                # Same computer name, and join it to the workgroup.
                Add-Computer @parameterSet
                Write-Verbose -Message "Added computer to workgroup '$($WorkGroupName)'."
            }
        }
        elseif ($Name -ne $env:COMPUTERNAME) 
        {
            $parameterSet = @{
                NewName = $Name
                Force = $true
            }

            if (GetComputerDomain) 
            {
                $parameterSet.Add('DomainCredential', $Credential)
            }
            
            Rename-Computer -NewName $Name -Force
            Write-Verbose -Message "Renamed computer to '$($Name)'."
        }
    }
    else 
    {
        if ($DomainName) 
        {
            throw "Missing domain join credentials."
        }

        if (-not $WorkGroupName)
        {
            if ($Name -ne $env:COMPUTERNAME)
            {
                Rename-Computer -NewName $Name
                Write-Verbose -Message "Renamed computer to '$($Name)'."
                $global:DSCMachineStatus = 1
            }
            return
        }
        
        if ($WorkGroupName -eq (Get-WmiObject -Class win32_computersystem).Workgroup)
        {
            # Same workgroup, new computer name
            Rename-Computer -NewName $Name -force
            Write-Verbose -Message "Renamed computer to '$($Name)'."
            $global:DSCMachineStatus = 1
            return
        }
        
        $addParameters = @{
            WorkGroupName = $WorkGroupName
        }
        if ($name -ne $env:COMPUTERNAME)
        {
            $addParameters.Add('NewName', $Name)
        }

        Add-Computer @addParameters

        Write-Verbose -Message "'$($Name)' added to workgroup '$($WorkGroupName)'."
        $global:DSCMachineStatus = 1
        return        
    }

    if (-not [string]::IsNullOrWhiteSpace($Description))
    {
        Get-CimInstance -ClassName Win32_OperatingSystem | Set-CimInstance -Property @{
            'Description' = $Description;
        }
    }

    $global:DSCMachineStatus = 1
}

function Test-TargetResource
{
    [OutputType([System.Boolean])]
    [CmdletBinding()]
    param
    (
        [parameter(Mandatory)]
        [ValidateLength(1, 15)]
        [ValidateScript( {$_ -inotmatch '[\/\\:*?"<>|]' })]
        [string]
        $Name,
    
        [string]
        $DomainName,

        [string]
        $JoinOU,
        
        [PSCredential]
        $Credential,

        [PSCredential]
        $UnjoinCredential,

        [string]
        $WorkGroupName,

        [string]
        $Description
    )
    
    Write-Verbose -Message 'Getting current values'
    $currentValues = Get-TargetResource @PSBoundParameters

    if ($null -eq $currentValues)
    {
        return $false
    }

    Write-Verbose -Message "Validate desired Name is a valid name"
    
    Write-Verbose -Message "Checking if computer name is correct"
    if (($Name -ne 'localhost') -and ($Name -ne $currentValues.Name)) {return $false}

    if ($PSBoundParameters.ContainsKey('Description') -and $currentValues.Description -ne $Description)
    {
        return $false
    }

    ValidateDomainOrWorkGroup -DomainName $DomainName -WorkGroupName $WorkGroupName

    if ($DomainName)
    {
        if (-not ($Credential))
        {
            throw "Need to specify credentials with domain"
        }
        
        try
        {
            Write-Verbose "Checking if the machine is a member of $DomainName."
            return ($DomainName.ToLower() -eq $currentValues.DomainName.ToLower())
        }
        catch
        {
            Write-Verbose 'The machine is not a domain member.'
            return $false
        }
    }
    elseif ($WorkGroupName)
    {
        Write-Verbose -Message "Checking if workgroup name is $WorkGroupName"
        return ($WorkGroupName -eq $currentValues.WorkGroupName)
    }
    else
    {
        ## No Domain or Workgroup specified and computer name is correct
        return $true;
    }
}

function ValidateDomainOrWorkGroup($DomainName, $WorkGroupName)
{
    if ($DomainName -and $WorkGroupName)
    {
        throw "Only DomainName or WorkGroupName can be specified at once."
    }
}

function GetComputerDomain
{
    try
    {
        return ([System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()).Name
    }
    catch [System.Management.Automation.MethodInvocationException]
    {
        Write-Debug 'This machine is not a domain member.'
    }
}

function Get-ComputerOU
{
    $ou = $null

    if (GetComputerDomain)
    {
        $dn = $null
        $dn = ([adsisearcher]"(&(objectCategory=computer)(objectClass=computer)(cn=$env:COMPUTERNAME))").FindOne().Properties.distinguishedname
        $ou = $dn -replace '^(CN=.*?(?<=,))', ''
    }

    return $ou
}

Export-ModuleMember -Function *-TargetResource
