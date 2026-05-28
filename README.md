# vmware-management-script

## Script principal

- `Rotate-VmwareTemplate.ps1` : automatise la rotation d'un template VMware (PowerCLI), l'archivage mensuel, la phase de mise à jour, l'export OVA et le déploiement sur des sites distants.

## Analyse de cohérence du workflow

Le workflow est structuré pour éviter les incohérences opérationnelles :

1. **Template source → VM de travail** : le template devient modifiable pour patching.
2. **Renommage en nom de travail** : séparation claire entre objet en cours de maintenance et objet final.
3. **Clone d'archive daté (`MM-yyyy`)** : conservation d'un historique mensuel.
4. **Re-template immédiat de l'archive** : l'archive reste immutable.
5. **Boot + fenêtre d'updates** : phase de maintenance contrôlée.
6. **Arrêt propre puis fallback forcé** : évite les VMs laissées allumées.
7. **Renommage en nom générique** : standardisation avant diffusion.
8. **Export OVA unique** : artefact de référence pour les sites distants.
9. **Import par site + conversion en template** : même base OS partout.
10. **Conversion finale sur le site source** : la source revient en état template.

## Exemple d'utilisation

```powershell
$cred = Get-Credential
$sites = @(
    @{ Name = 'Lyon'; VCenter = 'vc-lyon.local'; Cluster = 'Cluster-Lyon'; Datastore = 'DS-Lyon-01'; Folder = 'Templates' },
    @{ Name = 'Paris'; VCenter = 'vc-paris.local'; Cluster = 'Cluster-Paris'; Datastore = 'DS-Paris-01'; Folder = 'Templates' }
)

.\Rotate-VmwareTemplate.ps1 `
  -SourceVCenter 'vc-source.local' `
  -SourceTemplateName 'win2022-template' `
  -WorkingVmName 'win2022-patching' `
  -GenericTemplateName 'win2022-template' `
  -SourceCluster 'Cluster-Source' `
  -SourceDatastore 'DS-Source-01' `
  -SourceFolder 'Templates' `
  -ExportOvfPath 'D:\Exports' `
  -RemoteSites $sites `
  -Credential $cred `
  -PauseForManualUpdates
```

## Conseils d'exécution

- Lancer en premier avec `-WhatIf` pour valider le plan.
- Vérifier que VMware Tools est présent pour l'arrêt invité.
- Adapter la partie updates (WSUS/SCCM/Ansible/Invoke-VMScript) selon votre SI.


## Actions de PSCHECK incluses

Le script ajoute des **actions de PSCHECK** avant les opérations destructives :

- vérification existence template/cluster/datastore/folder source,
- vérification accessibilité/création du dossier d'export,
- test de connexion à chaque vCenter distant.

Chaque check loggue `[PSCHECK]`, `[PSCHECK:OK]` ou échoue en `[PSCHECK:KO]` pour stopper le workflow proprement.
