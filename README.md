# Hellm4n — templates AMP

Dépôt unique regroupant mes templates de modules génériques pour CubeCoders AMP.
Organisation à plat, comme `CubeCoders/AMPTemplates` et `Greelan/AMPTemplates` :
un seul `manifest.json` à la racine, tous les fichiers de template au même niveau.

## Templates

| Template | Préfixe des fichiers | Source |
|---|---|---|
| Bannerlord Coop Dedicated Server | `bannerlord-coop*` | copie de `rhinotastic/bannerlord-coop-amp-template`, métadonnées adaptées |
| RimWorld Multiplayer (RWMT) | `rwmt*` | créé ici, à partir du binaire `Server-beta.zip` |
| Coodsz Coop Server Tool (AMP 3) | `coodszcoop*` | créé ici : outil Windows WPF sous Wine, interface dans le navigateur par noVNC |

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

**Par un champ dans AMP**, disponible dans la variante CDN : le réglage
`Accept the licence on next start` vaut `No` par défaut et s'injecte dans
`App.EnvironmentVariables` sous la forme `"DS_ACCEPT_EULA":"{{AcceptEula}}"`. Les valeurs
sont littérales, donc pas de surprise de conversion. On le passe à `Yes`, on démarre une
fois, le serveur écrit son `eula.txt` avec l'empreinte du texte qu'il embarque, puis on le
remet à `No`. Le laisser sur `Yes` reviendrait à accepter par avance toute licence future.

Le champ n'apparaît qu'à la création de l'instance : AMP fige la définition du template et
ses réglages dans le kvp de l'instance. Une instance existante doit être recréée pour voir
un réglage ajouté depuis.

`eula.txt` vit dans `CoopData/DedicatedServer/`, hors de l'arborescence remplacée par
l'update, donc il survit aux mises à jour. Une nouvelle instance, elle, repart sans lui :
c'est pour ça qu'une acceptation ne se transfère pas d'une instance à l'autre sans
recopier le fichier.

Pour transférer une acceptation existante vers une instance neuve, la seule condition est
que le texte de licence soit identique. On compare les empreintes des deux `EULA.md`, puis
on copie le fichier — sans le recopier à la main, l'identifiant `eula-sha256` devant rester
intact :

```
EA=$(find /home/amp/.ampdata/instances/Bannerlord01/bannerlordcoop/steamhome -name EULA.md | head -1)
EB=$(find /home/amp/.ampdata/instances/Bannerlord201/bannerlordcoop/steamhome -name EULA.md | head -1)
md5sum "$EA" "$EB"
cp -a /home/amp/.ampdata/instances/Bannerlord01/bannerlordcoop/CoopData/DedicatedServer/eula.txt /home/amp/.ampdata/instances/Bannerlord201/bannerlordcoop/CoopData/DedicatedServer/
chown 1001:1001 /home/amp/.ampdata/instances/Bannerlord201/bannerlordcoop/CoopData/DedicatedServer/eula.txt
```

Les chemins ci-dessus supposent la lecture depuis un conteneur monté sur
`/home/amp/.ampdata`, et `1001` est l'identifiant de `amp` dans les images CubeCoders.

Si les deux empreintes diffèrent, ne pas copier : c'est le contrôle qui protège d'une
acceptation donnée sur un texte qui a changé depuis.

### Variante : repli sur le CDN de la team (test)

Template séparé, `Bannerlord Coop Dedicated Server (CDN fallback)`, ajouté pour tester sans
toucher au template d'origine, qui reste inchangé. Les deux coexistent dans AMP.

Champs ajoutés :

- `Update source` : `auto` tente l'atelier puis bascule sur le CDN, `steam` impose l'atelier
  et échoue si l'objet est indisponible, `cdn` ignore SteamCMD et ne demande aucun compte Steam
- `Release tag for CDN` : `v0.1.7`, ou `latest` pour résoudre la dernière release GitHub

Déroulé de l'update :

1. atelier Steam via SteamCMD, avec les mêmes champs de compte que le template d'origine
2. si le téléchargement échoue, ou si la source est `cdn`, lecture du `manifest.json` de la
   release, qui donne l'URL, la taille et le SHA-256 de l'archive serveur
