<#
.SYNOPSIS
Automatise la rotation d'un template VMware et son déploiement multi-sites.

.DESCRIPTION
Workflow implémenté (cohérent avec le besoin métier):
1. Connexion au vCenter source.
2. Conversion du template source en VM de travail.
3. Clonage de cette VM vers un artefact d'archive nommé `template-MM-yyyy`.
4. Conversion immédiate du clone d'archive en template (historisation).
5. Démarrage de la VM de travail (patching).
6. Pause pour updates manuelles/externes.
7. Arrêt propre puis arrêt forcé si nécessaire.
8. Renommage de la VM patchée en nom générique du template cible.
9. Export en OVA.
10. Déploiement de l'OVA sur chaque site distant (en parallèle sur PowerShell 7+).
11. Conversion en template sur chaque site distant.
12. Conversion finale en template sur le site source.

.NOTES
- Script prévu pour VMware PowerCLI.
- Exécuter d'abord avec -WhatIf pour validation.
- Le déploiement multi-sites est parallélisé via ForEach-Object -Parallel sur
  PowerShell 7+ (throttle configurable via MaxParallelSites); repli séquentiel
  automatique sur Windows PowerShell 5.1.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter()]
    [pscredential]$Credential
)

$ErrorActionPreference = 'Stop'


function Import-WorkflowConfig {
    param([string]$Path)

    if (-not (Test-Path -Path $Path)) {
        throw "Fichier de configuration introuvable: $Path"
    }

    $cfg = Get-Content -Path $Path -Raw | ConvertFrom-Json
    $required = @('SourceVCenter','SourceTemplateName','WorkingVmName','GenericTemplateName','SourceCluster','SourceDatastore','SourceFolder','ExportOvfPath','RemoteSites')
    foreach ($field in $required) {
        if (-not $cfg.PSObject.Properties.Name.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$cfg.$field)) {
            throw "Champ obligatoire manquant dans le fichier de configuration: $field"
        }
    }

    if (-not $cfg.PSObject.Properties.Name.Contains('BootWaitSeconds')) { $cfg | Add-Member -NotePropertyName BootWaitSeconds -NotePropertyValue 120 }
    if (-not $cfg.PSObject.Properties.Name.Contains('ShutdownTimeoutSeconds')) { $cfg | Add-Member -NotePropertyName ShutdownTimeoutSeconds -NotePropertyValue 300 }
    if (-not $cfg.PSObject.Properties.Name.Contains('PauseForManualUpdates')) { $cfg | Add-Member -NotePropertyName PauseForManualUpdates -NotePropertyValue $false }
    if (-not $cfg.PSObject.Properties.Name.Contains('MaxParallelSites')) { $cfg | Add-Member -NotePropertyName MaxParallelSites -NotePropertyValue 4 }

    return $cfg
}

function Connect-ToVCenter {
    param([string]$Server, [pscredential]$Cred)

    Write-Host "Connexion à $Server ..." -ForegroundColor Cyan
    if ($Cred) { return Connect-VIServer -Server $Server -Credential $Cred }
    return Connect-VIServer -Server $Server
}

function Disconnect-AllVIServersSafe {
    Write-Host "Déconnexion de tous les vCenters..." -ForegroundColor Cyan
    Disconnect-VIServer -Server * -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}

function Wait-VMToPowerOff {
    param([VMware.VimAutomation.ViCore.Impl.V1.Inventory.VirtualMachineImpl]$VM, [int]$TimeoutSeconds)

    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $current = Get-VM -Id $VM.Id
        if ($current.PowerState -eq 'PoweredOff') {
            return $true
        }
        Start-Sleep -Seconds 5
        $elapsed += 5
    }
    return $false
}


function Invoke-PSCheck {
    param(
        [string]$Name,
        [scriptblock]$Check
    )

    Write-Host "[PSCHECK] $Name" -ForegroundColor Yellow
    try {
        & $Check
        Write-Host "[PSCHECK:OK] $Name" -ForegroundColor Green
    }
    catch {
        throw "[PSCHECK:KO] $Name -> $($_.Exception.Message)"
    }
}

