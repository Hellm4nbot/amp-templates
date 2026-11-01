# Hellm4n — templates AMP

Dépôt unique regroupant mes templates de modules génériques pour CubeCoders AMP.
Organisation à plat, comme `CubeCoders/AMPTemplates` et `Greelan/AMPTemplates` :
un seul `manifest.json` à la racine, tous les fichiers de template au même niveau.

## Templates

| Template | Préfixe des fichiers | Source |
|---|---|---|
| Bannerlord Coop Dedicated Server | `bannerlord-coop*` | copie de `rhinotastic/bannerlord-coop-amp-template`, métadonnées adaptées |
| RimWorld Multiplayer (RWMT) | `rwmt*` | créé ici, à partir du binaire `Server-beta.zip` |

## Installation dans AMP

Configuration → Instance Deployment → Add Configuration Repository → `Hellm4n/amp-templates:main`,
puis **Fetch** et rafraîchir la page.

Variante locale, sans GitHub : copier les fichiers dans
`ADS01/Plugins/ADSModule/DeploymentTemplates/LOCAL-amp-templates-main/` puis redémarrer ADS.

## Bannerlord Coop

Serveur du mod Bannerlord Coop, exécuté **sous Wine** dans `cubecoders/ampbase:wine-stable`,
parce que `BannerlordCoopServer.exe` n'a pas de build Linux.

- Téléchargement depuis l'atelier Steam 261550 / 3770450698 via SteamCMD, avec login
  Steam obligatoire (l'atelier d'un jeu payant ne se télécharge pas en anonyme).
- `--data-dir` pointe sur `CoopData/DedicatedServer/` pour que sauvegardes et config
  survivent aux mises à jour de l'atelier.
- Ports UDP 4200 et 4201, plus 7210 interne.
- Licence : acceptation persistée dans `eula.txt` avec `eula-sha256`. Ne pas laisser
  `DS_ACCEPT_EULA` en permanence, sinon une nouvelle version du texte serait acceptée
  sans lecture.
- Le serveur vérifie par SHA-256 son module Coop au démarrage : client et serveur
  doivent être sur la même build (v0.1.6 au moment de l'écriture, jeu v1.4.8).

## RimWorld Multiplayer (RWMT)

Serveur dédié du mod RimWorld Multiplayer (projet Zetrith), **Linux natif .NET 8**,
sans Wine, dans `cubecoders/ampbase:debian`.

- Image Debian obligatoire : runtime .NET 8, et l'utilitaire `script` pour fournir un
  PTY — le serveur appelle `Console.KeyAvailable`, qui lève une exception quand
  l'entrée standard est un tube comme dans AMP.
- Champ **Server download URL** : build officiel `continuous/Server-beta.zip` par
  défaut, ou tout zip fourni sur le Discord du projet.
- Port 30502 déclaré en TCP et UDP ; la valeur réelle vient du `settings.toml`
  téléversé par le premier client.
- Aucune configuration manuelle : le premier joueur connecté fait le bootstrap depuis
  RimWorld.
- Les mises à jour ne touchent jamais `settings.toml`, `save.zip` ni `Saved/` : un
  garde-fou refuse l'archive si elle en contient.

## Notes de maintenance

- Chaque template garde son `Meta.AppConfigId` propre ; seul le `manifest.json` du
  dépôt porte l'identifiant unique du dépôt.
- Si AMP affiche une erreur de chemin du type `DeploymentTemplates/--main/...` après un
  push, refetcher le dépôt, et au besoin supprimer le dossier du template dans
  `DeploymentTemplates` avant de refetcher.