3. téléchargement sur le disque de l'instance, puis vérification du SHA-256
4. extraction avec `7zr.exe` sous Wine, l'image ne contenant ni `7z` ni `pip`
5. copie dans le dossier que le template utilise déjà, donc `WorkingDir`, `Executable` et
   les ports ne changent pas

Mesures de référence sur v0.1.7 : archive de 4,52 Go téléchargée en 87 secondes, empreinte
`c5818885…` conforme au manifeste, extraction en 188 secondes pour 5 622 fichiers. Le
préfixe Wine pèse 1,4 Go et doit rester sur le disque de l'instance, jamais dans la couche
du conteneur.

**Attention aux ports** : la variante utilise les mêmes 4200, 4201 et 7210 que le template
d'origine. Les deux instances ne peuvent pas tourner en même temps sans changer les ports
de l'une des deux.

Côté licence, rien à refaire : le `EULA.md` de v0.1.7 est identique octet pour octet à
celui de v0.1.6, et un serveur 0.1.7 démarre avec une acceptation donnée sous 0.1.6 —
vérifié en conditions réelles, jusqu'à `SERVING` avec la campagne chargée.

### Sauvegarde avant mise à jour

Les deux templates écrivent une copie de l'état courant **avant** de remplacer le moindre
binaire, dans le dossier `Backups` de l'instance, à côté de ceux qu'AMP gère lui-même.

Le nom porte la version qui va être remplacée, pas la nouvelle : `pre-update-0.1.6-…` pour
Bannerlord, `pre-update-<sha12>-…` pour RWMT. Une version n'étant remplacée qu'une fois, le
premier dossier créé reste l'état d'origine, et une seconde exécution de l'update ne
l'écrase pas. Trois dossiers sont conservés au maximum.

Ce que contient chaque sauvegarde :

- Bannerlord : `Game Saves/` en entier, `.sav` et `.json` jumeaux compris, plus
  `server-config.json`, `mod-config.json` et `eula.txt`
- RWMT : `settings.toml`, `save.zip` et `Saved/` lorsqu'ils existent
- dans les deux cas un `LISEZ-MOI.txt` avec la date, la version sortante, la version
  entrante et le `saveName` en cours, qu'on ne peut pas reconstituer après coup

La restauration se fait à la main : arrêter le serveur, vider les fichiers concernés dans
le dossier de données, recopier le contenu de la sauvegarde, relancer. Rien n'est automatique
dans ce sens, c'est volontaire — une restauration silencieuse sur un monde vivant serait
plus dangereuse qu'utile.

Le risque réel couvert n'est pas la mise à jour en elle-même, qui ne touche pas aux données,
mais une version qui migre la sauvegarde en place au premier chargement. Sans copie prise
avant que la nouvelle version ne tourne, il n'y a alors aucun retour possible.

### Exploitation au quotidien

Commandes à taper dans la console de l'instance, sans interface dédiée :

- `save` sauvegarde immédiatement. Une sauvegarde automatique tourne aussi toutes les cinq
  minutes, réglable par `autosaveMinutes` dans `server-config.json`, `0` pour l'arrêter
- `stop` sauvegarde puis ferme, en laissant jusqu'à trente secondes. Il n'y a **pas** de
  bouton de redémarrage : il faut relancer `BannerlordCoopServer.exe` ensuite
- `help` liste les autres commandes, dont `status`, `say` et `kick`

Toute modification de `server-config.json` ou de `mod-config.json` exige un redémarrage,
sinon elle n'est pas appliquée.

Le monde joué est celui que désigne `saveName` dans `server-config.json`. Mettre un nom qui
n'existe pas encore crée un monde neuf, sans supprimer l'ancien : il suffit de remettre son
nom pour y revenir. Pour charger une sauvegarde précise, déposer le `.sav` **et** le `.json`
du même nom dans `Game Saves/`, puis renseigner `saveName` sans l'extension.

Codes de sortie à connaître : `6` quand la licence n'est pas acceptée, `4` quand le module
Coop a été modifié et ne correspond plus au build du serveur. Les journaux sont dans
`CoopData/DedicatedServer/logs`, et une sauvegarde faite avec War Sails activé ne se chargera
pas.

