# Montages Coop : un template AMP 3 piloté par des packs

Proposition — 16 novembre 2026. Objet : retrouver la gestion de l'outil Coodsz & Friends
(profils, mods, ordre de chargement, carte, sauvegardes) **sans** son interface WPF, en la
pilotant depuis le panneau AMP.

## 1. Principe

Un template `bannerlord-modpack`, dérivé du template **CDN fallback** qui fonctionne déjà, et un
fichier de description par montage (« pack ») dans le dépôt. Le template ne connaît aucun mod :
il sait *assembler* un pack, le *vérifier* et le *lancer*. Changer de montage = changer une valeur
ou un fichier, jamais du code.

Ce que le CDN fallback apporte déjà, et qu'on garde tel quel :

- atelier Steam Workshop par SteamCMD, avec repli sur le CDN de l'équipe ;
- préservation à travers les mises à jour : `server-data/`, `Game Saves/`, `server-config.json`,
  `mod-config.json`, et **les modules inconnus du paquet dans `engine/Modules`** — donc un TAOM de
  18 Go n'est pas retéléchargé ;
- les ports publiés, les 40+ réglages de jeu mappés sur `server-config.json` / `mod-config.json`.

## 2. Le pack, nouvelle unité de configuration

`packs/<id>.json`, versionné dans le dépôt, décrit un montage complet :

```json
{
  "id": "coop-taom",
  "displayName": "Coop + TAOM",
  "gameVersion": "1.4.8",
  "coopBuild": "0.1.7",
  "base": "coop",
  "modules": [
    "TAOM.Dependencies", "Native", "SandBoxCore", "Sandbox", "StoryMode",
    "CustomBattle", "LOTRLOME_Armory", "DualWield", "TAOM_Map", "TAOM",
    "Coop", "DedicatedServer.Windows", "DedicatedServer.CoopSaveRescue"
  ],
  "disabled": ["NavalDLC"],
  "sources": [
    { "match": "TAOM*", "kind": "local", "path": "modpacks/taom",
      "hint": "build 1.4.8, ModDB ou Nexus ; déposer les dossiers de modules ici" },
    { "match": "LOTRLOME_*|DualWield", "kind": "local", "path": "modpacks/taom" }
  ],
  "notes": "Montage non supporté par les équipes TAOM et Coop."
}
```

`coopBuild` n'est pas décoratif : il épingle la version du mod Coop avec laquelle le pack a été
validé. Le template refuse de démarrer si le build installé diffère, sauf `SkipModuleCheck` — parce
que le mod Coop bouge vite (nightlies) et qu'un pack validé sur `0.1.7` n'est pas validé sur
`0.1.9`.

