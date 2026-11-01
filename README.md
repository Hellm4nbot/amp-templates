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

Configuration → Instance Deployment → Add Configuration Repository → `Hellm4nbot/amp-templates:main`,
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
- `App.ExecutableLinux=Server/Linux/start.sh` : ce chemin est relatif à `App.RootDir`,
  **pas** à `App.BaseDirectory`. Avec `start.sh` seul, AMP cherche `/AMP/rwmt/start.sh`,
  journalise `Specified executable ... does not exist` et relance l'Update à chaque
  clic sur Start.
- Champ **Server download URL** : build officiel `continuous/Server-beta.zip` par
  défaut, ou tout zip fourni sur le Discord du projet.
- Port 30502 déclaré en **UDP seul** ; LiteNetLib, la bibliothèque réseau du mod, n'ouvre
  aucune socket TCP (vérifié : `0.0.0.0:30502 udp` en écoute). La valeur effective vient
  du `settings.toml` téléversé par le premier client.
- Onglet **RWMT server settings** : `settings.toml` est mappé dans l'interface par
  `rwmtmetaconfig.json`, selon la méthode des templates BeamMP et Pumpkin — deux entrées,
  une pour les valeurs entre guillemets, une pour les booléens, nombres et tableaux. Les
  paramètres apparaissent dès que le fichier existe, c'est-à-dire après la première
  connexion. Avant, l'onglet est vide : le fichier n'est créé que par le bootstrap.
- Aucune configuration manuelle : le premier joueur connecté fait le bootstrap depuis
  RimWorld.
- Les mises à jour ne touchent jamais `settings.toml`, `save.zip` ni `Saved/` : un
  garde-fou refuse l'archive si elle en contient.

### Côté joueurs

RimWorld avec le mod Multiplayer, **même build que le serveur** — une différence fait
refuser la connexion. Connexion en IP directe sur `<ip>:30502`, Steam n'est pas utilisé :
le serveur headless ne peut pas héberger de lobby Steam.

Le mod client se prend sur la **même release que le serveur** :

```
https://github.com/rwmt/Multiplayer/releases/download/continuous/Multiplayer-beta.zip
```

Les deux archives, `Server-beta.zip` et `Multiplayer-beta.zip`, sont deux assets de la
même release `continuous`, produits par la même exécution d'intégration : ils
correspondent donc par construction. Si le champ *Server download URL* est remplacé par
un zip récupéré sur le Discord, il faut fournir aux joueurs le **client du même build**
et mettre à jour le champ *Client mod URL* en conséquence — l'interface l'affiche comme
un lien cliquable, et l'Update le rappelle dans sa sortie.

Le premier joueur connecté configure la carte et le scénario depuis RimWorld, et son
client téléverse le `settings.toml` sur le serveur. Les suivants rejoignent la session
en cours, sans configuration. Pour jouer depuis l'extérieur, rediriger **UDP 30502**
sur le routeur.

### État vérifié

Validé de bout en bout le 1er novembre 2026 sur AMP 2.8.0.4 : runtime 8.0.15 installé
dans `rwmt/dotnet`, wrapper PTY fonctionnel, serveur en écoute, journal affichant les
deux lignes de bootstrap.

## Notes de maintenance

- Chaque template garde son `Meta.AppConfigId` propre ; seul le `manifest.json` du
  dépôt porte l'identifiant unique du dépôt.
- Une modification du kvp n'est prise en compte qu'au **redémarrage de l'instance** :
  AMP charge la définition une fois, au démarrage. Incrémenter `Meta.ConfigVersion` à
  chaque changement, puis Fetch → redémarrer l'instance.
- Si AMP affiche une erreur de chemin du type `DeploymentTemplates/--main/...` après un
  push, refetcher le dépôt, et au besoin supprimer le dossier du template dans
  `DeploymentTemplates` avant de refetcher.
