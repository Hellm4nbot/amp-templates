#!/bin/bash
# Installe un modpack : archives verifiees, modules en place, etat controle.
#
# Usage : modpack-install.sh <pack> <dossier Modules> <dossier de packs> [<cache>]
#
# Le manifeste est cherche dans le dossier de packs (<pack>.json), puis telecharge
# depuis le depot. Chaque archive est cherchee dans le dossier de packs, puis
# telechargee dans le cache ; sa TAILLE et son EMPREINTE sont controlees avant
# toute extraction. Une archive differente de celle epinglee est refusee, pas
# installee « au cas ou ».
#
# Deux destinations possibles pour une archive :
#   modules        (defaut)  -> modules extraits dans engine/Modules du serveur
#   game-modules            -> modules du jeu, deballes dans le dossier du jeu
#
# Aucun binaire tiers n'est redistribue : le script telecharge l'original.

set -u

PACK="${1:-}"
MODULES="${2:-}"
PACKS="${3:-}"
CACHE="${4:-${PACKS:-/tmp}}"
GAME_MODULES="${GAME_MODULES_DIR:-$PACKS/game-modules}"
DEPOT_MANIFESTES="https://raw.githubusercontent.com/Hellm4nbot/amp-templates/main/modpacks"
OUTIL="$(dirname "$0")/modpack.py"

# Le calcul d empreinte prend une demi-heure sur une archive de 19 Go et un disque charge,
# et l update le refaisait a chaque passage. La taille et la date de modification suffisent
# a garantir que le fichier n a pas bouge : on garde le dernier resultat a cote de l archive
# et on ne recalcule que si l un des deux a change.
empreinte_archive() {
    _f="$1"
    _stamp="${_f}.empreinte"
    _info=$(stat -c '%s %Y' "$_f" 2>/dev/null || echo "0 0")
    if [ -f "$_stamp" ]; then
        _cache=$(cat "$_stamp" 2>/dev/null)
        case "$_cache" in
            "$_info "*)
                echo "$_cache" | cut -d' ' -f3
                return 0
                ;;
        esac
    fi
    # l avancement part sur la sortie d erreur, l empreinte seule sur la sortie standard
    _sha=$(python3 "$OUTIL" empreinte "$_f")
    printf '%s %s\n' "$_info" "$_sha" > "$_stamp" 2>/dev/null || true
    echo "$_sha"
}

log() { echo "[modpack] $*"; }
erreur() { echo "[modpack] ERREUR : $*" >&2; }

[ -n "$PACK" ] && [ -n "$MODULES" ] && [ -n "$PACKS" ] || {
    erreur "usage : modpack-install.sh <pack> <dossier Modules> <dossier de packs> [<cache>]"
    exit 2
}
[ -f "$OUTIL" ] || { erreur "outil introuvable : $OUTIL"; exit 2; }
mkdir -p "$MODULES" "$PACKS" "$CACHE" "$GAME_MODULES" || exit 2

