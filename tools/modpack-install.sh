#!/bin/bash
# Installe un modpack : archive verifiee, modules extraits, etat controle.
#
# Usage : modpack-install.sh <pack> <dossier Modules> <dossier de packs> [<cache>]
#
# Le manifeste est cherche d'abord dans le dossier de packs (<pack>.json), puis
# telecharge depuis le depot. L'archive est cherchee dans le dossier de packs,
# puis telechargee dans le cache. Dans les deux cas l'empreinte et la taille sont
# verifiees avant toute extraction : une archive differente de celle epinglee est
# refusee, pas installee « au cas ou ».
#
# Aucun binaire tiers n'est redistribue : le script telecharge l'original.

set -u

PACK="${1:-}"
MODULES="${2:-}"
PACKS="${3:-}"
CACHE="${4:-${PACKS:-/tmp}}"
DEPOT_MANIFESTES="https://raw.githubusercontent.com/Hellm4nbot/amp-templates/main/modpacks"
OUTIL="$(dirname "$0")/modpack.py"

log() { echo "[modpack] $*"; }
erreur() { echo "[modpack] ERREUR : $*" >&2; }

[ -n "$PACK" ] && [ -n "$MODULES" ] && [ -n "$PACKS" ] || {
    erreur "usage : modpack-install.sh <pack> <dossier Modules> <dossier de packs> [<cache>]"
    exit 2
}
[ -f "$OUTIL" ] || { erreur "outil introuvable : $OUTIL"; exit 2; }
mkdir -p "$MODULES" "$PACKS" "$CACHE" || exit 2

# --- 1. manifeste ------------------------------------------------------------
MANIFESTE="$PACKS/$PACK.json"
if [ ! -f "$MANIFESTE" ]; then
    log "manifeste $PACK absent du dossier de packs : recuperation depuis le depot"
    if ! curl -fsSL --max-time 60 -o "$MANIFESTE.tmp" "$DEPOT_MANIFESTES/$PACK.json"; then
        erreur "manifeste $PACK introuvable (ni local, ni dans le depot)"
        rm -f "$MANIFESTE.tmp"
        exit 2
    fi
    mv "$MANIFESTE.tmp" "$MANIFESTE"
fi
log "manifeste : $MANIFESTE"
python3 "$OUTIL" verifier "$MANIFESTE" "$MODULES" 2>/dev/null | head -3 || true

# --- 2. ce que les joueurs ont constate -------------------------------------
COMPAT="$PACKS/compatibilite.json"
if [ ! -f "$COMPAT" ]; then
    curl -fsSL --max-time 30 -o "$COMPAT.tmp" "$DEPOT_MANIFESTES/compatibilite.json" 2>/dev/null \
        && mv "$COMPAT.tmp" "$COMPAT" || rm -f "$COMPAT.tmp"
fi
if [ -f "$COMPAT" ]; then
    python3 "$OUTIL" compat "$COMPAT" "$MANIFESTE" 2>/dev/null || true
fi

# --- 3. archives : presence, taille, empreinte ------------------------------
while IFS="$(printf '\t')" read -r CLE URL SHA TAILLE NOM; do
    [ -n "${CLE:-}" ] || continue
    if [ -z "$URL" ] || [ -z "$NOM" ]; then
        erreur "source $CLE sans url : a deposer a la main dans $PACKS"
        exit 1
    fi
    ARCHIVE="$PACKS/$NOM"
    if [ ! -f "$ARCHIVE" ]; then
        ARCHIVE="$CACHE/$NOM"
        if [ ! -f "$ARCHIVE" ]; then
            log "telechargement de $NOM (source $CLE)"
            if ! curl -fsSL -C - --retry 2 --max-time 7200 -o "$ARCHIVE.part" "$URL"; then
                erreur "telechargement de $NOM echoue"
                exit 1
            fi
            mv "$ARCHIVE.part" "$ARCHIVE"
        else
            log "archive deja en cache : $NOM"
        fi
    else
        log "archive fournie dans le dossier de packs : $NOM"
    fi

    REEL_TAILLE=$(stat -c %s "$ARCHIVE" 2>/dev/null || echo 0)
    if [ -n "$TAILLE" ] && [ "$TAILLE" != "0" ] && [ "$REEL_TAILLE" != "$TAILLE" ]; then
        erreur "taille de $NOM inattendue : $REEL_TAILLE octets, $TAILLE attendus"
        exit 1
    fi
    if [ -n "$SHA" ]; then
        REEL_SHA=$(sha256sum "$ARCHIVE" | cut -d' ' -f1)
        if [ "$REEL_SHA" != "$SHA" ]; then
            erreur "empreinte de $NOM differente de celle epinglee"
            erreur "  attendu : $SHA"
            erreur "  obtenu  : $REEL_SHA"
            exit 1
        fi
        log "empreinte de $NOM conforme"
    else
        log "aucune empreinte epinglee pour $NOM : taille verifiee seulement"
    fi
done <<EOF
$(python3 "$OUTIL" sources "$MANIFESTE")
EOF

# --- 4. extraction ----------------------------------------------------------
# extraire() traite d'un coup tous les modules d'une archive et saute ce qui est
# deja complet : une seule passe par archive suffit, quelle que soit la quantite
# de modules manquants.
while IFS="$(printf '\t')" read -r CLE URL SHA TAILLE NOM; do
    [ -n "${CLE:-}" ] || continue
    ARCHIVE=""
    [ -f "$PACKS/$NOM" ] && ARCHIVE="$PACKS/$NOM"
    [ -z "$ARCHIVE" ] && [ -f "$CACHE/$NOM" ] && ARCHIVE="$CACHE/$NOM"
    [ -n "$ARCHIVE" ] || { erreur "archive $NOM introuvable pour l extraction"; exit 1; }
    log "extraction depuis $NOM"
    python3 "$OUTIL" extraire "$MANIFESTE" "$ARCHIVE" "$MODULES" || exit 1
done <<EOF
$(python3 "$OUTIL" sources "$MANIFESTE")
EOF

# --- 5. controle final ------------------------------------------------------
if python3 "$OUTIL" verifier "$MANIFESTE" "$MODULES"; then
    log "modpack $PACK pret"
    exit 0
fi
erreur "modpack $PACK incomplet : voir la liste ci-dessus"
exit 1
