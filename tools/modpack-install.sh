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
# Une url fournie par le panneau prend le pas sur le manifeste du depot : c'est ce
# qui permet de suivre un nouveau build sans modifier le depot. L'empreinte et la
# taille sont reprises si elles sont fournies, sinon l archive est epinglee au
# premier telechargement (voir plus bas).
if [ -n "${MODPACK_URL:-}" ]; then
    log "url fournie par le panneau : $MODPACK_URL"
    DERIVE="$PACKS/$PACK.local.json"
    python3 "$OUTIL" surcharger "$MANIFESTE" "$DERIVE" "$MODPACK_URL" \
        "${MODPACK_SHA256:-}" "${MODPACK_TAILLE:-}" || exit 1
    MANIFESTE="$DERIVE"
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
    [ "$URL" = "-" ] && URL=""
    [ "$SHA" = "-" ] && SHA=""
    [ "$NOM" = "-" ] && NOM=""
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
    REEL_SHA=$(sha256sum "$ARCHIVE" | cut -d' ' -f1)
    EPINGLE="$PACKS/$NOM.sha256"
    if [ -n "$SHA" ]; then
        if [ "$REEL_SHA" != "$SHA" ]; then
            erreur "empreinte de $NOM differente de celle epinglee dans le manifeste"
            erreur "  attendu : $SHA"
            erreur "  obtenu  : $REEL_SHA"
            exit 1
        fi
        log "empreinte de $NOM conforme au manifeste"
    elif [ -f "$EPINGLE" ]; then
        ATTENDU=$(cut -d' ' -f1 "$EPINGLE")
        if [ "$REEL_SHA" != "$ATTENDU" ]; then
            erreur "l archive $NOM a change depuis le premier telechargement"
            erreur "  epinglee : $ATTENDU"
            erreur "  obtenue  : $REEL_SHA"
            erreur "  si c est voulu, effacer $EPINGLE ; sinon remettre la bonne archive"
            exit 1
        fi
        log "empreinte de $NOM conforme a l epinglage local"
    else
        printf '%s  %s\n' "$REEL_SHA" "$NOM" > "$EPINGLE"
        log "aucune empreinte annoncee : $NOM epinglee maintenant ($(printf '%s' "$REEL_SHA" | cut -c1-16)...)"
        log "  pour la fixer durablement, reporter cette valeur dans le manifeste ou le champ Empreinte"
    fi

    # Suivi de version : si l archive a change, les dossiers qu elle avait installes
    # doivent partir avant l extraction, sinon les fichiers de deux builds cohabitent.
    ETAT="$PACKS/.etat-$PACK-$CLE.txt"
    IDS=$(python3 "$OUTIL" modules "$MANIFESTE" "$CLE")
    if [ -f "$ETAT" ]; then
        AVANT=$(head -1 "$ETAT")
        if [ "$AVANT" != "$REEL_SHA" ]; then
            log "l archive $NOM a change : retrait des modules de la version precedente"
            for ident in $(tail -n +2 "$ETAT"); do
                if [ -d "$MODULES/$ident" ]; then
                    rm -rf "$MODULES/$ident" && log "  retire : $ident"
                fi
            done
        fi
    fi
    { printf '%s\n' "$REEL_SHA"; printf '%s\n' "$IDS"; } > "$ETAT"
done <<EOF
$(python3 "$OUTIL" sources "$MANIFESTE")
EOF

# --- 4. extraction ----------------------------------------------------------
# extraire() traite d'un coup tous les modules d'une archive et saute ce qui est
# deja complet : une seule passe par archive suffit, quelle que soit la quantite
# de modules manquants.
while IFS="$(printf '\t')" read -r CLE URL SHA TAILLE NOM; do
    [ -n "${CLE:-}" ] || continue
    [ "$NOM" = "-" ] && continue
    ARCHIVE=""
    [ -f "$PACKS/$NOM" ] && ARCHIVE="$PACKS/$NOM"
    [ -z "$ARCHIVE" ] && [ -f "$CACHE/$NOM" ] && ARCHIVE="$CACHE/$NOM"
    [ -n "$ARCHIVE" ] || { erreur "archive $NOM introuvable pour l extraction"; exit 1; }
    log "extraction depuis $NOM"
    python3 "$OUTIL" extraire "$MANIFESTE" "$ARCHIVE" "$MODULES" || exit 1
done <<EOF
$(python3 "$OUTIL" sources "$MANIFESTE")
EOF

# --- 5. modules pris dans l'installation du jeu -----------------------------
# Le paquet serveur Coop ne livre que cinq modules ; un serveur modde a besoin de
# modules du jeu (CustomBattle, BirthAndDeath...). Ils viennent des fichiers du jeu
# de l'operateur : rien n'est redistribue.
GAME_MODULES="${GAME_MODULES_DIR:-$PACKS/game-modules}"
mkdir -p "$GAME_MODULES"
# Un zip depose dans ce dossier est deballe ici : l operateur n a pas a l ouvrir.
for z in "$GAME_MODULES"/*.zip; do
    [ -f "$z" ] || continue
    log "archive de modules du jeu : $(basename "$z")"
    python3 "$OUTIL" deballer "$z" "$GAME_MODULES" || { erreur "deballage de $z impossible"; exit 1; }
    mv "$z" "$z.deballee"
done
python3 "$OUTIL" copier-jeu "$MANIFESTE" "$MODULES" "$GAME_MODULES" || {
    erreur "des modules doivent etre copies depuis votre installation de Bannerlord"
    erreur "  dossier attendu : ${GAME_MODULES_DIR:-$PACKS/game-modules}"
    exit 1
}

# --- 6. modules d'apparence -------------------------------------------------
# Certains modules exiges par un overhaul ne sont pas livres par le paquet serveur
# (CustomBattle cote Coop). Un module d'apparence satisfait la declaration, pas le
# besoin : il est cree seulement si le manifeste le demande explicitement.
python3 "$OUTIL" apparence "$MANIFESTE" "$MODULES" || true

# --- 7. controle final ------------------------------------------------------
if python3 "$OUTIL" verifier "$MANIFESTE" "$MODULES"; then
    log "modpack $PACK pret"
    exit 0
fi
erreur "modpack $PACK incomplet : voir la liste ci-dessus"
exit 1
