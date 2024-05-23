#IP Addresses of vCenter 
$prodVCSA = <production VCSA>
$drVCSA = <dr VCSA>

#Initializes Hashtable for Hosts and VMs
$HostIDTable = @{}
$VMIDTable = @{}

$readyState = "Connected"
$verifyCount = 0

#Presents user with a menu to select the location they would like to run the code against
cls
Write-Host "`n`n`n################################`n" -ForegroundColor Cyan
Write-Host "   Enter number for site" -ForegroundColor Cyan
Write-Host "   1. Prod" -ForegroundColor Cyan
Write-Host "   2. DR`n" -ForegroundColor Cyan
Write-Host "################################`n" -ForegroundColor Cyan

$num = read-host "Enter Selection"

switch($num){
    1 {cls;$vcsa = $prodVCSA;"`n`nStarting at PROD`n"}
    2 {cls;$vcsa = $drVCSA;"`n`nStarting DR`n"}
    Default{
        cls
        Write-Host "`n`n`n################################`n" -ForegroundColor Yellow
        Write-Host "            Exiting" -ForegroundColor Yellow
        Write-Host "`n################################`n" -ForegroundColor Yellow

        Start-Sleep -Seconds 2
        break
    }
}

#Connects to vCenter Server from your selection
Connect-VIServer -Server $vcsa

#Queries vCenter for each host and the ID assigned to it and inserts that information into the $HostIDTable hashtable
Get-VMHost | Select-Object -Property Name,ID | Sort-Object | ForEach-Object {$HostIDTable[$_.Id] = $_.name}

#Queries vCenter server for All VMs and what host they are on and inserts that information into the $VMIDTable hashtable
Get-VM | Select-Object -Property Name,VMHostId | ForEach-Object {$VMIDTable[$_.Name] = $_.VMHostId}


foreach($h in $HostIDTable.Values){
       
    $j = 0
    $destHosts = $HostIDTable.Values | where {$_ -ne $h}
    
    #Gets the currently hosted VM's of the current host
    $vms = get-vmhost -Name $h | Get-VM
    
    #Moves VMs to other hosts besides the current one in round robin order
    foreach($vm in $vms){
        $vmName = $vm.name
        
        if($j -eq $destHosts.Length){
            $j = 0
        }
        $tgtHost = $destHosts[$j]

        Write-Host "Moving $vmName to $tgtHost" -ForegroundColor Yellow
       
        move-vm -VM $vmName -Destination $tgtHost -VMotionPriority High | Out-Null
        
        $j++
    }

    
    #Puts VMHost into Maintenance Mode
    Write-Host "`nPutting $h into maintenance mode...`n" -ForegroundColor Cyan
    Get-VMHost -Name $h | set-vmhost -State Maintenance | Out-Null

    #Starts SSH service
    Write-Host "Starting SSH service on $h...`n" -ForegroundColor Magenta
    Get-VMHost -name $h | Get-VMHostService | where {$_.key -eq 'TSM-SSH'} | Start-VMHostService -Confirm:$false | Out-Null

    #Prompt for user to press enter once ESXi Host update is complete
    Read-Host -Prompt "Press enter to reboot VMHost"

    #Restarts VMHost after updates have been applied
    Restart-VMHost -VMHost $h -Confirm:$false

    #Begins sleep timer and tests connection to host to confirm host is back online before continuing
    
    Start-Sleep -Seconds 80
       
    do{
        $conStatus = Test-Connection -ComputerName $h -Quiet -Count 1
        Start-sleep -Seconds 5
        Write-host "Host has not reconnected yet..." -foregroundcolor yellow
    }while($conStatus -eq $false)
    
    start-sleep -Seconds 70

    #Takes VMHost out of Maintenance Mode
    Write-host "Host is exiting maintenance mode...`n" -ForegroundColor Cyan
    Get-VMHost -Name $h | set-vmhost -State Connected | out-null
    
    #verifying the vm host is out of maintenance mode before trying to migrate vm's back
    do{
        $vmHostState = Get-VMHost -Name $h | Select-Object -Property ConnectionState
        $temp = Compare-Object -ReferenceObject $readyState -DifferenceObject $vmHostState.ConnectionState -IncludeEqual
        Start-Sleep -Seconds 5
        if($temp.SideIndicator -ne "=="){
            Write-Host "Waiting on $h to become connected" -ForegroundColor Yellow
            Start-Sleep -Seconds 2
        }
    }while($temp.SideIndicator -ne "==")

    #Moves all VMs back to original host
    foreach($vm in $vms){
        write-host "Moving "$vm.Name" back to $h `n" -ForegroundColor Green
        Move-VM -VM $vm.Name -Destination $h -VMotionPriority High |Out-Null
    }

    #Verify All VM's are back home
    if($verifyCount -eq ($vms.count - 1)){
        $verifyCount = 0
    }else{
        $verifyCount++
    }
}

#verifying vm's are all on the correct host before ending
foreach($vm in $VMIDTable.Keys){
        
     Write-Host "Moving $vm to"$HostIDTable[$VMIDTable["$vm"]] -ForegroundColor Yellow
       
     move-vm -VM $vm -Destination $HostIDTable[$VMIDTable["$vm"]] -VMotionPriority High -RunAsync |Out-Null
}


#stops both SSH and BASH
Get-VMHost | Foreach {
    Write-Host "Stopping SSH service on $_"
	Stop-VMHostService -HostService ($_ | Get-VMHostService | Where {$_.Key -eq "TSM-SSH"}) -Confirm:$false |Out-Null
    Write-Host "Stopping bash service on $_"
    Stop-VMHostService -HostService ($_ | Get-VMHostService | Where {$_.Key -eq "TSM"}) -Confirm:$false | Out-Null
}

$VMIDTable = $null
$HostIDTable = $null

Disconnect-VIServer -Confirm:$false
