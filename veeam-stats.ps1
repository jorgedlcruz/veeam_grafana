<#
        .SYNOPSIS
        PRTG Veeam Advanced Sensor
  
        .DESCRIPTION
        Advanced Sensor will Report Statistics about Backups during last 24 Hours and Actual Repository usage. It will then convert them into JSON, ready to add into InfluxDB and show it with Grafana
	
        .Notes
        NAME:  veeam-stats.ps1
        ORIGINAL NAME: PRTG-VeeamBRStats.ps1
        LASTEDIT: 27/02/2017
        VERSION: 0.1
        KEYWORDS: Veeam, PRTG
   
        .Link
        http://mycloudrevolution.com/
        Minor Edits and JSON output for Grafana by https://jorgedelacruz.es/
 
 #Requires PS -Version 3.0
 #Requires -Modules VeeamPSSnapIn    
 #>
[cmdletbinding()]
param(
    [Parameter(Position=0, Mandatory=$false)]
        [string] $BRHost = "veeamsrv",
    [Parameter(Position=1, Mandatory=$false)]
        $reportMode = "24", # Weekly, Monthly as String or Hour as Integer
    [Parameter(Position=2, Mandatory=$false)]
        $repoCritical = 10,
    [Parameter(Position=3, Mandatory=$false)]
        $repoWarn = 20
  
)
# You can find the original code for PRTG here, thank you so much Markus Kraus - https://github.com/mycloudrevolution/Advanced-PRTG-Sensors/blob/master/Veeam/PRTG-VeeamBRStats.ps1
# Big thanks to Shawn, creating a awsome Reporting Script:
# http://blog.smasterson.com/2016/02/16/veeam-v9-my-veeam-report-v9-0-1/

#region: Start Load VEEAM Snapin (if not already loaded)
if (!(Get-PSSnapin -Name VeeamPSSnapIn -ErrorAction SilentlyContinue)) {
	if (!(Add-PSSnapin -PassThru VeeamPSSnapIn)) {
		# Error out if loading fails
		Write-Error "`nERROR: Cannot load the VEEAM Snapin."
		Exit
	}
}
#endregion

#region: Functions
Function Get-vPCRepoInfo {
[CmdletBinding()]
        param (
                [Parameter(Position=0, ValueFromPipeline=$true)]
                [PSObject[]]$Repository
                )
        Begin {
                $outputAry = @()
                Function Build-Object {param($name, $repohost, $path, $free, $total)
                        $repoObj = New-Object -TypeName PSObject -Property @{
                                        Target = $name
										RepoHost = $repohost
                                        Storepath = $path
                                        StorageFree = [Math]::Round([Decimal]$free/1GB,2)
                                        StorageTotal = [Math]::Round([Decimal]$total/1GB,2)
                                        FreePercentage = [Math]::Round(($free/$total)*100)
                                }
                        Return $repoObj | Select Target, RepoHost, Storepath, StorageFree, StorageTotal, FreePercentage
                }
        }
        Process {
                Foreach ($r in $Repository) {
                	# Refresh Repository Size Info
					[Veeam.Backup.Core.CBackupRepositoryEx]::SyncSpaceInfoToDb($r, $true)
					
					If ($r.HostId -eq "00000000-0000-0000-0000-000000000000") {
						$HostName = ""
					}
					Else {
						$HostName = $($r.GetHost()).Name.ToLower()
					}
					$outputObj = Build-Object $r.Name $Hostname $r.Path $r.info.CachedFreeSpace $r.Info.CachedTotalSpace
					}
                $outputAry += $outputObj
        }
        End {
                $outputAry
        }
}
#endregion

#region: Start BRHost Connection
$OpenConnection = (Get-VBRServerSession).Server
if($OpenConnection -eq $BRHost) {
	
} elseif ($OpenConnection -eq $null ) {
	
	Connect-VBRServer -Server $BRHost
} else {
    
    Disconnect-VBRServer
   
    Connect-VBRServer -Server $BRHost
}

$NewConnection = (Get-VBRServerSession).Server
if ($NewConnection -eq $null ) {
	Write-Error "`nError: BRHost Connection Failed"
	Exit
}
#endregion