### Ajouter des mods

> **Version requise : template v7 ou plus récent.** La préservation des mods dans
> `engine/Modules` date de la version 7. Sur une version antérieure, le script d'update vide
> le dossier d'installation avant d'y copier la nouvelle archive : tout mod déposé serait
> perdu à la mise à jour suivante, sans avertissement. Vérifier `Meta.ConfigVersion` dans le
> `GenericModule.kvp` de l'instance avant de déposer un mod, et faire le Fetch puis l'Update
> pour passer en version 7.

À partir de la 0.1.7, le serveur dédié accepte des mods. Les joueurs doivent avoir les
**mêmes mods aux mêmes versions** que le serveur pour se connecter : installer côté serveur
d'abord, puis activer.

La 0.1.7 livre aussi `BannerlordCoopServerManager.exe`, une interface Windows pour piloter
le serveur et gérer les mods. Elle est **inutilisable sur cette instance** : le template lance
`BannerlordCoopServer.exe` en console, sans écran, et l'interface a besoin d'un bureau Windows.
Ses étapes sont donc reproduites à la main ci-dessous — c'est exactement ce qu'elle fait.

1. copier le dossier **complet** du mod dans `engine/Modules`, à la racine de l'installation
   du serveur, par SFTP ou par le gestionnaire de fichiers d'AMP. Le chemin complet, dans le
   dossier de l'instance, est
   `bannerlordcoop/steamhome/Steam/steamapps/workshop/content/261550/3770450698/DedicatedServer/engine/Modules`
   — l'interface d'AMP ne l'affiche nulle part
2. vérifier que le nom du dossier correspond à l'`Id` déclaré par le mod dans son
   `SubModule.xml` (`<Module><Id value="…"/>`) : sinon le serveur ne le trouve pas, et le
   Manager affiche l'erreur et le nom attendu
3. déclarer le mod dans le tableau `modules` de `server-config.json`, dans
   `CoopData/DedicatedServer/` — c'est le seul geste que l'interface graphique faisait à
   votre place. La clé **n'existe pas** tant qu'aucun mod n'a été activé : la créer au même
   niveau que `saveName`, avec les identifiants dans l'ordre de chargement.

```json
"modules": ["MyMod", "AnotherMod"]
```

Ce format vient du code du Manager de la 0.1.7, qui écrit ce tableau. Que le **serveur** le
relise au démarrage est en revanche **déduit** de là, pas observé : à confirmer au premier mod
réellement activé.

L'ordre du tableau **est** l'ordre de chargement. Les modules toujours chargés ne doivent
jamais y figurer, le serveur les ajoute lui-même : `native`, `sandboxcore`, `sandbox`,
`coop`, `coopnightly`, `dedicatedserver.windows`. Le fichier doit rester un JSON valide, et
les changements ne s'appliquent qu'au démarrage suivant : on redémarre l'instance depuis
l'interface AMP, il n'y a aucune commande à taper.

Messages à savoir lire : « Needs mods » signale une dépendance manquante, désactivée, trop
ancienne ou placée trop bas dans la liste ; « Not installed » signale un dossier absent, et le
serveur s'arrête tant que le mod n'est pas installé ou désactivé ; « Client code only » signale
un mod sans code serveur. Si la sauvegarde a été faite avec un mod absent de la liste, le
serveur pose la question avant de démarrer — charger sans lui peut casser la campagne.

War Sails, Birth and Aging Options et Fast Mode ne fonctionnent pas sur un serveur dédié :
les laisser désactivés.

**Ce que fait ce template.** Le dossier `engine/Modules` se trouve dans la partie que l'update
remplace. Les dossiers de mods qui ne viennent pas de l'archive sont mis de côté avant la
copie, puis remis en place après, avec un contrôle que chacun est bien revenu ; les noms
sont aussi inscrits dans le `LISEZ-MOI.txt` de la sauvegarde pré-update. Les modules livrés
par la nouvelle version, eux, sont bien remplacés.

