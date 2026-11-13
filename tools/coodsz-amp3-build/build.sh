#!/bin/bash
# Construit l'image du template coodszcoop et, sur demande, la publie.
#
#   ./build.sh          construit coodsz-amp:amp3 en local et sous le nom du registre
#   ./build.sh push     construit puis pousse vers $IMAGE (registre prive)
#
# AMP tire ses conteneurs avec podman, qui a son propre stockage : une image
# seulement locale n'est pas visible par AMP et le nom nu est cherche sur
# Docker Hub. D'ou le registre.
set -eu

IMAGE="${IMAGE:-ghcr.io/hellm4nbot/coodsz-amp:amp3}"
LOCAL="coodsz-amp:amp3"
ICI="$(cd "$(dirname "$0")" && pwd)"

echo "construction de $LOCAL (aussi etiquetee $IMAGE)"
docker build -t "$LOCAL" -t "$IMAGE" "$ICI"

case "${1:-build}" in
    build)
        echo "image construite : $LOCAL / $IMAGE"
        ;;
    push)
        echo "publication de $IMAGE"
        docker push "$IMAGE"
        echo "pousse. Sur l'hote AMP, se connecter une fois au registre :"
        echo "  su - amp -c 'podman login ghcr.io -u <compte>'   # jeton read:packages"
        ;;
    *)
        echo "usage: $0 [build|push]"; exit 1
        ;;
esac
