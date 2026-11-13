# tools/coodsz-amp3-build

Construction de l'image `coodsz-amp:amp3` utilisée par le template `coodszcoop`.

```sh
tools/coodsz-amp3-build/build.sh        # construit coodsz-amp:amp3 + l'etiquette du registre
tools/coodsz-amp3-build/build.sh push   # construit puis publie (registre prive)
```

Le `.kvp` désigne l'image par son nom de registre (`ghcr.io/hellm4nbot/coodsz-amp:amp3`),
paquet **privé**. Pourquoi : AMP 3 tire ses conteneurs avec **podman**, dont le stockage
est distinct de celui de docker ; une image seulement locale est invisible pour AMP, qui
cherche alors le nom nu sur Docker Hub et échoue avec `requested access to the resource
is denied`. Sur l'hôte AMP, une connexion au registre est donc nécessaire une fois :

```sh
su - amp -c 'podman login ghcr.io -u Hellm4nbot'   # jeton avec read:packages
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
