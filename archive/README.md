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
