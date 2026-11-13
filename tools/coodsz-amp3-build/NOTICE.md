# tools/coodsz-amp3-build

Construction de l'image `coodsz-amp:amp3` utilisée par le template `coodszcoop`.

```sh
docker build -t coodsz-amp:amp3 tools/coodsz-amp3-build
```

- `Dockerfile` — `cubecoders/amp3base:debian` + Wine 32/64, Xvfb, x11vnc, noVNC,
  fluxbox, winetricks et les polices. Rien de l'outil Coodsz : sa licence réserve
  la redistribution, aucun binaire n'est présent ici ni dans l'image.
- `coodsz-desktop.sh` — enveloppe de l'entrypoint. `amp3base` n'a pas de crochet
  `/ampstart.d` : ce script monte l'écran virtuel et noVNC, puis `exec /ampstart.sh`.

Les binaires de l'outil sont téléchargés dans l'instance par `coodszcoop-update.sh`
(release GitHub officielle, empreinte vérifiée).

L'étape de mise à jour du template appelle le script à la racine du dépôt
(`coodszcoop-update.sh`) ; il n'y a pas de copie ici, pour éviter deux versions qui
divergent.
