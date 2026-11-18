#!/bin/bash
# Lanceur du serveur Coop pour le template « Bannerlord Coop (modpacks) ».
#
# Trois responsabilites, dans cet ordre :
#   1. importer une sauvegarde deposee dans le dossier d'import, apres avoir
#      verifie qu'elle a ete creee avec les modules du pack ;
#   2. choisir le chemin de lancement : ligne eprouvee du paquet quand le pack
#      n'ajoute aucun module, sinon starter .NET avec le jeton de modules ;
#   3. refuser de demarrer si le pack est incomplet.
#
# Le jeton a la forme `_MODULES_*Native*SandBoxCore*...*_MODULES_` et vient du
# manifeste, pas d'une liste codee en dur : le binaire du serveur ne fabrique pas
# cette liste (aucune trace de _MODULES_ dedans, verifie sur piece).

set -u

ROOT="${ROOT_DIR:-/amp/bannerlordcoop/}"
ROOT="${ROOT%/}"
WID="${WORKSHOP_ID:-3770450698}"
SERV="$ROOT/steamhome/Steam/steamapps/workshop/content/261550/$WID/DedicatedServer"
DATA="$ROOT/CoopData/DedicatedServer"
SAVES="$DATA/Game Saves"
MODULES="$SERV/engine/Modules"
# Les reglages de dossier sont saisis en chemin relatif (./bannerlordcoop/...), valable
# depuis la racine du shard pendant l Update, mais le serveur demarre avec un autre
# repertoire courant : « ./bannerlordcoop/packs » y designe un dossier inexistant, et le
# manifeste est annonce introuvable alors qu il est en place. On essaie donc les deux
# bases possibles et on garde celle qui existe.
resoudre() {
    # $1 = valeur du reglage, $2 = defaut a utiliser s il est vide
    v="$1"
    [ -n "$v" ] || { echo "$2"; return; }
    case "$v" in
        /*) echo "${v%/}"; return ;;
    esac
    rel="${v#./}"
    for base in "$ROOT" "$(dirname "$ROOT")"; do
        c="${base%/}/$rel"
        if [ -d "$c" ]; then echo "${c%/}"; return; fi
    done
    echo "$(dirname "$ROOT")/${rel%/}"
}
PACKS="$(resoudre "${PACKS_DIR:-}" "$ROOT/packs")"
IMPORT="$(resoudre "${IMPORT_DIR:-}" "$ROOT/import")"
PACK="${MODPACK:-vanilla}"
SAVE="${SAVE_NAME:-saveauto1}"
PORT="${ENGINE_PORT:-7210}"
REGION="${REGION:-EU}"
OUTIL="$ROOT/tools/modpack.py"
# Version de jeu annoncee aux joueurs. Elle vient du reglage, avec la valeur du template en
# secours : le bandeau est imprime avant tout le reste, donc la variable doit exister des ici
# (set -u fait echouer le script sur une variable non definie).
JEU="${GAME_VERSION:-1.4.8}"
COOP_ID="${COOP_BUILD:-0.1.7}"

log() { echo "[coop] $*"; }
erreur() { echo "[coop] ERREUR : $*" >&2; }

# Bandeau imprime avant de passer la main au serveur : une fois le pty en place,
# plus rien de ce script n'apparait dans la console.
banniere() {
    echo
    echo " COMMENT JOUER — prereglage « $PACK »"
    echo "   monde demande      : $SAVE (dans Game Saves)"
    echo "   port moteur        : $PORT (interne, les joueurs ne s y connectent pas)"
    echo "   cote joueurs       : meme version de Bannerlord ($JEU) et du mod Coop ($COOP_ID),"
    echo "                        plus les mods du prereglage s il en a"
    echo "   fiche du prereglage: $ROOT/PRESET-$PACK.md (modules, liens, manipulations)"
    echo
}

[ -d "$SERV" ] || { erreur "dossier du serveur introuvable : $SERV"; exit 1; }
[ -f "$OUTIL" ] || { erreur "outil modpack introuvable : $OUTIL"; exit 1; }

MANIFESTE="$PACKS/$PACK.json"
if [ ! -f "$MANIFESTE" ]; then
    erreur "manifeste du pack « $PACK » introuvable : $MANIFESTE"
    erreur "  dossier des packs : $PACKS"
    erreur "  (reglage « Dossier des packs » : chemin relatif resolu depuis $ROOT)"
    erreur "  lancer un Update du template (il recupere les manifestes du depot)"
    exit 1
fi

# Le moteur cherche ses donnees sous Documents du prefixe Wine ; le template les
# tient dans CoopData a la racine. Sans ce lien, la sauvegarde importee et les
# options de jeu ne seraient pas vues.
UTILISATEUR=$(id -un 2>/dev/null || echo root)
PREFIXE="${WINEPREFIX:-$ROOT.wine}"
DOCS="$PREFIXE/drive_c/users/$UTILISATEUR/Documents/Mount and Blade II Bannerlord"
if [ ! -e "$DOCS/CoopData" ] && [ -d "$DATA" ]; then
    mkdir -p "$(dirname "$DOCS/CoopData")" 2>/dev/null || true
    ln -sfn "$DATA" "$DOCS/CoopData" 2>/dev/null \
        && log "CoopData du prefixe relie a $DATA" \
        || log "lien CoopData impossible : le mod utilisera son dossier par defaut"
fi

# --- 1. import d'une sauvegarde ---------------------------------------------
# Le monde d'un overhaul se cree sur une machine joueur : sans ce chemin, il
# faudrait aller copier des fichiers a la main au fond du conteneur.
if [ -d "$IMPORT" ]; then
    SAV=""
    for f in "$IMPORT"/*.sav; do
        [ -f "$f" ] || continue
        if [ -z "$SAV" ] || [ "$f" -nt "$SAV" ]; then SAV="$f"; fi
    done
    if [ -n "$SAV" ]; then
        log "sauvegarde trouvee dans l import : $(basename "$SAV")"
        if python3 "$OUTIL" sauvegarde "$SAV" "$MANIFESTE"; then
            mkdir -p "$SAVES" || { erreur "creation de $SAVES impossible"; exit 1; }
            CIBLE="$SAVES/$SAVE.sav"
            if [ -f "$CIBLE" ]; then
                HORO=$(date +%Y%m%d-%H%M%S)
                cp -a "$CIBLE" "$CIBLE.avant-$HORO" && log "sauvegarde precedente conservee : $(basename "$CIBLE").avant-$HORO"
            fi
            cp -a "$SAV" "$CIBLE" || { erreur "copie de la sauvegarde impossible"; exit 1; }
            SIDECAR="${SAV%.sav}.json"
            if [ -f "$SIDECAR" ]; then
                cp -a "$SIDECAR" "$SAVES/$SAVE.json" && log "sidecar importe : $SAVE.json (personnages joueurs conserves)"
            else
                log "pas de sidecar .json : sauvegarde de solo, les joueurs creeront leur personnage"
            fi
            HORO=$(date +%Y%m%d-%H%M%S)
            mv "$SAV" "$IMPORT/importe-$HORO-$(basename "$SAV")" 2>/dev/null
            [ -f "$SIDECAR" ] && mv "$SIDECAR" "$IMPORT/importe-$HORO-$(basename "$SIDECAR")" 2>/dev/null
            log "sauvegarde installee sous le nom « $SAVE »"
        else
            erreur "sauvegarde refusee : elle n a pas ete creee avec les modules du pack $PACK"
            erreur "  creer le monde avec exactement ces modules, ou choisir un autre pack"
            exit 1
        fi
    fi
fi

# --- 2. modules supplementaires ? -------------------------------------------
SUPPLEMENTAIRES=$(python3 - "$MANIFESTE" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8-sig"))
print(sum(1 for e in m.get("modules", []) if e.get("source") != "engine"))
PY
) || { erreur "manifeste illisible : $MANIFESTE"; exit 1; }

# --- 3a. pack sans module ajoute : ligne eprouvee du paquet -----------------
if [ "${SUPPLEMENTAIRES:-0}" = "0" ]; then
    log "pack $PACK : aucun module supplementaire, lancement par l exe du paquet"
    log "port moteur $PORT, region $REGION, donnees $DATA"
    banniere
    cd "$SERV" || exit 1
    exec /usr/bin/wine BannerlordCoopServer.exe --no-tui --data-dir "Z:$DATA" -p "$PORT" --region "$REGION"
fi

# --- 3b. pack modde : starter .NET avec le jeton ----------------------------
JETON=$(python3 "$OUTIL" jeton "$MANIFESTE" "$MODULES")
CODE=$?
if [ "$CODE" != "0" ]; then
    erreur "modules incomplets pour le pack $PACK : demarrage refuse"
    erreur "  $JETON"
    erreur "  lancer un Update : il installe les modules manquants"
    exit 1
fi

log "pack $PACK : $SUPPLEMENTAIRES module(s) supplementaire(s)"
log "jeton de modules : $JETON"
log "port moteur $PORT, region $REGION"

BIN="$SERV/engine/bin/Win64_Shipping_Server"
STARTER="TaleWorlds.Starter.DotNetCore.dll"
DOTNET="$SERV/engine/dotnet/dotnet.exe"
[ -f "$BIN/$STARTER" ] || { erreur "starter .NET absent : $BIN/$STARTER"; exit 1; }
[ -f "$DOTNET" ] || { erreur "dotnet embarque absent : $DOTNET"; exit 1; }

# Le repertoire de travail est celui du starter : c'est de la que le moteur
# resout ses assemblies, pas de la racine du serveur.
cd "$BIN" || exit 1

banniere

export DOTNET_ROOT="Z:$SERV/engine/dotnet"
export DOTNET_MULTILEVEL_LOOKUP=0
export COOP_DATA_DIR="C:\\users\\$UTILISATEUR\\Documents\\Mount and Blade II Bannerlord\\CoopData"

# /no_watchdog est obligatoire des qu'un mod est present : le moteur signale ses
# avertissements a un programme de surveillance de bureau ; sans ecran, le premier
# avertissement tue le serveur. Le jeu de base n'avertit pas, les mods si.
exec /usr/bin/wine "$DOTNET" "$STARTER" "$JETON" /dedicatedcustomserver "$PORT" "$REGION" 0 /no_watchdog
