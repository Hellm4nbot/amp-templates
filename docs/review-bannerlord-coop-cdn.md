# Review — `Bannerlord Coop Dedicated Server (CDN fallback)`

Template **en production**. Cette review ne le modifie pas : elle liste ce qui casserait, à quel
signal, et la correction proposée. Revue du 16 novembre 2026 (ConfigVersion 7, `amp3` = `145c26c`).

## Ce dont il dépend réellement

| Dépendance | Où c'est écrit | Ce qui arrive si ça change |
|---|---|---|
| L'atelier Coop `3770450698`, paquet `DedicatedServer/` | `WorkshopItemID`, `App.WorkingDir` | l'update dit « serveur absent après le téléchargement » et s'arrête — **bruyant, sans dégât** |
| `BannerlordCoopServer.exe` comme point d'entrée | `App.LinuxCommandLineArgs` | si le lanceur disparaît ou change de nom : échec au démarrage, immédiat |
| Ses options `--no-tui --data-dir -p --region --no-watchdog` | `App.CommandLineArgs` | une option retirée = démarrage qui échoue ou mode TUI bloqué |
| `manifest.json` de la release (CDN) : `windows.url/sha256/name` | script d'update | **repli CDN seulement** : si le schéma change, l'atelier reste la voie normale |
| `release-info.txt` : lignes `Built:`, `Game version:` | script d'update, backups | cosmétique : nommage des sauvegardes et affichage de version |
| `server-config.json` (JSON strict) | `cfg_valide()` | **le point le plus risqué** — voir R1 |
| `engine/Modules` pour préserver les mods inconnus | script d'update | un mod déposé à la main serait écrasé à l'update |

## Risques, du plus grave au plus bénin

**R1 — `server-config.json` illisible ⇒ réinitialisation silencieuse.** `cfg_valide()` fait un
`json.load` strict. Or on sait maintenant que ces fichiers sont **JSONC** chez Coop (`mod-config.json`
l'est, avec commentaires et virgules finales). Si `server-config.json` reçoit un jour un commentaire
ou une virgule finale — ou si un opérateur y touche — le script le déplace en `.illisible-<date>` et
écrit un **défaut** : `saveName=saveauto1`, port 4200, mot de passe vide. Résultat possible : le
serveur démarre sur un monde vide sous un autre nom, alors que la campagne est intacte sur le disque.
*Correction proposée* : lire en tolérant le JSONC, et **refuser** de réinitialiser si `Game Saves/`
n'est pas vide — dans ce cas, s'arrêter en nommant le fichier conservé.

**R2 — le port est écrit en dur à 4200 à l'initialisation.** La ligne qui crée le fichier met
`"port":4200`, alors que le réglage `$GamePort` du template peut valoir autre chose (AMP renumérote
à la création). Si l'initialisation se déclenche, le serveur écoute sur 4200 pendant qu'AMP publie un
autre numéro — exactement le piège rencontré sur le template Coodsz.
*Correction proposée* : initialiser avec `{{$GamePort}}` plutôt qu'avec une constante.

**R3 — aucune garde de version.** Rien ne compare le paquet installé à ce qui est attendu. Le jour où
l'atelier passe de `0.1.7` à une version qui exige Bannerlord 1.5.7, l'update remplace le socle sans
le dire : au mieux le serveur refuse de démarrer, au pire il démarre sur un monde incompatible.
*Correction proposée* : deux réglages (`GameVersion`, `CoopBuild`), lus dans `release-info.txt`, et
un message bloquant explicite en cas d'écart.

**R4 — pas de panneau de connexion.** `Meta.EndpointURIFormat` est vide : pas d'IP publique, pas de
bouton « Se connecter ». Ce n'est pas un risque de casse, c'est une absence — et l'adresse
d'autoconnexion du client Coop permettrait de la combler.

**R5 — `AcceptEula` par défaut à `false`.** Une instance neuve démarre sur une question posée en
console ; `App.HasWriteableConsole=True` permet d'y répondre, mais un opérateur distant verra un
serveur « qui ne démarre pas ». Passer le défaut à `true`, la licence restant consultable dans le
paquet.

**R6 — pas de mods, par construction.** Le template lance le **lanceur**, dont la liste de modules
est figée. Ce n'est pas un défaut pour la production actuelle (le serveur est vanilla), mais il faut
le savoir : toute demande « ajoute un mod » sort de ce template, elle n'y sera jamais réglable.

## Ce qui est solide, et qu'il ne faut pas casser

- atelier en voie principale, CDN en repli — l'échec d'une voie n'empêche pas l'autre ;
- vérification d'empreinte de l'archive, cache réutilisé ;
- sauvegarde avant remplacement, avec nommage par version sortante, et conservation de
  `Game Saves`, `server-config.json`, `eula.txt` et `mod-config.json` ;
- préservation des modules inconnus dans `engine/Modules` (sauvegarde/restauration autour du
  remplacement) ;
- `--no-watchdog` déjà passé : sans lui, le premier avertissement d'un mod tuerait le serveur ;
- 52 réglages, dont 43 mappés dans `$.difficulty.*` et `$.modOptions.*` — l'imbrication est correcte,
  et `difficulty.playerReceivedDamage` est bien renseigné, ce qui évite le défaut headless
  « Realistic » qui appliquerait quart de dégâts sans que personne ne l'ait demandé.

## Verdict

Rien ne menace la production aujourd'hui : les deux voies d'installation sont indépendantes et les
échecs sont bruyants. Les trois points à traiter **avant** la prochaine bascule de version sont R1
(réinitialisation silencieuse), R2 (port en dur) et R3 (absence de garde). Ce sont trois corrections
locales, sans changement d'architecture.