function Invoke-PreFlightPSChecks {
    param(
        [string]$VCenter,
        [string]$TemplateName,
        [string]$ClusterName,
        [string]$DatastoreName,
        [string]$FolderName,
        [array]$Sites,
        [string]$ExportPath
    )

    Invoke-PSCheck -Name 'Template source existe' -Check { Get-Template -Name $TemplateName | Out-Null }
    Invoke-PSCheck -Name 'Cluster source existe' -Check { Get-Cluster -Name $ClusterName | Out-Null }
    Invoke-PSCheck -Name 'Datastore source existe' -Check { Get-Datastore -Name $DatastoreName | Out-Null }
    Invoke-PSCheck -Name 'Folder source existe' -Check { Get-Folder -Name $FolderName | Out-Null }
    Invoke-PSCheck -Name 'Dossier export accessible/creable' -Check {
        if (-not (Test-Path -Path $ExportPath)) {
            New-Item -Path $ExportPath -ItemType Directory -Force | Out-Null
        }
    }

    foreach ($site in $Sites) {
        Invoke-PSCheck -Name "Site $($site.Name): connexion vCenter" -Check {
            $remoteConn = if ($Credential) { Connect-VIServer -Server $site.VCenter -Credential $Credential } else { Connect-VIServer -Server $site.VCenter }
            Disconnect-VIServer -Server $remoteConn -Confirm:$false | Out-Null
        }
    }
}

function Assert-RequiredSiteFields {
    param([array]$Sites)

    $required = @('Name', 'VCenter', 'Cluster', 'Datastore', 'Folder')
    foreach ($site in $Sites) {
        foreach ($field in $required) {
            if (-not $site.PSObject.Properties.Name.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$site.$field)) {
                throw "RemoteSites invalide: champ '$field' manquant ou vide pour l'entrée '$($site | Out-String)'."
            }
        }
    }
}

