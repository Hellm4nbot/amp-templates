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

## 6. Le point à mesurer avant d'écrire le reste

**Comment imposer l'ordre de chargement au serveur headless.** Trois pistes, à départager par
l'expérience sur l'instance existante :

1. le fichier que lit le serveur Coop (`modded-server-modules.txt` / `modded-server-selection.json`) ;
2. l'ordre des `DependedModules` dans les `SubModule.xml` ;
3. un argument de `BannerlordCoopServer.exe`.

Une heure de mesure avec un module factice et le journal du serveur tranche. Tant que ce point
n'est pas réglé, tout le reste serait speculative.

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
