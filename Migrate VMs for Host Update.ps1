$prodVCSA = <production VCSA>
$drVCSA = <dr VCSA>

$prodHosts = <Enter hosts using comma separated values. Include quotation marks around each entry>
$drHosts = <Enter hosts using comma separated values. Include quotation marks around each entry>

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
    1 {cls;$vcsa = $prodVCSA;$hosts = $prodHosts;"`n`nStarting at PROD`n"}
    2 {cls;$vcsa = $drVCSA;$hosts = $drHosts;"`n`nStarting DR`n"}
    Default{
        cls
        Write-Host "`n`n`n################################`n" -ForegroundColor Yellow
        Write-Host "            Exiting" -ForegroundColor Yellow
        Write-Host "`n################################`n" -ForegroundColor Yellow

        Start-Sleep -Seconds 2
        break
    }
}

#Establishes a connection with the vcenter server
Connect-VIServer -Server $vcsa

foreach($h in $hosts){
       
    $j = 0
    $destHosts = $hosts | where {$_ -ne $h}
    
    $vms = get-vmhost -Name $h | Get-VM
    
    foreach($vm in $vms){
        $vmName = $vm.name
        
        if($j -eq $destHosts.Length){
            $j = 0
        }
        $tgtHost = $destHosts[$j]

        Write-Host "Moving $vmName to $tgtHost" -ForegroundColor Yellow
       
        move-vm -VM $vmName -Destination $destHosts[$j] -VMotionPriority High | Out-Null
        
        $j = $j + 1
    }

    
    #Puts VMHost into Maintenance Mode
    Write-Host "Putting $h into maintenance mode...`n" -ForegroundColor Cyan
    Get-VMHost -Name $h | set-vmhost -State Maintenance |out-null

    #Starts SSH service
    Write-Host "Starting SSH service on $h...`n" -ForegroundColor Magenta
    Get-VMHost -name $h | Get-VMHostService | where {$_.key -eq 'TSM-SSH'} | Start-VMHostService -Confirm:$false | out-null

    #Prompt for user to press enter once ESXi Host update is complete
    Read-Host -Prompt "Press enter to reboot VMHost"

    #Restarts VMHost after updates have been applied
    Restart-VMHost -VMHost $h -Confirm:$false

    #Begins sleep timer and tests connection to host to confirm host is back online
    
    Start-Sleep -Seconds 80
       
    do{
        $conStatus = Test-Connection -ComputerName $h -Quiet -Count 1
        Start-sleep -Seconds 5
        Write-host $conStatus
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
        $vmName = $vm.name
        write-host "Moving $vmName back to $h `n" -ForegroundColor Green
        Move-VM -VM $vmName -Destination $h -VMotionPriority High |Out-Null
    }

    #Verify All VM's are back home
    if($verifyCount -eq ($vms.count - 1)){
        
        $verifyCount = 0
    }else{
        $verifyCount++
    }
}

#verifying vm's are all on the correct host before ending
foreach($h in $hosts){
    Write-Host "Starting on $h" -ForegroundColor Green

    $vms = import-csv -Path 
    
    foreach($vm in $vms){
        $vmName = $vm.name
        
        Write-Host "Moving $vmName to $h" -ForegroundColor Yellow
       
        move-vm -VM $vmName -Destination $h -VMotionPriority High -RunAsync |Out-Null
        
    }
}