**Limite connue : les réglages de gameplay de l'interface AMP ne s'appliquent pas.** Les
réglages `Battle Size`, `Difficulty`, exécutions et autres sont censés être écrits par AMP
dans un `mod-config.json` situé dans `CoopData/DedicatedServer/` — un fichier qui **n'existe
pas** dans l'instance. Le fichier effectif est **présumé** être celui du préfixe Wine :
`bannerlordcoop/.wine/drive_c/users/amp/Documents/Mount and Blade II Bannerlord/CoopData/mod-config.json`.
C'est celui-là qu'il faut éditer, puis redémarrer. Une correction du template est à
l'étude ; en attendant, ne pas se fier à ces champs dans l'interface.

### Exécutions entre joueurs

Désactivées par défaut. Pour les autoriser, dans le `mod-config.json` du préfixe Wine
(`Documents/Mount and Blade II Bannerlord/CoopData/`), passer `enablePlayerExecutions` à
`true` — et `enableHeroExecutions` doit valoir `true` aussi, sinon le réglage reste sans
effet. Redémarrer le serveur après modification, les deux valeurs étant à `false` par défaut.

## RimWorld Multiplayer (RWMT)

### Après l'initialisation du monde

Le premier client qui se connecte sur un serveur vide écrit `settings.toml`, puis
`save.zip`, et le serveur s'arrête de lui-même une fois la configuration terminée. Un
redémarrage est nécessaire pour qu'il charge la sauvegarde.

Le wrapper `start.sh` s'en charge : si le serveur sort proprement et que `save.zip` ou
`Saved/` est présent, il le relance une seule fois pour charger le monde. Si l'arrêt vient
du bouton Stop d'AMP, ou si aucun monde n'existe encore, rien n'est relancé.

Ce comportement est dans le wrapper et non dans AMP, parce qu'AMP n'a pas de réglage pour
cela : `AppStartupMode` ne définit que ce que l'instance fait **quand elle démarre**, et
`AutoRetryCount` ne couvre que les plantages, pas une sortie propre.


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

### Prérequis système : le tampon de réception

Le hub demande 4 Mo de tampon par socket et le noyau refuse par défaut : il journalise
`! hub: the socket receive buffer is 416 KB, 4096 KB asked — the system caps it (net.core.rmem_max)`
puis travaille avec ce qu'on lui donne. Un petit tampon fait perdre des paquets en relais quand
ça s'agite, ce qui se traduit par des saccades côté joueurs. C'est un réglage d'hôte, donc hors de
portée du template :

```
printf 'net.core.rmem_max = 8388608\n' > /etc/sysctl.d/90-nightcoop-hub.conf
sysctl --system
cat /proc/sys/net/core/rmem_max
```

La dernière commande doit afficher `8388608`. Sur ce serveur la valeur par défaut était de
212 992 octets, et le fichier `60-amp3.conf` du paquet AMP ne doit pas être touché.

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

## Coodsz Coop Server Tool (AMP 3, interface graphique sous Wine)

L'outil Coodsz n'existe que pour Windows, en WPF. Il tourne donc sous Wine dans un écran
virtuel Xvfb, et son interface est servie dans le navigateur par noVNC : AMP pilote le
cycle de vie (démarrage, arrêt, ports, limites), tandis que les réglages de l'outil
(mods, carte, port de jeu) restent dans sa fenêtre.

