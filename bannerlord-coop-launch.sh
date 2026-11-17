#!/bin/bash
# Lanceur du serveur Coop pour le template « Bannerlord Coop (modpacks) ».
#
# Deux chemins, choisis par le manifeste du modpack :
#
#  - pack sans module supplementaire (vanilla) : on garde la ligne de commande
#    eprouvee, `wine BannerlordCoopServer.exe --no-tui --data-dir ...` ;
#  - pack avec modules : on appelle directement le starter .NET en lui passant le
#    jeton de modules, parce que l'exe ne fabrique pas cette liste (aucune trace de
#    _MODULES_ dans le binaire) et chargerait donc les seuls modules par defaut.
#
# Le jeton a la forme `_MODULES_*Native*SandBoxCore*...*_MODULES_` et vient du
# manifeste, pas d'une liste codee en dur.

set -u

ROOT="${ROOT_DIR:-/amp/bannerlordcoop/}"
ROOT="${ROOT%/}"
WID="${WORKSHOP_ID:-3770450698}"
SERV="$ROOT/steamhome/Steam/steamapps/workshop/content/261550/$WID/DedicatedServer"
DATA="$ROOT/CoopData/DedicatedServer"
MODULES="$SERV/engine/Modules"
PACKS="${PACKS_DIR:-$ROOT/packs}"
PACK="${MODPACK:-vanilla}"
PORT="${ENGINE_PORT:-7210}"
REGION="${REGION:-EU}"
JEU="${GAME_VERSION:-1.4.8}"
OUTIL="$ROOT/tools/modpack.py"

log() { echo "[coop] $*"; }
erreur() { echo "[coop] ERREUR : $*" >&2; }

[ -d "$SERV" ] || { erreur "dossier du serveur introuvable : $SERV"; exit 1; }
[ -f "$OUTIL" ] || { erreur "outil modpack introuvable : $OUTIL"; exit 1; }

# Le starter .NET cherche les donnees du mod sous Documents du prefixe Wine. Le
# template, lui, les tient dans CoopData a la racine : sans ce lien, le serveur
# modde demarrerait sur un dossier vide et ne verrait pas la sauvegarde.
PREFIXE="${WINEPREFIX:-$ROOT.wine}"
DOCS="$PREFIXE/drive_c/users/$(id -un)/Documents/Mount and Blade II Bannerlord"
mkdir -p "$(dirname "$DOCS/CoopData")" 2>/dev/null || true
if [ ! -e "$DOCS/CoopData" ] && [ -d "$DATA" ]; then
    mkdir -p "$(dirname "$DOCS")" 2>/dev/null || true
    ln -sfn "$DATA" "$DOCS/CoopData" 2>/dev/null \
        && log "CoopData du prefixe relie a $DATA" \
        || log "lien CoopData impossible : le mod utilisera son dossier par defaut"
fi

# --- manifeste ---------------------------------------------------------------
MANIFESTE="$PACKS/$PACK.json"
if [ ! -f "$MANIFESTE" ]; then
    erreur "manifeste du pack « $PACK » introuvable : $MANIFESTE"
    erreur "  lancer un Update du template (il recupere les manifestes du depot)"
    exit 1
fi

# --- modules supplementaires ? ----------------------------------------------
SUPPLEMENTAIRES=$(python3 - "$MANIFESTE" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8-sig"))
n = sum(1 for e in m.get("modules", []) if e.get("source") != "engine")
print(n)
PY
) || { erreur "manifeste illisible : $MANIFESTE"; exit 1; }

cd "$SERV" || exit 1

if [ "${SUPPLEMENTAIRES:-0}" = "0" ]; then
    log "pack $PACK : aucun module supplementaire, lancement par l exe du paquet"
    log "port moteur $PORT, region $REGION, donnees $DATA"
    exec /usr/bin/wine BannerlordCoopServer.exe --no-tui --data-dir "Z:$DATA" -p "$PORT" --region "$REGION"
fi

# --- jeton de modules --------------------------------------------------------
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

STARTER="engine/bin/Win64_Shipping_Server/TaleWorlds.Starter.DotNetCore.dll"
DOTNET="engine/dotnet/dotnet.exe"
[ -f "$STARTER" ] || { erreur "starter .NET absent : $STARTER"; exit 1; }
[ -f "$DOTNET" ] || { erreur "dotnet embarque absent : $DOTNET"; exit 1; }

exec /usr/bin/wine "$DOTNET" "$STARTER" "$JETON" /dedicatedcustomserver "$PORT" "$REGION" 0