try {
    if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI)) {
        throw "VMware.PowerCLI n'est pas installé. Lancez : Install-Module VMware.PowerCLI"
    }

    Import-Module VMware.PowerCLI -ErrorAction Stop
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false | Out-Null

    $config = Import-WorkflowConfig -Path $ConfigPath
    $SourceVCenter = $config.SourceVCenter
    $SourceTemplateName = $config.SourceTemplateName
    $WorkingVmName = $config.WorkingVmName
    $GenericTemplateName = $config.GenericTemplateName
    $SourceCluster = $config.SourceCluster
    $SourceDatastore = $config.SourceDatastore
    $SourceFolder = $config.SourceFolder
    $ExportOvfPath = $config.ExportOvfPath
    $RemoteSites = @($config.RemoteSites)
    $BootWaitSeconds = [int]$config.BootWaitSeconds
    $ShutdownTimeoutSeconds = [int]$config.ShutdownTimeoutSeconds
    $PauseForManualUpdates = [bool]$config.PauseForManualUpdates
    $MaxParallelSites = [int]$config.MaxParallelSites

    Assert-RequiredSiteFields -Sites $RemoteSites

    $dateSuffix = Get-Date -Format 'MM-yyyy'
    $archivedTemplateName = "$SourceTemplateName-$dateSuffix"
    # Export-VApp -Format Ova crée un sous-dossier portant le nom de la VM: <Dest>\<Nom>\<Nom>.ova
    $ovaFilePath = Join-Path (Join-Path $ExportOvfPath $GenericTemplateName) "$GenericTemplateName.ova"

    if (-not (Test-Path -Path $ExportOvfPath)) {
        if ($PSCmdlet.ShouldProcess($ExportOvfPath, 'Créer le dossier d export')) {
            New-Item -Path $ExportOvfPath -ItemType Directory -Force | Out-Null
        }
    }

    $sourceConn = Connect-ToVCenter -Server $SourceVCenter -Cred $Credential

    Invoke-PreFlightPSChecks -VCenter $SourceVCenter -TemplateName $SourceTemplateName -ClusterName $SourceCluster -DatastoreName $SourceDatastore -FolderName $SourceFolder -Sites $RemoteSites -ExportPath $ExportOvfPath

    $sourceTemplate = Get-Template -Name $SourceTemplateName -Server $sourceConn
    $targetCluster = Get-Cluster -Name $SourceCluster -Server $sourceConn
    $targetDatastore = Get-Datastore -Name $SourceDatastore -Server $sourceConn
    $targetFolder = Get-Folder -Name $SourceFolder -Server $sourceConn
    $targetHost = $targetCluster | Get-VMHost -Server $sourceConn | Sort-Object CpuUsageMhz | Select-Object -First 1

    if ($PSCmdlet.ShouldProcess($SourceTemplateName, 'Convertir le template en VM')) {
        $workingVm = Set-Template -Template $sourceTemplate -ToVM -VMHost $targetHost -Datastore $targetDatastore
    }
    else {
        Write-Host '[WhatIf] Conversion simulée; planification basée sur le template source.' -ForegroundColor DarkGray
        $workingVm = $sourceTemplate
    }

    if ($workingVm.Name -ne $WorkingVmName -and $PSCmdlet.ShouldProcess($workingVm.Name, "Renommer en $WorkingVmName")) {
        $workingVm = Set-VM -VM $workingVm -Name $WorkingVmName -Confirm:$false
    }

    if ($PSCmdlet.ShouldProcess($workingVm.Name, "Cloner en $archivedTemplateName")) {
        $archiveVm = New-VM -Name $archivedTemplateName -VM $workingVm -Location $targetFolder -Datastore $targetDatastore -VMHost ($workingVm | Get-VMHost)
        Set-VM -VM $archiveVm -ToTemplate -Confirm:$false | Out-Null
    }

    if ($PSCmdlet.ShouldProcess($workingVm.Name, 'Démarrer la VM de travail')) {
        Start-VM -VM $workingVm -Confirm:$false | Out-Null
        Write-Host "Attente du démarrage ($BootWaitSeconds s)..." -ForegroundColor Cyan
        Start-Sleep -Seconds $BootWaitSeconds
    }

    if ($PauseForManualUpdates -eq $true -and -not $WhatIfPreference) {
        Read-Host "Effectuez les updates dans la VM $($workingVm.Name), puis appuyez sur Entrée"
    }
    elseif (-not $PauseForManualUpdates) {
        Write-Warning "Ajoutez votre mécanisme d'updates (Invoke-VMScript, WSUS, SCCM, Ansible, etc.)."
    }

    if ($PSCmdlet.ShouldProcess($workingVm.Name, 'Arrêter proprement la VM')) {
        Shutdown-VMGuest -VM $workingVm -Confirm:$false -ErrorAction SilentlyContinue
        $isOff = Wait-VMToPowerOff -VM $workingVm -TimeoutSeconds $ShutdownTimeoutSeconds
        if (-not $isOff) {
            Write-Warning "Arrêt invité non finalisé dans le délai. Arrêt forcé."
            Stop-VM -VM $workingVm -Confirm:$false | Out-Null
        }
    }

    if ($workingVm.Name -ne $GenericTemplateName -and $PSCmdlet.ShouldProcess($workingVm.Name, "Renommer en $GenericTemplateName")) {
        $workingVm = Set-VM -VM $workingVm -Name $GenericTemplateName -Confirm:$false
    }

    if ($PSCmdlet.ShouldProcess($workingVm.Name, "Exporter en OVA vers $ExportOvfPath")) {
        Export-VApp -VM $workingVm -Destination $ExportOvfPath -Format Ova -Force | Out-Null
    }

    # --- Déploiement multi-sites ---
    # La décision ShouldProcess (et donc le mode -WhatIf) est évaluée ici, dans le runspace
    # principal: $PSCmdlet n'est pas accessible depuis les runspaces de ForEach-Object -Parallel.
    $sitesToDeploy = @()
    foreach ($site in $RemoteSites) {
        if ($PSCmdlet.ShouldProcess($site.Name, "Importer $ovaFilePath et templatiser")) {
            $sitesToDeploy += $site
        }
    }

    if ($sitesToDeploy.Count -gt 0) {
        if (-not (Test-Path -Path $ovaFilePath)) {
            throw "OVA introuvable: $ovaFilePath"
        }

        $throttle = if ($MaxParallelSites -gt 0) { $MaxParallelSites } else { 4 }

        if ($PSVersionTable.PSVersion.Major -ge 7) {
            Write-Host "Déploiement parallèle sur $($sitesToDeploy.Count) site(s) (throttle=$throttle)..." -ForegroundColor Cyan
            # Chaque site tourne dans un runspace isolé: import PowerCLI + connexion dédiés,
            # ce qui évite toute ambiguïté de contexte multi-vCenter.
            $siteResults = $sitesToDeploy | ForEach-Object -ThrottleLimit $throttle -Parallel {
                $site        = $_
                $ova         = $using:ovaFilePath
                $cred        = $using:Credential
                $genericName = $using:GenericTemplateName

                $result = [pscustomobject]@{ Site = $site.Name; Success = $false; Message = $null }
                $conn = $null
                try {
                    Import-Module VMware.VimAutomation.Core -ErrorAction Stop
                    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false | Out-Null

                    $conn = if ($cred) {
                        Connect-VIServer -Server $site.VCenter -Credential $cred -ErrorAction Stop
                    }
                    else {
                        Connect-VIServer -Server $site.VCenter -ErrorAction Stop
                    }

                    $deployedVmName = "$genericName-$($site.Name)"
                    $siteCluster    = Get-Cluster   -Name $site.Cluster   -Server $conn -ErrorAction Stop
                    $siteHost       = $siteCluster | Get-VMHost -Server $conn | Sort-Object CpuUsageMhz | Select-Object -First 1
                    $siteDatastore  = Get-Datastore -Name $site.Datastore -Server $conn -ErrorAction Stop
                    $siteFolder     = Get-Folder    -Name $site.Folder    -Server $conn -ErrorAction Stop

                    $deployedVm = Import-VApp -Source $ova -Name $deployedVmName -VMHost $siteHost -Datastore $siteDatastore -Location $siteFolder -Server $conn -ErrorAction Stop
                    Set-VM -VM $deployedVm -ToTemplate -Confirm:$false -ErrorAction Stop | Out-Null

                    $result.Success = $true
                    $result.Message = "Template '$deployedVmName' déployé."
                }
                catch {
                    $result.Message = $_.Exception.Message
                }
                finally {
                    if ($conn) { Disconnect-VIServer -Server $conn -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }
                }
                $result
            }
        }
        else {
            Write-Warning "PowerShell < 7 détecté: déploiement séquentiel (parallélisme indisponible)."
            $siteResults = foreach ($site in $sitesToDeploy) {
                $result = [pscustomobject]@{ Site = $site.Name; Success = $false; Message = $null }
                $conn = $null
                try {
                    $conn = Connect-ToVCenter -Server $site.VCenter -Cred $Credential
                    $deployedVmName = "$GenericTemplateName-$($site.Name)"
                    $siteCluster    = Get-Cluster   -Name $site.Cluster   -Server $conn
                    $siteHost       = $siteCluster | Get-VMHost -Server $conn | Sort-Object CpuUsageMhz | Select-Object -First 1
                    $siteDatastore  = Get-Datastore -Name $site.Datastore -Server $conn
                    $siteFolder     = Get-Folder    -Name $site.Folder    -Server $conn

                    $deployedVm = Import-VApp -Source $ovaFilePath -Name $deployedVmName -VMHost $siteHost -Datastore $siteDatastore -Location $siteFolder -Server $conn
                    Set-VM -VM $deployedVm -ToTemplate -Confirm:$false | Out-Null

                    $result.Success = $true
                    $result.Message = "Template '$deployedVmName' déployé."
                }
                catch {
                    $result.Message = $_.Exception.Message
                }
                finally {
                    if ($conn) { Disconnect-VIServer -Server $conn -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }
                }
                $result
            }
        }

        foreach ($r in $siteResults) {
            if ($r.Success) {
                Write-Host "[SITE:OK] $($r.Site) - $($r.Message)" -ForegroundColor Green
            }
            else {
                Write-Warning "[SITE:KO] $($r.Site) - $($r.Message)"
            }
        }

        $failedSites = @($siteResults | Where-Object { -not $_.Success })
        if ($failedSites.Count -gt 0) {
            throw "Déploiement échoué sur $($failedSites.Count) site(s): $(($failedSites | ForEach-Object { $_.Site }) -join ', ')."
        }
    }

    if ($PSCmdlet.ShouldProcess($GenericTemplateName, 'Convertir la VM source en template')) {
        $sourceVmToTemplate = Get-VM -Name $GenericTemplateName -Server $sourceConn
        Set-VM -VM $sourceVmToTemplate -ToTemplate -Confirm:$false | Out-Null
    }

    Write-Host 'Workflow terminé avec succès.' -ForegroundColor Green
}
catch {
    Write-Error "Echec du workflow: $($_.Exception.Message)"
    throw
}
finally {
    Disconnect-AllVIServersSafe
}