- **Image** : `ghcr.io/hellm4nbot/coodsz-amp:amp3`, construite sur `cubecoders/amp3base:debian`
  et publiée en **paquet privé**. AMP 3 tirant ses conteneurs avec podman, une image
  seulement locale ne lui suffit pas (stockages séparés, le nom nu part sur Docker Hub et
  échoue en `requested access to the resource is denied`) : une connexion au registre est
  donc nécessaire une fois sur l'hôte AMP, avec un jeton `read:packages` —
  `su - amp -c 'podman login ghcr.io -u Hellm4nbot'`. Reconstruction et publication :
  `tools/coodsz-amp3-build/build.sh push` (Dockerfile et enveloppe d'entrypoint dans ce dossier).
- **Pourquoi une enveloppe** : `/ampstart.sh` d'`amp3base` ne connaît aucun crochet
  `/ampstart.d` — contrairement à `ampbase` d'AMP 2 — et exécute directement l'agent du
  shard. `coodsz-desktop.sh` monte donc le serveur X, fluxbox et noVNC, puis
  `exec /ampstart.sh`. `DISPLAY` remonte à l'agent par `AMP_ADDITIONAL_ENV_VARS`, seul
  mécanisme qui survit au `env -i` du démarrage.
- **Serveur VNC : TigerVNC (`Xvnc`), pas Xvfb + x11vnc.** Dans `amp3base`, `x11vnc`
  0.9.17 accepte le TCP mais ne sert jamais le client : la file d'écoute reste pleine
  (`Recv-Q 1`), aucune réponse RFB n'est envoyée, y compris en loopback, et noVNC reste
  bloqué sur « En cours de connexion ». `Xvnc` réunit serveur X et VNC dans un seul
  processus, l'authentification étant celle du serveur.
- **Mot de passe VNC obligatoire** : noVNC n'a aucune authentification propre et le port de
  l'interface est publié. `Xvnc` démarre avec `-rfbauth` et `-SecurityTypes VncAuth`. Trois sources,
  dans cet ordre : le réglage **VNC Password** du template, sinon le mot de passe conservé
  avec l'instance (`$HOME/.coodsz-vnc.pass`), sinon un mot de passe généré au premier
  démarrage. Le réglage s'affiche et se modifie dans l'interface AMP ; laissé vide, le mot
  de passe est généré et reste consultable dans la console.
- **La console affiche l'accès à chaque démarrage** : adresse de l'interface
  (`http://<adresse>:<port>/vnc.html`) puis mot de passe et son origine. Le conteneur écoute
  le port déclaré, 8642, en dur (voir la note sur les ports 1:1 ci-dessous).
- **Ports** : 8642 TCP (interface), 4200 et 4201 UDP (jeu et jeu+1), 7210 interne.
  Le port de l'interface est **paramétrable** : `COODSZ_WEB_PORT` dans le `.kvp` et le numéro
  déclaré dans `coodszcoopports.json` doivent rester identiques, le conteneur écoute ce que
  le template déclare.
- **AMP 3 publie les ports 1:1, et c'est ce qui décide de tout.** Mesuré sur une instance
  réelle (`podman port <id>`) : `6082/tcp -> 0.0.0.0:6082`, `7211/tcp -> 0.0.0.0:7211`,
  `4202/udp -> 0.0.0.0:4202`. Le numéro de l'onglet Ports n'est donc pas un port hôte posé
  devant un port conteneur distinct : c'est **le même des deux côtés**, et l'application doit
  écouter exactement ce numéro. Deux conséquences :
  - le port de l'interface est **fixé à 8642 dans l'image** (identique à
    `coodszcoopports.json`). Le changer demande de reconstruire l'image, ce n'est pas un
    réglage. Ne jamais faire dépendre ce port d'une variable d'environnement du template :
    mesuré, `podman exec <id> printenv COODSZ_WEB_PORT` renvoie vide — les variables déclarées
    dans le `.kvp` après la création de l'instance n'arrivent pas au conteneur, et l'entrée
    retombait alors sur 6080 pendant qu'AMP publiait 8642 (connexion réinitialisée dans le
    navigateur, port en écoute côté hôte) ;
  - les ports de jeu et moteur doivent être **recopiés à la main** dans la fenêtre de l'outil
    (Paramètres : Port UDP, Port du moteur) avec les numéros affichés dans l'onglet Ports —
    AMP les décale pour éviter les collisions avec les autres instances (4200 devenu 4202,
    7210 devenu 7211 dans notre cas).