#region: Convert mode (timeframe) to hours
If ($reportMode -eq "Monthly") {
        $HourstoCheck = 720
} Elseif ($reportMode -eq "Weekly") {
        $HourstoCheck = 168
} Else {
        $HourstoCheck = $reportMode
}
#endregion

#region: Collect and filter Sessions
# $vbrserverobj = Get-VBRLocalhost        # Get VBR Server object
# $viProxyList = Get-VBRViProxy           # Get all Proxies
$repoList = Get-VBRBackupRepository     # Get all Repositories
$allSesh = Get-VBRBackupSession         # Get all Sessions (Backup/BackupCopy/Replica)
# $allResto = Get-VBRRestoreSession       # Get all Restore Sessions
$seshListBk = @($allSesh | ?{($_.CreationTime -ge (Get-Date).AddHours(-$HourstoCheck)) -and $_.JobType -eq "Backup"})           # Gather all Backup sessions within timeframe
$seshListBkc = @($allSesh | ?{($_.CreationTime -ge (Get-Date).AddHours(-$HourstoCheck)) -and $_.JobType -eq "BackupSync"})      # Gather all BackupCopy sessions within timeframe
$seshListRepl = @($allSesh | ?{($_.CreationTime -ge (Get-Date).AddHours(-$HourstoCheck)) -and $_.JobType -eq "Replica"})        # Gather all Replication sessions within timeframe
#endregion

#region: Collect Jobs
# $allJobsBk = @(Get-VBRJob | ? {$_.JobType -eq "Backup"})        # Gather Backup jobs
# $allJobsBkC = @(Get-VBRJob | ? {$_.JobType -eq "BackupSync"})   # Gather BackupCopy jobs
# $repList = @(Get-VBRJob | ?{$_.IsReplica})                      # Get Replica jobs
#endregion

#region: Get Backup session informations
$totalxferBk = 0
$totalReadBk = 0
$seshListBk | %{$totalxferBk += $([Math]::Round([Decimal]$_.Progress.TransferedSize/1GB, 0))}
$seshListBk | %{$totalReadBk += $([Math]::Round([Decimal]$_.Progress.ReadSize/1GB, 0))}
#endregion

#region: Preparing Backup Session Reports
$successSessionsBk = @($seshListBk | ?{$_.Result -eq "Success"})
$warningSessionsBk = @($seshListBk | ?{$_.Result -eq "Warning"})
$failsSessionsBk = @($seshListBk | ?{$_.Result -eq "Failed"})
$runningSessionsBk = @($allSesh | ?{$_.State -eq "Working" -and $_.JobType -eq "Backup"})
$failedSessionsBk = @($seshListBk | ?{($_.Result -eq "Failed") -and ($_.WillBeRetried -ne "True")})
#endregion

#region:  Preparing Backup Copy Session Reports
$successSessionsBkC = @($seshListBkC | ?{$_.Result -eq "Success"})
$warningSessionsBkC = @($seshListBkC | ?{$_.Result -eq "Warning"})
$failsSessionsBkC = @($seshListBkC | ?{$_.Result -eq "Failed"})
$runningSessionsBkC = @($allSesh | ?{$_.State -eq "Working" -and $_.JobType -eq "BackupSync"})
$IdleSessionsBkC = @($allSesh | ?{$_.State -eq "Idle" -and $_.JobType -eq "BackupSync"})
$failedSessionsBkC = @($seshListBkC | ?{($_.Result -eq "Failed") -and ($_.WillBeRetried -ne "True")})
#endregion

#region: Preparing Replicatiom Session Reports
$successSessionsRepl = @($seshListRepl | ?{$_.Result -eq "Success"})
$warningSessionsRepl = @($seshListRepl | ?{$_.Result -eq "Warning"})
$failsSessionsRepl = @($seshListRepl | ?{$_.Result -eq "Failed"})
$runningSessionsRepl = @($allSesh | ?{$_.State -eq "Working" -and $_.JobType -eq "Replica"})
$failedSessionsRepl = @($seshListRepl | ?{($_.Result -eq "Failed") -and ($_.WillBeRetried -ne "True")})

