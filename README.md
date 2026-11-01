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
  sans lecture. Procédure complète ci-dessous.
- Le serveur vérifie par SHA-256 son module Coop au démarrage : client et serveur
  doivent être sur la même build, sans quoi le refus est immédiat en code 4. Au moment
  de l'écriture, l'atelier servait encore v0.1.6, alors que v0.1.7 est publiée sur
  GitHub depuis le 30 octobre 2026 et attend son approbation sur Steam.

### Licence (EULA)

Le serveur refuse de démarrer tant que les conditions ne sont pas acceptées, et sort en
**code 6**. Un `eula.txt` réduit à `eula=true` ne suffit pas : le serveur y ajoute
l'identifiant du texte accepté sous forme `eula-sha256`, qui doit correspondre à celui du
build installé. C'est ce qui protège d'une acceptation donnée sur une version antérieure.

Pour accepter, deux voies.

**Par la variable d'environnement**, la seule disponible aujourd'hui. Dans
`<instance>/GenericModule.kvp`, ajouter `DS_ACCEPT_EULA` aux variables :

```
App.EnvironmentVariables={"DS_ACCEPT_EULA":"true","WINEPREFIX":"{{$FullRootDir}}.wine","WINEARCH":"win64","WINEDEBUG":"-all","SteamAppId":"261550"}
```

Démarrer une fois : le serveur écrit `eula.txt` complet, 316 octets avec son
`eula-sha256`. Puis **retirer la variable** et redémarrer — le fichier suffit, et le
serveur échouera proprement en code 6 si une future version change le texte. Laisser la
variable en place reviendrait à accepter par avance toute licence future, sans lecture.

**Par un champ dans AMP**, possible et prévu avec la prochaine version du template : un
champ à deux valeurs, `false` par défaut, injecté dans `App.EnvironmentVariables` sous la
forme `"DS_ACCEPT_EULA":"{{AcceptEula}}"`. Les valeurs sont littérales, donc pas de
surprise de conversion. Le principe reste le même : on coche, on démarre une fois, on
décoche. La case ne doit jamais rester cochée en permanence, pour la raison ci-dessus.

`eula.txt` vit dans `CoopData/DedicatedServer/`, hors de l'arborescence remplacée par
l'update, donc il survit aux mises à jour. Une nouvelle instance, elle, repart sans lui :
c'est pour ça qu'une acceptation ne se transfère pas d'une instance à l'autre sans
recopier le fichier.

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
- `App.WorkingDir` reste **vide**. Ce champ-là est résolu depuis `App.BaseDirectory`, pas
  depuis `RootDir` : avec `BaseDirectory=./rwmt/Server/Linux/`, une valeur `Server/Linux`
  donnait `/AMP/rwmt/Server/Linux/Server/Linux` et Start échouait sur
  `Could not find a part of the path`. C'est `start.sh` qui se place dans son propre
  dossier.
- Champ **Server download URL** : build officiel `continuous/Server-beta.zip` par
  défaut, ou tout zip fourni sur le Discord du projet.
- Port 30502 déclaré en **UDP seul** ; LiteNetLib, la bibliothèque réseau du mod, n'ouvre
  aucune socket TCP (vérifié : `0.0.0.0:30502 udp` en écoute). La valeur effective vient
  du `settings.toml` téléversé par le premier client.
- Onglet **RWMT server settings** : `settings.toml` est mappé dans l'interface par
  `rwmtmetaconfig.json`, selon la méthode des templates BeamMP et Pumpkin — deux entrées,
  une pour les valeurs entre guillemets, une pour les booléens, nombres et tableaux. Le
  chemin `ConfigFile` est relatif à `App.BaseDirectory`, donc il vaut `settings.toml` et
  non `Server/Linux/settings.toml`, sous peine de doubler le segment. Les paramètres
  apparaissent dès que le fichier existe, c'est-à-dire après la première connexion.
  Avant, l'onglet est vide : le fichier n'est créé que par le bootstrap.
- **AMP recopie le template dans le dossier de l'instance à sa création** :
  `<instance>/configmanifest.json` et `<instance>/metaconfig.json` sont des instantanés.
  Les modifier dans `DeploymentTemplates/` ou dans le dépôt ne change rien pour une
  instance existante, et un redémarrage ne les rafraîchit pas — seule une recréation le
  fait. C'est la cause d'une erreur `DirectoryNotFoundException` dans `WriteMetaconfigs`
  avec un chemin en double : il faut corriger `<instance>/metaconfig.json` directement.
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