- **Une collision de port ne se règle pas en décalant le port hôte**, puisque les deux côtés
  bougent ensemble : il faut soit un numéro libre pour le port déclaré (reconstruction de
  l'image pour l'interface), soit — pour les ports de jeu — changer le numéro et le reporter
  dans l'outil. Symptômes à distinguer : « Un port nécessaire à cette application est déjà
  utilisé » = le numéro était pris au démarrage (`ghostdesk` tenait 6080 en
  `192.168.1.13:6080`) ; `ERR_CONNECTION_RESET` ou un port qui écoute sans répondre =
  l'application n'écoute pas le numéro publié. Identifier le détenteur avant de toucher quoi
  que ce soit : `ss -ltnp | grep :<port>`, plus
  `su - amp -c 'podman ps -a --format "{{.Names}} {{.Status}} {{.Ports}}"'` (instances AMP)
  et `docker ps --format "{{.Names}} {{.Status}} {{.Ports}}"'` (conteneurs de test) — un
  service démarré depuis des jours est celui de l'exploitant, on ne le supprime pas.
- **Serveur dédié et mods d'atelier (SteamCMD)** : l'outil ne télécharge rien, et le
  conteneur n'a ni Steam ni jeu. Une seconde étape d'Update récupère l'atelier `3770450698`
  et les ateliers listés dans **Mods Workshop IDs**, avec le compte Steam des réglages
  (mot de passe et code Steam Guard si le compte en exige un : utilisés une seule fois,
  puis effacés — le jeton reste en cache dans l'instance). Elle assemble
  `<instance>/server/DedicatedServer`, à désigner dans l'outil par **Set server folder** :
  `Z:\AMP\coodszcoop\server\DedicatedServer`. Un dossier serveur déjà présent n'est **jamais**
  écrasé (sauvegardes, mods et réglages de l'outil) ; pour repartir d'une copie neuve, le
  supprimer puis relancer Update. Chaque mod est copié dans
  `server/DedicatedServer/Modules/<nom>` depuis le dossier qui porte son `SubModule.xml`,
  quel que soit le niveau d'imbrication ; l'étape est idempotente. Sans identifiants Steam,
  l'étape est sautée et l'outil s'installe quand même.
- **Où l'outil garde ses réglages** : `%LOCALAPPDATA%\Coodsz\Coop\host.json` dans le
  préfixe Wine, soit `.wine/drive_c/users/amp/AppData/Local/Coodsz/Coop/host.json`. Il contient
  les profils (`CoopPort`, `EnginePort`, `CampaignMap`, `ModuleOrder`, `DisabledModules`), le
  dossier serveur (`ServerExecutable`, ce que règle « Set server folder ») et l'acceptation de
  la licence. Il survit aux redémarrages et aux Update, et se sauvegarde comme n'importe quel
  fichier. Le script de démarrage y **préremplit `ServerExecutable`** avec
  `Z:\AMP\coodszcoop\server\DedicatedServer\BannerlordCoopServer.exe` quand le chemin est vide
  ou ne pointe plus sur rien — jamais quand l'exploitant a déjà choisi un chemin valide. Il ne
  touche pas aux ports : AMP les attribue à la création de l'instance (4200 → 4202 chez nous),
  donc soit on aligne l'onglet Ports sur les valeurs par défaut de l'outil (4200 / 7210), soit on
  saisit les numéros d'AMP une seule fois dans la fenêtre, et `host.json` les conserve.
- **Ce qui n'est pas sur l'atelier** : TAOM (ModDB) et les mods Nexus se déposent à la main
  dans `server/DedicatedServer/Modules/`, qui survit aux mises à jour.
- **Scripts livrés par l'Update** : AMP ne copie pas les fichiers annexes d'un template dans
  l'instance — seuls le `.kvp` et les fichiers `@IncludeJson` sont lus. La première étape
  récupère donc `coodszcoop-update.sh`, `coodszcoop-steam.sh` et `coodszcoop-start.sh` depuis
  la branche `main` du dépôt avant de les exécuter ; c'est aussi ce qui rend
  `coodszcoop-start.sh` disponible pour `App.ExecutableLinux`. Sans cette étape, l'Update
  échoue en `No such file or directory` (code 127).
- **Mise à jour** : `coodszcoop-update.sh` télécharge l'archive `Coodsz-Coop-Tools-…zip`
  de la dernière release GitHub et la contrôle contre le `digest` publié par l'API
  (repli : `SHA256SUMS.txt`). Aucun binaire dans ce dépôt ni dans l'image — la licence
  interdit la redistribution et tout miroir. L'autre zip de la release
  (`Coodsz-Coop-and-Friends`) ne sert qu'aux anciennes versions pour se mettre à jour
  elles-mêmes : le prendre donnerait un paquet inadapté.
- **Préfixe Wine** : `<racine de l'instance>.wine`, préparé au premier lancement par
  `coodszcoop-start.sh` — `wineboot -i`, `winetricks corefonts` avec repli sur Liberation,
  `DisableHWAcceleration` pour le rendu logiciel de WPF. Le préparer pendant la
  construction de l'image ne tient pas : les couches sont mises en cache et le préfixe
  appartiendrait au mauvais utilisateur.
- **État** : chaîne de démarrage vérifiée dans l'image, avec un agent factice —
  `Xvnc` en écoute, noVNC joignable, `DISPLAY=:99` transmis à l'agent, et le serveur
  annonce bien `RFB 003.008` puis le type de sécurité `2` (mot de passe) à travers
  websockify. Contrôlé avec un vrai client VNC : sans mot de passe la connexion est
  refusée, avec le mot de passe la capture du bureau X (fluxbox) aboutit.
  Reste non vérifié : le lancement réel du serveur, qui exige le dossier
  `DedicatedServer` de l'atelier Steam et `steam_api64.dll` avec un compte possédant
  Bannerlord.

## Notes de maintenance

- Chaque template garde son `Meta.AppConfigId` propre ; seul le `manifest.json` du
  dépôt porte l'identifiant unique du dépôt.
- Une modification du kvp n'est prise en compte qu'au **redémarrage de l'instance** :
  AMP charge la définition une fois, au démarrage. Incrémenter `Meta.ConfigVersion` à
  chaque changement, puis Fetch → redémarrer l'instance.
- Si AMP affiche une erreur de chemin du type `DeploymentTemplates/--main/...` après un
  push, refetcher le dépôt, et au besoin supprimer le dossier du template dans
  `DeploymentTemplates` avant de refetcher.
| Subnautica (Nitrox) AMP 3 | `subnautica-nitrox-amp3*` | copie de `subnautica2.kvp`, chemin du jeu sorti du réglage cassé |
| NightCoop Hub (AMP 3) | `nightcoop-hub-amp3*` | créé ici : aucun binaire publié en amont, le template compile le hub depuis ses sources |

## NightCoop Hub sur AMP 3 (Linux uniquement)

Relais du mod NightCoop (coop pour Cyberpunk 2077). Il n'héberge aucun jeu : le monde reste la
sauvegarde du joueur hôte, le hub distribue les codes de session et relaie le trafic quand aucun
chemin direct ne s'ouvre, les liens hôte-invité restant chiffrés de bout en bout.

Le projet amont ne publie **aucun binaire Linux**, seulement des sources avec un `Dockerfile`.
L'étape de mise à jour compile donc le hub dans l'instance via `tools/nightcoop_hub_build.sh`
(embarqué en base64 dans l'un des fichiers du template) : sources du hub au commit
`6b694a6c86fd7c2b93743497ab3bd924553f25b8`, ENet au commit `5a9c537f`, et `g++` installé par
l'étape elle-même puisque l'image `amp3base:debian` n'apporte aucun compilateur.

- ports : **UDP 47800** (entrée, obligatoire), `47810` et `47811` pour les deux fils
- réglages : `Shards` (2), `MaxClients` (512), `MaxGuests` (7, soit 8 joueurs avec l'hôte)
- clé et empreinte : `data/hub-sign.key`, empreinte affichée au démarrage, à donner aux joueurs
  avec l'adresse (`monhub.example.org#PEAJ-796J-9TBC-4BTZ`)
- il faut une **IPv4 publique** et une redirection UDP : depuis un LAN, personne ne joint le hub

Le détail — compilation reproductible, empreinte du binaire, réglages, côté joueurs — est dans la
branche `amp3`, section « NightCoop Hub sur AMP 3 ».

### L'image doit fournir le compilateur

AMP 3 **n'installe aucun paquet à l'exécution** : la doc du produit est explicite — « without root
there is no apt, so `ExtraContainerPackages` cannot be applied at launch ». L'étape de compilation
tourne donc sous l'utilisateur de l'instance, pas en root, et ne peut rien installer elle-même.

`amp3base:debian` n'a aucun compilateur. Le template déclare donc
`Meta.SpecificDockerImage=cubecoders/amp3base:postgresql`, image Debian 13 dont la description
est « Toolchain and headers for building PostgreSQL from source » et qui livre `g++`, `gcc`,
`make`, `git`, `curl`, `tar` et `base64`. `amp3base:redis` fonctionne aussi (Ubuntu 26.04), avec le
même outillage. Compilation vérifiée en compte non privilégié dans `postgresql` : même binaire,
même `sha256`.

## Miroir des fichiers NightCoop

Le projet peut retirer un build, et une session exige que tous les joueurs aient le **même** build du
mod. Les fichiers sont donc mirroirés à deux endroits, avec leurs empreintes :

- **pCloud**, dossier `NightCoop Mirror` (compte du bot) — 5 fichiers, vérifiés par re-téléchargement
  et comparaison du `sha256`
- **serveur**, `/home/hermes/archives/nightcoop/` — même contenu, sur le disque du serveur
- **dépôt**, fichier `nightcoop-mirror.txt` — les empreintes et la procédure, jamais les binaires :
  deux archives de 10 Mo dans l'historique git ralentiraient chaque `Fetch` d'AMP

Contenu du miroir au 2026-11-09 :

| Fichier | Taille | Rôle |
|---|---|---|
| `NightCoop-0.2.0-beta-2.5.zip` | 10 117 378 o | client pour un jeu en 2.5 (RED4ext 1.31.0) |
| `NightCoop-0.2.0-beta-2.31.zip` | 10 115 285 o | client pour un jeu en 2.31 (RED4ext 1.30.0) |
| `nightcoop-hub-6b694a6c…tar.gz` | 161 303 o | sources du hub, commit épinglé par le template |
| `enet-5a9c537f…tar.gz` | 83 822 o | ENet, commit épinglé par le Dockerfile amont |
| `MANIFEST.txt` | 3 445 o | empreintes complètes, versions, procédure |

Les empreintes des deux clients correspondent aux préfixes publiés par le projet
(`ca070aa296519fb4…`, `ecb66f43c23dd212…`). Détail complet dans `nightcoop-mirror.txt`.

À refaire quand : un nouveau build du mod sort, ou le commit du hub change dans
`tools/nightcoop_hub_build.sh`. Le miroir doit toujours correspondre au template déployé, sinon il
induit en erreur — un joueur avec l'ancien build ne rejoint pas une session.

## Miroir des fichiers : ce qu'on garde et ce qu'on ne garde pas

Tous les templates ne méritent pas un miroir. Le critère est la nature de la source : on conserve ce
qui est **mutable ou éphémère**, on laisse ce qui est déjà immuable. Le détail complet, empreintes
comprises, est dans `mirror-templates.txt` ; les fichiers sont dans les dépôts `amp-mirror` — GitHub
`Hellm4nbot/amp-mirror`, Codeberg `hellm4nbot/amp-mirror` — branches `main` et `amp3`, avec une copie
locale sous `/home/hermes/archives/`.

- **RWMT — mirroiré, priorité haute.** La release `continuous` a un tag **roulant** : ses deux
  archives sont écrasées à chaque build. Un serveur installé hier ne peut plus être reproduit depuis
  GitHub, et le client du joueur doit correspondre au serveur au bit près. C'est le seul cas où
  perdre les fichiers rend un serveur impossible à reconstruire.
- **Nitrox — mirroiré.** Tag immuable, mais projet bénévole et archive de 23 Mo pointée directement
  par le template.
- **NightCoop — mirroiré, sources comprises.** Sans les sources, l'Update échouerait si le dépôt
  amont disparaissait.
- **Project Zomboid — rien à garder.** SteamCMD, serveurs Valve, connexion anonyme : chaque instance
  retélécharge à volonté.
- **Bannerlord Coop — rien à garder.** Atelier Steam, immuable.
- **Bannerlord CDN — version consignée, pas d'archive.** Releases taguées mais 4,5 Go par version :
  on note le tag et l'empreinte du manifeste, et on retrouve l'objet tant que le dépôt existe.