Une entrée de `modules` est soit une chaîne (elle ne fixe que l'ordre), soit un objet qui porte sa
propre vérification quand la version déclarée n'est pas fiable :

```json
{ "id": "ROT_Map", "verify": { "mode": "sha256", "file": "ROT.dll", "sha256": "…" } }
```

Les modes sont `version` (par défaut, lecture du `SubModule.xml`), `sha256`, et `marker` (présence
d'une chaîne dans un fichier). Voir §14 pour la raison : certains builds estampillent la version du
jeu à la place de la leur.

Trois natures de source, et c'est la clé de la robustesse :

- `workshop` — récupéré par SteamCMD depuis l'objet 3770450698 (le socle Coop) ;
- `local` — un dossier que l'exploitant remplit une fois (`modpacks/taom/`), jamais écrasé par un
  update. TAOM n'étant pas redistribuable, aucune URL automatique n'est inventée ;
- `cdn` — pour ce que l'équipe Coop publie officiellement.

## 3. Réglages exposés dans AMP

| Réglage | Rôle | Remplace, côté Coodsz |
|---|---|---|
| `Modpack` (liste) | quel montage assembler | le profil actif |
| `GameVersion` (liste) | version de jeu exigée, contrôlée | — (implicite) |
| `SaveName` | monde chargé ou créé | le champ sauvegarde |
| `JoinPort` / `EnginePort` | ports, écrits dans `server-config.json` | les champs verrouillés de l'outil |
| `ExtraModules` (texte) | mods supplémentaires, séparés par des virgules | « Add mods » |
| `ModuleOrder` (texte) | remplace l'ordre du pack si besoin | le glisser-déposer |
| `SkipModuleCheck` (case) | démarrer malgré une vérification en échec | « aucun mod cassé » |
| les 40+ réglages existants | difficulté, taille de bataille, MCM… | la page Paramètres |

La **carte de campagne** n'est plus un réglage : elle découle du pack (le module `TAOM_Map` ou
`Sandbox` fournit la carte). C'est une simplification, pas une régression — c'est exactement ce que
l'outil Coodsz devait préserver à la main dans `host.json`.

**La surface de réglages dépend du pack — c'est la réponse à l'inquiétude TAOM.** Les ~40 réglages
`mc_*` de `mod-config.json` (difficulté de recrutement, vitesse de carte, taille de bataille…) sont
les options de la **campagne vanilla de Coop** : sous TAOM, elles ne portent pas toutes, parce que
TAOM remplace la campagne et ses propres options vivent dans son MCM. Un pack déclare donc
`settingsProfile`, et le template n'écrit **que les clés que ce profil connaît** :

```json
"settingsProfile": "taom",
"settings": {
  "supported": ["saveName", "autosaveMinutes", "password", "port", "steam",
                "allowClientTimeControls", "logFile"],
  "ignored":   ["mc_recruitmentDifficulty", "mc_playerMapMovementSpeed", "*"]
}
```

Au démarrage, le template imprime ce qu'il a écrit et ce qu'il a ignoré, avec la raison. Mieux vaut
un montage qui annonce « 7 réglages applicables sur 40, les autres relèvent du MCM de TAOM » qu'un
panneau qui affiche des réglages sans effet — c'est précisément le mensonge d'interface qu'on
reprochait à l'outil Coodsz.

## 4. Chaîne d'assemblage (étape Update, puis Start)

1. Socle : SteamCMD → `engine/Modules` (repli CDN si l'atelier refuse).
2. Pack : copie de `modpacks/<pack>/` vers `engine/Modules`, sans jamais écraser un module du
   socle (comparaison de version dans `SubModule.xml`).
3. **Vérification** : chaque module du pack est-il présent, à la bonne version, et la version de
   jeu correspond-elle ? Sinon message explicite et arrêt :
   ```
   [pack] coop-taom : 3 modules manquants dans /amp/.../engine/Modules
   [pack]   TAOM, TAOM_Map, LOTRLOME_Armory
   [pack]   attendu : build 1.4.8 -> déposer les dossiers dans modpacks/taom/
   ```
4. **Ordre de chargement** : écrit dans le mécanisme que le serveur headless lit réellement
   (voir §6 — c'est le seul point à mesurer avant de coder).
5. Lancement : `BannerlordCoopServer.exe` avec les modules retenus, `server-config.json` déjà
   rédigé par AMP.

## 5. Sauvegardes, et changement de pack

- `SaveName` écrit dans `server-config.json` ; `Game Saves/` et `server-data/` restent préservés
  par l'étape d'update existante.
- Un monde appartient à un pack : au Start, si le pack a changé depuis le dernier démarrage
  (mémorisé dans `.modpack-etat`), le template refuse de charger la sauvegarde et explique
  pourquoi — un monde vanilla ne s'ouvre pas avec TAOM, comme les sauvegardes 1.4.8 ne s'ouvrent
  pas en 1.5.7.

## 6. L'ordre de chargement — résolu (16 novembre 2026)

**Mesuré et documenté par le projet `PlodyIce/bannerlordcoop-server-manager` (MIT), qui fait tourner
des serveurs Coop moddés :** `BannerlordCoopServer.exe` n'est qu'un lanceur. Il démarre le moteur
avec une **liste de modules figée** et n'offre aucun moyen d'y ajouter quoi que ce soit. Pour
servir avec des mods, on n'utilise donc pas le lanceur — on démarre le moteur exactement comme lui,
modules en plus :

```
cwd  engine\bin\Win64_Shipping_Server
     engine\dotnet\dotnet.exe TaleWorlds.Starter.DotNetCore.dll
         _MODULES_*Native*SandBoxCore*Sandbox*Coop*DedicatedServer.Windows*_MODULES_
         /dedicatedcustomserver 7210 EU 0

env  DOTNET_ROOT=Z:\server\engine\dotnet
     DOTNET_MULTILEVEL_LOOKUP=0
     BANNERLORD_USER_DIR=Z:\data
     COOP_DATA_DIR=C:\users\coop\Documents\Mount and Blade II Bannerlord\CoopData
```

L'ordre de chargement, c'est **la liste `_MODULES_*A*B*C*_MODULES_`** de la ligne de commande. Le
manifeste d'un pack se traduit donc littéralement en cette chaîne : pas de fichier annexe, pas de
`DependedModules` à bricoler, pas d'argument caché. C'est la réponse à la question qui bloquait
tout le reste.

Conséquence sur le template : dès qu'un pack contient autre chose que le socle Coop, c'est le
**moteur** qu'on lance, pas `BannerlordCoopServer.exe`. Ce que le lanceur faisait en plus — un
journal par lancement, l'initialisation du dossier de données — se fait dans le script de démarrage.
Le reste (licence, contrôle de somme Coop, `server-config.json`, console `save` / `players` /
`stop`, sauvegarde de fermeture) est dans le moteur et continue de fonctionner.

Ce qui reste à vérifier de notre côté, et qui se mesure en une fois sur l'instance existante : que
le moteur démarre bien ainsi sous **notre** préfixe Wine, avec notre chemin d'installation.

## 7. Découpage

| Étape | Contenu | Livrable |
|---|---|---|
| P0 | mesure de l'ordre de chargement headless | note + commande reproductible |
| P1 | template dérivé du CDN, `Modpack`, vérification, pack `coop` | instance identique à l'actuelle, avec la plomberie |
| P2 | pack `coop-taom`, dossier `modpacks/taom/`, contrôle de version | montage TAOM assemblé et vérifié |
| P3 | `coop-rot` quand Realm of Thrones sort ; passage 1.5.7 = nouveau manifeste | — |

## 8. Ce qu'on accepte, et ce qu'on refuse

**Accepté** : un montage non supporté par les équipes (Coop + TAOM) reste possible, mais signalé
comme tel dans le pack et dans la console au démarrage.

**Refusé** : télécharger TAOM automatiquement. Ni URL stable, ni licence compatible avec une
redistribution ; le dossier `modpacks/` est la seule voie, et le template dit précisément ce qui
manque.

**Refusé** : ressusciter l'interface WPF comme dépendance. Elle apportait une fenêtre là où AMP
suffit, au prix de Wine, d'un VNC et d'un hôte PowerShell qui ne peut pas fonctionner.

## 9. Ce que ça donne à l'usage

Un montage = une instance AMP. Le panneau affiche le pack, la version de jeu, l'état des modules
et les réglages de jeu ; le bouton Update réassemble et vérifie ; le bouton Start refuse de mentir.
Pour tester trois montages côte à côte, trois instances — les 18 Go de TAOM étant partagés par un
dossier `modpacks/` commun.

## 10. Suivre les évolutions du mod Coop (nightlies)

Le mod Coop bouge vite. La réponse n'est pas de courir après chaque build, c'est de **figer des
paires validées** et de rendre le mouvement visible :

- chaque pack porte `coopBuild` et `gameVersion` ; le template compare avec ce qui est installé et
  refuse de démarrer en cas d'écart, avec un message qui dit quoi faire ;
- `packs/` devient la matrice de compatibilité du projet : `coop` sur `0.1.7 / 1.4.8`,
  `coop-taom` sur `0.1.7 / 1.4.8 + TAOM v2.4.1`, et demain les variantes 1.5.7 ;
- un changement de build côté atelier ne casse donc rien : il **bloque** avec une explication, et
  la mise à jour d'un manifeste est une décision, pas un effet de bord.

**Cible annoncée par l'équipe TAOM** (novembre 2026) : compatibilité TAOM + Coop pour Bannerlord
**1.5.7** avec Coop **0.1.7** (« we are close »). Le jour où ça sort, l'ajout se limite à une entrée
`packs/coop-taom-157.json` : `gameVersion: "1.5.7"`, `coopBuild: "0.1.7"`, et la liste des modules
du build TAOM 2.x. Aucune ligne de code du template ne change.

Trois points à vérifier à ce moment-là, dans cet ordre :

1. que la release Coop de l'atelier livre bien les modules **1.5.7** (le pack les déclare, la
   vérification de version les contrôle — sinon on assemble un TAOM 1.5.7 sur un socle 1.4.8) ;
2. que TAOM est distribué en build **1.5.7** (aujourd'hui `2.0.39`, launcher seul ; ModDB et Nexus
   sont restés en 1.4.8) ;
3. que **War Sails reste exclu** du montage — le DLC progresse côté Coop, mais TAOM le refuse
   toujours, et l'annonce ne dit rien d'une levée de cette contrainte.

Ce qu'il faut surveiller dans les changelogs, parce que c'est ce qui touche le template et non le
jeu : le layout du paquet atelier (`engine/`, `engine/Modules/`, nom de l'exécutable), les
arguments de lancement et la façon dont le serveur prend sa liste de modules, le format de
`server-config.json` / `mod-config.json`, les migrations de sauvegarde, les noms de release du CDN,
et toute mention de TAOM ou de Realm of Thrones côté Coop. Le reste — équilibrage, corrections de
gameplay — ne concerne pas le montage.

## 11. Statut du chantier Coodsz

Le template à interface WPF reste **en suspens** (voir le bandeau du README). Il n'est pas une
dépendance de cette proposition : la seule chose qu'on en réutilise est le savoir-faire — atelier
SteamCMD, préservation des modules, gestion des sauvegardes — déjà présent dans le template CDN.

## 12. Veille — changelogs Coop du 7 au 15 novembre 2026

Relevé des nightly changelogs (développement entre `e365e24` et `c01b576`), filtré sur ce qui
touche le montage :

| Constat | Effet sur le template |
|---|---|
| **Nouvelle clé `allowClientTimeControls`** (15/11) — « Hosts can now stop players from pausing or changing the game speed » | à exposer comme réglage et à écrire dans `server-config.json` |
| **« Added a server setting to prefer specific players as battle host »** (11/11) | deuxième clé nouvelle en une semaine ; son nom n'est pas donné, à identifier sur une instance avant de l'exposer |
| **« The nightly build was missing its War Sails modules »** (8/11) | War Sails arrive sous forme de **modules supplémentaires** : exactement ce que le manifeste `modules` d'un pack sait décrire. Un pack « War Sails » serait donc `modules: [...] + NavalDLC`, et non un réglage |
| **Adresse d'autoconnexion** (9/11) : « the client log staying empty when the game is started with an autoconnect address » | le client Coop accepte une **adresse d'autoconnexion** : c'est la bonne matière pour `Meta.EndpointURIFormat` (le panneau « Se connecter »), bien meilleure que le `steam://connect` du template Coodsz |
| **Sauvegardes autoritaires serveur** (7/11) : Save/Save As/Load retirés du menu client « since the server saves the campaign » | confirme que `SaveName` et `Game Saves/` sont la seule vérité ; notre gestion reste côté serveur |
| **« A save with a party left in an army it already left no longer stops the server from starting »** (11/11) | un monde peut être la cause d'un refus de démarrage : le template doit remonter le message du serveur tel quel et laisser les sauvegardes précédentes intactes (déjà fait par l'étape de backup) |
| **Journaux plus petits sur les sessions longues** (11/11) | moins de pression sur `/var` ; on peut conserver les journaux sans inquiétude |
| 102 à 205 corrections par semaine, puis 102 sur les derniers jours | rythme qui redescend — signe de stabilisation avant la bascule 1.5.7 |
| **Rien** sur le layout du paquet atelier, les arguments de lancement, ni le format de `server-config.json` / `mod-config.json` | la surface dont dépend le template n'a pas bougé en neuf jours |
| Nightlies réservées à des rôles Discord, atelier Steam en retard jusqu'à la release | le template, qui passe par l'atelier, ne voit **que des releases** : le churn nightly ne nous atteint pas directement, ce qui justifie de figer `coopBuild` |

Conclusion : la dépendance utile est plus étroite qu'elle n'en a l'air. Les points à suivre
activement sont **les clés de `server-config.json`** (deux nouvelles en une semaine), **la carte des
options MCM** dont dépend le `settingsProfile`, et **la liste des modules livrés** avec le paquet —
puisqu'un DLC ou un overhaul arrivent tous les deux sous cette forme.

## 13. Référence externe : `PlodyIce/bannerlordcoop-server-manager` (MIT)

Un gestionnaire de serveur Coop écrit en shell, qui fait tourner des serveurs moddés et documente
ses mesures. On ne l'installe pas — sa pile est un Docker Compose qui gère lui-même Wine et
SteamCMD, là où AMP fait déjà ce travail — mais **on en reprend les conclusions**, qui sont
exactement le mode d'emploi d'un serveur Coop moddé. Ce qui compte pour un pack :

**Ce qu'un mod exige sur un serveur dédié** (mesuré par eux, mod par mod) :

1. **une copie serveur de son manifeste** — les frameworks restent dans la liste parce que le
   contrôle d'entrée Coop les compare ; Harmony et UIExtenderEx n'y chargent aucun code ;
2. **un hôte de démarrage** (*startup hook*) qui résout les bibliothèques d'interface depuis le
   module Coop, parce que le moteur charge Coop **après** les mods — sinon « assembly not found » ;
3. **les bibliothèques que le serveur n'a pas** : `StoryMode` et `CustomBattle` du jeu (~3,6 Go de
   dépôt Steam, réduits à ~1 Mo de DLL) — RBM appelle CustomBattle à chaque tick, Diplomacy
   StoryMode au chargement. TAOM les liste dans son ordre de chargement, ce qui aide ;
4. **le runtime Windows Desktop de Microsoft** pour ButterLib — et TAOM embarque ButterLib dans
   `TAOM.Dependencies` ;
5. **le build adapté à la version du jeu** : un serveur dédié rapporte `i-1.-1.-1.-1` comme version,
   donc les mods BUTR prennent le build le plus récent au lieu du bon. Il faut retirer les builds
   plus récents que le jeu du serveur ;
6. **`/no_watchdog`** : sans écran, le premier avertissement d'un mod fait planter le programme de
   surveillance et le serveur avec lui. RBM avertit à chaque démarrage ; TAOM avertira.

**Trois pièges à retenir pour le template :**

- `server-config.json` est du **JSONC** (commentaires et virgules finales) : `jq` ne sait pas le
  lire, et le modifier au motif régulier est la façon de perdre une campagne. On le **génère**.
- La liste de modules du lanceur est figée : tout pack non trivial impose de lancer le moteur
  directement (voir §6).
- Les mods gardent des fichiers propres qu'il faut rendre inscriptibles : `Configs/` du jeu,
  `server-data/` à côté du serveur, et le dossier de réglages que CoopModPatch attend.

Leur catalogue de mods testés (CoopModPatch, Diplomacy, RBM, CC's Banners, Enable Achievement) ne
contient **pas TAOM** : personne n'a encore fait tourner un overhaul de cette taille sur un serveur
Coop, ce qui confirme le statut « non supporté » et l'intérêt de la vérification avant démarrage.

## 14. Realm of Thrones : ce que `rot-coop-installer` apprend (et ce qu'il ne dit pas)

Dépôt `Blazzer10200/rot-coop-installer` (juillet 2026, PowerShell, outil Windows destiné aux
joueurs). **Attention au vocabulaire : son « co-op » est `Bannerlord Together` 0.4.1.4**, un autre
mod que le `Bannerlord Coop` de ce projet. Son profil vérifié est `Realm of Thrones 7.1 +
Bannerlord Together` sur Bannerlord **1.3.15**, War Sails décoché.

Trois conséquences pour nous :

1. **RoT est en retard sur notre version de jeu.** RoT 7.1 est décrit comme « le dernier build non
   War Sails pour 1.3.15 » — alors que le Coop tourne en 1.4.8. Un pack RoT suppose donc que RoT
   publie pour la version du Coop : c'est une contrainte côté mod, pas côté template. À vérifier au
   moment du pack, pas avant.
2. **Les modules RoT se décrivent très bien dans un manifeste** : `ROT-Core`, `ROT-Content`,
   `ROT_Map`, `ROT-Dragon`, avec un piège de nommage (le dossier livré `ROT-Map` doit être renommé
   `ROT_Map`, qui est son identifiant interne — sinon le module n'est pas vu).
3. **La version déclarée peut mentir.** Leur relevé est net : ce build de RoT estampille la version
   **du jeu** dans son `SubModule.xml` au lieu de la sienne. Une vérification qui ne lit que les
   versions déclarées validerait donc un mauvais build.

D'où deux ajouts au modèle de pack :

- chaque module porte une **méthode de vérification** : `version` (SubModule.xml) quand elle est
  fiable, sinon `sha256` d'un fichier, ou `marker` (présence d'une chaîne dans une DLL) ;
- le template sait **exporter le manifeste côté joueurs** — la liste des modules et de leurs
  versions, à comparer telle quelle. C'est la version serveur de leur option « match with a friend »,
  et ça règle le premier échec de connexion Coop : un client dont l'ensemble de modules diffère.

À noter aussi, dans leur approche : ils téléchargent BLSE et les dépendances (Harmony, ButterLib,
UIExtenderEx, MCM) depuis les **releases GitHub officielles**, et jamais les mods de contenu. C'est
exactement la distinction `cdn` / `local` de nos packs — et la même raison : la licence.

## 15. Ce que le dépôt officiel apporte (BannerlordCoop, branche `master`)

Quatre éléments de `deploy/` et de la racine, relevés le 16 novembre 2026 :

**1. `mod-config.default.json` — la structure officielle, et un piège.** Les réglages de campagne
sont **imbriqués** (`difficulty.playerReceivedDamage`, `modOptions.…`), pas plats, et le fichier est
du JSONC commenté. Le commentaire officiel dit ceci, qui compte plus que tout le reste : *« Left
unset on a HEADLESS server (dedicated/container), this defaults to Realistic — the headless profile
would otherwise push quarter damage to every joining player. »* Un serveur dédié à qui on ne dit
rien applique donc **Realistic** aux dégâts subis par les joueurs. C'est le genre de valeur par
défaut qui change le jeu sans que personne ne l'ait choisie : elle doit figurer explicitement dans
le `settingsProfile` d'un pack, jamais être laissée vide par omission.

Notre template CDN mappe déjà correctement l'imbrication (`$.difficulty.*`, `$.modOptions.*`,
43 réglages sur 52) — vérifié sur `bannerlord-coop-cdnconfig.json`. Rien à corriger, mais à
reprendre tel quel.

**2. Pas de serveur Linux natif.** Le `Dockerfile` du dépôt officiel part de
`mcr.microsoft.com/dotnet/sdk:6.0-alpine` et sert uniquement à **compiler les assemblages**
(`DockerPrepare.ps1` copie `TaleWorlds*.dll`, `SandBox*.dll` dans `DockerAssembliesTemp`) : ce n'est
pas une image de serveur. Wine reste donc obligatoire — notre architecture est la bonne, et il n'y a
pas de version native à espérer à court terme.

**3. Les ports officiels.** `deploy/Server Instructions.md` demande de rediriger **4200-4201 UDP**,
et rien d'autre. Cela confirme le choix des ports du template, et l'inutilité de publier 4202/7211.

**4. Le monde d'un overhaul doit être créé ailleurs — et ça concerne TAOM.** Le serveur crée un
monde en copiant le modèle que Coop livre ; un overhaul comme RBM — et très probablement TAOM —
n'installe son monde qu'**au moment de la création de la campagne**. La procédure documentée par
`bannerlord-coop-server-manager` est donc :

1. côté joueur, activer exactement les modules du serveur, dans son ordre, et régler les mods comme
   le serveur les aura (pour RBM : RBM Campaign activé) ;
2. créer une campagne **Sandbox** (jamais Story Mode : le serveur ne sait pas charger une campagne
   Story Mode), aller jusqu'à la carte, sauvegarder sous le nom voulu ;
3. copier le `.sav` dans `Game Saves/` du serveur — le `.json` est écrit à la première sauvegarde
   du serveur.

D'où une exigence pour le pack TAOM : le template doit accepter une **sauvegarde préparée**, déposée
dans un dossier du pack (`modpacks/taom/saves/`), et refuser de « créer un monde » avec un overhaul
qui ne sait pas s'initialiser ainsi. C'est une différence de nature avec le pack `coop`, et elle
mérite d'être visible dans la documentation du pack, pas découverte au premier démarrage.

## 16. Mesure : ModderLords n'est pas pilotable en headless (16 novembre 2026)

ModderLords 1.9.0 (publié le jour de la mesure) a été essayé dans l'image de l'instance.

**Résultat : non.** La release ne contient qu'un `ModderLords.exe` de 144 Mo, application
**graphique** autonome ; il n'y a **aucun binaire `ModderLords.Cli`** dans l'archive, et la
documentation ne cite que deux sous-commandes (`test`, `smoke`), pas de « lancer le serveur ». Sous
Wine, `--help` ne répond rien : le processus part en `Unhandled exception 0xe0434352` et
`nodrv_CreateWindow … no driver could be loaded`. Il lui faut un serveur X, donc un VNC — c'est-à-dire
le coût d'une interface graphique, dans une application plus lourde que celle de Coodsz.

**Ce qu'il apporte quand même, et qui vaut le détour :** deux fichiers de données, `compat-db.json`
et `verified-profiles.json` (JSONC), qui forment un **référentiel de compatibilité partagé avec
Coodsz** — verdicts mesurés mod par mod, rôles serveur, et profils épinglés avec versions,
`workshopId` et `sha256`.

**Et ce référentiel dit de TAOM quelque chose qu'aucun template ne peut corriger :**

| Mod | Verdict | Pourquoi |
|---|---|---|
| `TAOM.Dependencies` | NeedsRecipe | il liste `UIExtenderEx` **en premier** et sans étiquette serveur : le serveur meurt en chargeant un framework d'interface. Il faut ne garder que son amorce et le cœur de réglages de MCM |
| `TAOM` | NeedsRecipe | le crash headless venait de `0Harmony` (build différent, ILMerged, `MarkSequencePoint` absent du .NET 6 du serveur). Avec un **startup hook** résolvant les bibliothèques partagées, il charge — mais seulement en `DependencyOnly` : ses ~51 comportements de campagne ne tournent pas côté serveur. Leur conclusion : *« a data-parity server, not a full TAOM coop server »*, avec divergence attendue. Et aucun serveur TAOM n'a encore atteint `SERVING` : les essais chargeaient la sauvegarde vanilla, qu'aucun monde TAOM ne peut accepter |
| `TAOM_Map` | Works | données seules, aucun code : carte lue, CRC de navmesh constant |
| `LOTRLOME_Armory` | **Broken** | c'est **la** raison pour laquelle un serveur TAOM ne démarrait pas : ses `action_sets.xslt` déclarent des animations dont les données vivent dans un pack client de 1,17 Go que le serveur ne lit pas — 104 à 137 avertissements et 52 à 77 fenêtres modales bloquantes, puis sortie -1. Aucun rôle n'y remède (pas de `<SubModule>` à retirer), et les deux contournements essayés échouent, dont un en violation d'accès native. Verdict : **absent du serveur, présent chez les clients** |
| `TAOM.CoopCompat` | **Broken** | exige le `DedicatedServer.Core.dll` reconstruit du wrapper TAOM-Coop, avec des gardes épinglées par empreinte ; sur le serveur officiel la porte ne s'ouvre jamais. L'utiliser, c'est adopter toute leur pile, qui **remplace les binaires officiels du serveur** |

**Conséquence pour la décision d'architecture :** TAOM + Coop n'est pas un problème de template, il
est bloqué au niveau des mods. Notre couche d'assemblage n'y changerait rien, et ModderLords — qui a
fait ces mesures — n'a lui-même aucun profil TAOM vérifié.

La voie raisonnable devient donc :

1. **garder Coodsz comme serveur coop de référence** (il fonctionne : interface, atelier, lancement,
   licence, reprise de campagne), avec les ports alignés sur 4200 / 4201 / 7210 ;
2. laisser le template mince **documenté comme solution de repli**, pas comme chantier en cours ;
3. réévaluer quand `TAOM.CoopCompat` fonctionnera — c'est-à-dire quand l'équipe TAOM-Coop publiera
   un wrapper qui s'enregistre sur le serveur officiel — ou quand TAOM sortira en 1.5.7 pour Coop.

Autrement dit : la pièce qui manque n'est pas dans notre camp.
