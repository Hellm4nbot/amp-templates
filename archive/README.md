# Archive des templates

Templates retirés de la liste, mais conservés avec leur historique et leurs fichiers.

## bannerlord-coop — « Bannerlord Coop Dedicated Server »

Remplacé par **bannerlord-coop-cdn** (atelier SteamCMD en voie principale, repli sur le CDN de
l'équipe). La version archivée ne savait installer que depuis l'atelier : le jour où l'atelier refuse
une publication, elle n'avait aucune seconde source.

- `bannerlord-coop.kvp.archive` — renommé, sinon un scan récursif du dépôt le proposerait encore
- `bannerlord-coopconfig.json`, `-metaconfig.json`, `-ports.json`, `-updates.json`

**Une instance déjà créée sur ce template continue de fonctionner** : sa définition est en cache
côté AMP, elle n'est pas relue depuis le dépôt. L'archivage ne fait que retirer le template de la
liste de création.

Pour le réactiver : renommer le `.kvp.archive` en `.kvp` et le remettre à la racine du dépôt.

## blcoop2 — « Bannerlord Coop Dedicated Server v2 (CDN) »

Archivé le 2026-11-21 : aucune instance ne l'a jamais utilisé. Portait le script d'Update en
base64 dans `UpdateSourceArgs`, une forme qui rend toute correction invisible à un `grep` et qui
oblige à décoder, éditer, réencoder, redécoder et `bash -n` avant de savoir ce qu'on a écrit. Le
travail qu'il portait (atelier puis CDN, modules du jeu, garde de version) vit dans
`bannerlord-coop` et `bannerlord-coop-cdn`, sous forme de fichiers lisibles.

## coodszcoop — « Coodsz Coop Server Tool (AMP 3) »

Archivé le 2026-11-21 : deux instances avaient été créées, elles ne sont plus utilisées. L'outil
n'existe que pour Windows (WPF), donc sous Wine dans un écran virtuel Xvfb, avec son interface
en noVNC — beaucoup de surface pour un confort de configuration que le panneau AMP remplace.
Les fichiers restent ici : la recette Wine (préfixe préparé à l'exécution, clé Avalon, mot de
passe Xvnc) est documentée dans le `README.md` à la racine et vaut pour tout outil Windows
graphique sous AMP 3.