$RepoReport = $repoList | Get-vPCRepoInfo | Select     @{Name="Repository Name"; Expression = {$_.Target}},
                                                       @{Name="Host"; Expression = {$_.RepoHost}},
                                                       @{Name="Path"; Expression = {$_.Storepath}},
                                                       @{Name="Free (GB)"; Expression = {$_.StorageFree}},
                                                       @{Name="Total (GB)"; Expression = {$_.StorageTotal}},
                                                       @{Name="Free (%)"; Expression = {$_.FreePercentage}},
                                                       @{Name="Status"; Expression = {
                                                       If ($_.FreePercentage -lt $repoCritical) {"Critical"} 
                                                       ElseIf ($_.FreePercentage -lt $repoWarn) {"Warning"}
                                                       ElseIf ($_.FreePercentage -eq "Unknown") {"Unknown"}
                                                       Else {"OK"}}} | `
                                                       Sort "Repository Name" 
#endregion

#region: Number of Endpoints
$number_endpoints = 0
foreach ($endpoint in Get-VBREPJob ) {
$number_endpoints++;
}
#endregion
 

#region: JSON Output for Telegraf
Write-Host "{" 
$Count = $successSessionsBk.Count
Write-Host "`"Successful-Backups`"": "$Count,"
$Count = $warningSessionsBk.Count
Write-Host "`"Warning-Backups`"": "$Count,"
$Count = $failsSessionsBk.Count
Write-Host "`"Failes-Backups`"": "$Count,"
$Count = $failedSessionsBk.Count
Write-Host "`"Failed-Backups`"": "$Count,"
$Count = $runningSessionsBk.Count
Write-Host "`"Running-Backups`"": "$Count,"
$Count = $successSessionsBkC.Count
Write-Host "`"Successful-BackupCopys`"": "$Count,"
$Count = $warningSessionsBkC.Count
Write-Host "`"Warning-BackupCopys`"": "$Count,"
$Count = $failsSessionsBkC.Count
Write-Host "`"Failes-BackupCopys`"": "$Count,"
$Count = $failedSessionsBkC.Count
Write-Host "`"Failed-BackupCopys`"": "$Count,"
$Count = $runningSessionsBkC.Count
Write-Host "`"Running-BackupCopys`"": "$Count,"
$Count = $IdleSessionsBkC.Count
Write-Host "`"Idle-BackupCopys`"": "$Count,"
$Count = $successSessionsRepl.Count
Write-Host "`"Successful-Replications`"": "$Count,"
$Count = $warningSessionsRepl.Count
Write-Host "`"Warning-Replications`"": "$Count,"
$Count = $failsSessionsRepl.Count
Write-Host "`"Failes-Replications`"": "$Count,"
$Count = $failedSessionsRepl.Count
Write-Host "`"Failed-Replications`"": "$Count,"


Write-Host "`"TotalBackupTransfer`"": "$totalxferBk,"
foreach ($Repo in $RepoReport){
$Name = "REPO - " + $Repo."Repository Name"
$Free = $Repo."Free (%)"
Write-Host "`"$Name`"": "$Free,"
	}
Write-Host "`"Number of protected Endpoints`"": "$number_endpoints,"
Write-Host "`"TotalBackupRead`"": "$totalReadBk,"
$Count = $runningSessionsRepl.Count
Write-Host "`"Running-Replications`"": "$Count"
Write-Host "}" 
#endregion

#region: Debug
if ($DebugPreference -eq "Inquire") {
	$RepoReport | ft * -Autosize
    
    $SessionObject = [PSCustomObject] @{
	    "Successful Backups"  = $successSessionsBk.Count
	    "Warning Backups" = $warningSessionsBk.Count
	    "Failes Backups" = $failsSessionsBk.Count
	    "Failed Backups" = $failedSessionsBk.Count
	    "Running Backups" = $runningSessionsBk.Count
	    "Warning BackupCopys" = $warningSessionsBkC.Count
	    "Failes BackupCopys" = $failsSessionsBkC.Count
	    "Failed BackupCopys" = $failedSessionsBkC.Count
	    "Running BackupCopys" = $runningSessionsBkC.Count
	    "Idle BackupCopys" = $IdleSessionsBkC.Count
	    "Successful Replications" = $successSessionsRepl.Count
        "Warning Replications" = $warningSessionsRepl.Count
        "Failes Replications" = $failsSessionsRepl.Count
        "Failed Replications" = $failedSessionsRepl.Count
        "Running Replications" = $RunningSessionsRepl.Count
    }
    $SessionResport += $SessionObject
    $SessionResport
}
#endregion
