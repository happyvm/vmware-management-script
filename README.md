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

## Déploiement multi-sites parallèle

Le déploiement de l'OVA et la templatisation sur les sites distants sont
parallélisés sur **PowerShell 7+** (`ForEach-Object -Parallel`). Chaque site
s'exécute dans un runspace isolé (import PowerCLI + connexion vCenter dédiés),
ce qui évite toute ambiguïté de contexte multi-vCenter.

- `MaxParallelSites` (config JSON) limite le nombre de sites traités en
  parallèle (défaut : `4`). À ajuster selon la bande passante WAN disponible,
  car l'OVA est téléversé vers chaque site depuis la source.
- Sur Windows PowerShell 5.1, le script bascule automatiquement en
  déploiement séquentiel.
- Un échec sur un site n'interrompt pas les autres : tous les sites sont
  tentés, puis le script échoue en listant les sites en erreur.

## Conseils d'exécution

- Lancer en premier avec `-WhatIf` pour valider le plan.
- Vérifier que VMware Tools est présent pour l'arrêt invité.
- Adapter la partie updates (WSUS/SCCM/Ansible/Invoke-VMScript) selon votre SI.