# --- 0. zips deposes a la main dans le dossier des modules du jeu -------------
# Avant tout controle : un zip depose la est deballe ici, sinon la source serait
# declaree manquante alors que les fichiers sont deja la.
for z in "$GAME_MODULES"/*.zip; do
    [ -f "$z" ] || continue
    log "archive de modules du jeu deposee a la main : $(basename "$z")"
    python3 "$OUTIL" deballer "$z" "$GAME_MODULES" || { erreur "deballage de $z impossible"; exit 1; }
    mv "$z" "$z.deballee"
done

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

# Une url fournie par le panneau prend le pas sur le manifeste, source par source :
# c'est ce qui permet de suivre un nouveau build sans modifier le depot. Le
# manifeste d'origine n'est jamais reecrit, donc vider le champ revient a l'ancien
# comportement.
if [ -n "${MODPACK_URL:-}" ] || [ -n "${GAME_MODULES_URL:-}" ]; then
    DERIVE="$PACKS/$PACK.local.json"
    # Le manifeste derive n est plus recopie du manifeste frais : il est FUSIONNE avec celui
    # deja present. Un cp simple effacait les URL reelles que l operateur avait saisies (le
    # depot public ne porte que des hotes neutres), et l update suivant repartait sur
    # archives.example.invalid. L existant gagne, la base complete les cles nouvelles, et les
    # modules sont apparies par identifiant pour qu un module ajoute au depot soit repris.
    python3 - "$MANIFESTE" "$DERIVE" <<'PYFUSION' || exit 1
import json, os, sys
base_p, derive_p = sys.argv[1], sys.argv[2]
def charger(p):
    try:
        with open(p, encoding="utf-8-sig") as f:
            return json.load(f)
    except Exception:
        return {}
base = charger(base_p)
existant = charger(derive_p) if os.path.isfile(derive_p) else {}
out = dict(existant)
for cle, valeur in base.items():
    out.setdefault(cle, valeur)
if isinstance(base.get("modules"), list) and isinstance(existant.get("modules"), list):
    par_id = {m.get("id"): m for m in existant["modules"] if isinstance(m, dict)}
    fusion = []
    for m in base["modules"]:
        if not isinstance(m, dict):
            continue
        fusion.append(par_id.get(m.get("id"), m))
    fusion += [m for m in existant["modules"]
               if isinstance(m, dict) and m.get("id") not in {x.get("id") for x in fusion}]
    out["modules"] = fusion
tmp = derive_p + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
os.replace(tmp, derive_p)
PYFUSION
    # Une URL de pack ne vaut que pour l archive principale : l appliquer a toutes les
    # sources ecrasait l archive de compatibilite (52 Ko) par les 22 Go du pack. Les sources
    # sont donc classees — modules du jeu, compatibilite, puis archive principale (la
    # premiere rencontree) — et une source qui garde un hote neutre est signalee.
    MAIN_FAIT=0
    while IFS="$(printf '\t')" read -r CLE DESTINATION; do
        [ -n "${CLE:-}" ] || continue
        [ "$DESTINATION" = "-" ] && DESTINATION="modules"
        if [ "$DESTINATION" = "game-modules" ]; then
            if [ -n "${GAME_MODULES_URL:-}" ]; then
                log "url des modules du jeu fournie par le panneau : $GAME_MODULES_URL"
                python3 "$OUTIL" surcharger "$DERIVE" "$DERIVE" "$GAME_MODULES_URL" \
                    "${GAME_MODULES_SHA256:-}" "" "$CLE" || exit 1
            else
                log "modules du jeu : aucune url au panneau, la source $CLE reste au manifeste"
            fi
            continue
        fi
        case "$CLE" in
            *compat*)
                if [ -n "${COMPAT_URL:-}" ]; then
                    log "url de l archive de compatibilite fournie par le panneau : $COMPAT_URL"
                    python3 "$OUTIL" surcharger "$DERIVE" "$DERIVE" "$COMPAT_URL" \
                        "${COMPAT_SHA256:-}" "" "$CLE" || exit 1
                else
                    log "compatibilite : aucune url au panneau, la source $CLE reste au manifeste"
                fi
                ;;
            *)
                if [ -n "${MODPACK_URL:-}" ] && [ "$MAIN_FAIT" = 0 ]; then
                    log "url du pack fournie par le panneau : $MODPACK_URL (source $CLE)"
                    python3 "$OUTIL" surcharger "$DERIVE" "$DERIVE" "$MODPACK_URL" \
                        "${MODPACK_SHA256:-}" "${MODPACK_TAILLE:-}" "$CLE" || exit 1
                    MAIN_FAIT=1
                elif [ -n "${MODPACK_URL:-}" ]; then
                    log "source $CLE laissee au manifeste (l url du panneau vaut pour l archive principale)"
                fi
                ;;
        esac
    done <<EOF
$(python3 "$OUTIL" cles "$MANIFESTE")
EOF
    MANIFESTE="$DERIVE"
fi

log "manifeste : $MANIFESTE"

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
while IFS="$(printf '\t')" read -r CLE URL SHA TAILLE NOM DESTINATION; do
    [ -n "${CLE:-}" ] || continue
    [ "$URL" = "-" ] && URL=""
    [ "$SHA" = "-" ] && SHA=""
    [ "$NOM" = "-" ] && NOM=""
    [ "$DESTINATION" = "-" ] && DESTINATION="modules"
    # Le nom seul suffit : une archive sans url se depose dans le dossier de packs,
    # son empreinte fait foi. Sans nom, en revanche, il n y a rien a chercher.
    if [ -z "$NOM" ]; then
        # Sans url, une source n'est acceptable que si ses modules sont deja en
        # place (archive deposee a la main puis deballee).
        if [ "$DESTINATION" = "game-modules" ]; then
            MANQUE=""
            for ident in $(python3 "$OUTIL" modules "$MANIFESTE" jeu); do
                [ -f "$GAME_MODULES/$ident/SubModule.xml" ] || MANQUE="$MANQUE $ident"
            done
            if [ -z "$MANQUE" ]; then
                log "modules du jeu deja en place dans $GAME_MODULES"
                continue
            fi
            erreur "modules du jeu manquants ($MANQUE ) et aucune url fournie"
            erreur "  deposer l archive zip dans $GAME_MODULES, ou renseigner « URL des modules du jeu »"
        else
            erreur "source $CLE sans url : a deposer a la main dans $PACKS"
        fi
        exit 1
    fi
    ARCHIVE="$PACKS/$NOM"
    if [ ! -f "$ARCHIVE" ]; then
        ARCHIVE="$CACHE/$NOM"
        if [ ! -f "$ARCHIVE" ] && [ -z "$URL" ]; then
            erreur "archive $NOM absente de $PACKS et aucune url dans le manifeste"
            erreur "  la deposer dans $PACKS : l empreinte du manifeste fera foi"
            exit 1
        fi
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
    REEL_SHA=$(empreinte_archive "$ARCHIVE")
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

    if [ "$DESTINATION" = "game-modules" ]; then
        log "modules du jeu : deballage de $NOM dans $GAME_MODULES"
        python3 "$OUTIL" deballer "$ARCHIVE" "$GAME_MODULES" || {
            erreur "deballage de $NOM impossible"
            exit 1
        }
        continue
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

# --- 4. extraction des modules du serveur -----------------------------------
# extraire() traite d'un coup tous les modules d'une archive et saute ce qui est
# deja complet : une seule passe par archive suffit.
while IFS="$(printf '\t')" read -r CLE URL SHA TAILLE NOM DESTINATION; do
    [ -n "${CLE:-}" ] || continue
    [ "$NOM" = "-" ] && continue
    [ "$DESTINATION" = "game-modules" ] && continue
    ARCHIVE=""
    [ -f "$PACKS/$NOM" ] && ARCHIVE="$PACKS/$NOM"
    [ -z "$ARCHIVE" ] && [ -f "$CACHE/$NOM" ] && ARCHIVE="$CACHE/$NOM"
    [ -n "$ARCHIVE" ] || { erreur "archive $NOM introuvable pour l extraction"; exit 1; }
    log "extraction depuis $NOM"
    python3 "$OUTIL" extraire "$MANIFESTE" "$ARCHIVE" "$MODULES" "$CLE" || exit 1
done <<EOF
$(python3 "$OUTIL" sources "$MANIFESTE")
EOF

# --- 5. modules pris dans l'installation du jeu -----------------------------
# Le paquet serveur Coop ne livre que cinq modules ; un serveur modde a besoin de
# modules du jeu (CustomBattle, BirthAndDeath...). Ils viennent des fichiers du jeu
# de l'operateur : rien n'est redistribue.
python3 "$OUTIL" copier-jeu "$MANIFESTE" "$MODULES" "$GAME_MODULES" || {
    erreur "des modules doivent etre copies depuis votre installation de Bannerlord"
    erreur "  dossier attendu : $GAME_MODULES"
    exit 1
}

# --- 6. modules d'apparence -------------------------------------------------
# Un module d'apparence satisfait une dependance declaree, pas le besoin : il n'est
# cree que si le manifeste le demande explicitement.
python3 "$OUTIL" apparence "$MANIFESTE" "$MODULES" || true

# --- 7. controle final ------------------------------------------------------
if python3 "$OUTIL" verifier "$MANIFESTE" "$MODULES"; then
    log "modpack $PACK pret"
    exit 0
fi
erreur "modpack $PACK incomplet : voir la liste ci-dessus"
exit 1
