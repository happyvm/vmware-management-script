# vmware-management-script

## Script principal

- `Rotate-VmwareTemplate.ps1` : automatise la rotation d'un template VMware (PowerCLI), l'archivage mensuel, la phase de mise à jour, l'export OVA et le déploiement sur des sites distants.

## Configuration dans un fichier

Les variables sont maintenant externalisées dans un fichier JSON.

1. Copier `vmware-template-config.example.json` vers un fichier local (ex: `vmware-template-config.json`).
2. Adapter toutes les valeurs (vCenter, template, datastore, sites distants...).
3. Lancer le script avec `-ConfigPath`.

## Exemple d'utilisation

```powershell
$cred = Get-Credential

.\Rotate-VmwareTemplate.ps1 `
  -ConfigPath '.\vmware-template-config.json' `
  -Credential $cred
```

## Actions de PSCHECK incluses

Le script exécute des PSCHECK avant opérations critiques :

- vérification existence template/cluster/datastore/folder source,
- vérification accessibilité/création du dossier d'export,
- test de connexion à chaque vCenter distant.

Chaque check loggue `[PSCHECK]`, `[PSCHECK:OK]` ou échoue en `[PSCHECK:KO]`.

## Conseils d'exécution

- Lancer en premier avec `-WhatIf` pour valider le plan.
- Vérifier que VMware Tools est présent pour l'arrêt invité.
- Adapter la partie updates (WSUS/SCCM/Ansible/Invoke-VMScript) selon votre SI.
