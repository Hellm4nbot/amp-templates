#!/bin/bash
# Etape Steam : serveur dedie Coop + mods d'atelier, pour le template Coodsz.
#
# A quoi ca sert : l'outil Coodsz ne telecharge rien lui-meme (« Add mods opens
# mods already on this PC »). Dans un conteneur il n'y a ni Steam ni jeu, donc
# cette etape apporte les fichiers depuis SteamCMD, avec un compte Steam qui
# possede Bannerlord.
#
# Ce qui est telecharge :
#   - l'atelier 3770450698 (Bannerlord Coop), qui contient DedicatedServer/ ;
#   - chaque atelier listé dans le reglage « Mods Workshop IDs ».
# Le serveur est ensuite assemble dans <instance>/server/DedicatedServer, la ou
# l'outil s'attend a trouver BannerlordCoopServer.exe (bouton « Set server
# folder », chemin Windows Z:\AMP\coodszcoop\server\DedicatedServer).
#
# Variables fournies par l'etape de mise a jour :
#   STEAM_USER, STEAM_PASS, STEAM_GUARD, COOP_ITEM, STEAM_MODS
set -eu

ROOT="${1:-.}"
[ -d "$ROOT" ] || { echo "[coodsz-steam] racine introuvable : $ROOT"; exit 1; }
ROOT="$(cd "$ROOT" && pwd)"

SUSER="${STEAM_USER:-}"
SPASS="${STEAM_PASS:-}"
SGUARD="${STEAM_GUARD:-}"
ITEM="${COOP_ITEM:-3770450698}"
MODS="${STEAM_MODS:-}"

SC="$ROOT/steam"
HOME_SC="$ROOT/steamhome"
SRV="$ROOT/server"
LOG="$ROOT/steamcmd-last.log"

log() { echo "[coodsz-steam] $*"; }

if [ -z "$SUSER" ]; then
    log "aucun compte Steam renseigne (reglage « Steam Username ») : etape ignoree."
    log "les fichiers du serveur dedie ne seront pas recuperes."
    exit 1
fi

# --- 1. SteamCMD ---
mkdir -p "$SC" "$HOME_SC"
if [ ! -x "$SC/steamcmd.sh" ]; then
    log "installation de SteamCMD dans $SC"
    if ! curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz -o "$SC/steamcmd.tar.gz"; then
        log "telechargement de SteamCMD echoue"; exit 1
    fi
    tar -xzf "$SC/steamcmd.tar.gz" -C "$SC" || { log "extraction de SteamCMD echouee"; exit 1; }
    rm -f "$SC/steamcmd.tar.gz"
fi

# --- 2. Connexion ---
if [ -n "$SPASS" ]; then
    set -- +login "$SUSER" "$SPASS" ${SGUARD:-}
else
    set -- +login "$SUSER"
fi

log "connexion Steam et telechargement de l'atelier $ITEM"
HOME="$HOME_SC" "$SC/steamcmd.sh" "$@" \
    +workshop_download_item 261550 "$ITEM" validate \
    +quit 2>&1 | tee "$LOG"

CONTENT="$HOME_SC/Steam/steamapps/workshop/content/261550"
EXE="$(find "$CONTENT/$ITEM" -maxdepth 3 -name 'BannerlordCoopServer.exe' 2>/dev/null | head -1)"
if [ -z "$EXE" ]; then
    if grep -qE 'Invalid Password|Cached credentials not found|Account Logon Denied|Two-factor|Rate Limit|FAILED' "$LOG"; then
        log "CONNEXION STEAM REFUSEE. Renseigne « Steam Password » et, si le compte en exige un,"
        log "un code Steam Guard frais (il expire en ~30 s), relance Update, puis vide les deux champs."
    else
        log "BannerlordCoopServer.exe introuvable sous $CONTENT/$ITEM — voir $LOG"
    fi
    exit 1
fi

# --- 3. Assemblage du dossier serveur ---
mkdir -p "$SRV"
DS_SRC="$(dirname "$EXE")"
if [ ! -d "$SRV/DedicatedServer" ]; then
    log "copie du serveur dedie vers $SRV/DedicatedServer"
    cp -a "$DS_SRC" "$SRV/DedicatedServer" || { log "copie du serveur echouee"; exit 1; }
else
    log "dossier serveur deja present : laisse tel quel (sauvegardes, mods et reglages de l'outil)"
    log "  pour repartir d'une copie neuve, supprime $SRV/DedicatedServer puis relance Update"
fi

# --- 4. Mods d'atelier ---
MODS_DIR="$SRV/DedicatedServer/Modules"
mkdir -p "$MODS_DIR"
if [ -n "$MODS" ]; then
    for id in $(printf '%s' "$MODS" | tr ';,' '  '); do
        [ -n "$id" ] || continue
        log "atelier $id (mods)"
        HOME="$HOME_SC" "$SC/steamcmd.sh" "$@" +workshop_download_item 261550 "$id" validate +quit >>"$LOG" 2>&1 || true
        SRC="$CONTENT/$id"
        if [ ! -d "$SRC" ]; then
            log "  atelier $id absent apres telechargement — voir $LOG"; continue
        fi
        # Le mod utile est le dossier qui porte un SubModule.xml, a n'importe
        # quelle profondeur (certains ateliers ajoutent un niveau Modules/).
        while IFS= read -r sub; do
            dossier="$(dirname "$sub")"
            nom="$(basename "$dossier")"
            if [ -d "$MODS_DIR/$nom" ]; then
                log "  $nom deja present, laisse tel quel"
            else
                cp -a "$dossier" "$MODS_DIR/$nom" && log "  $nom installe"
            fi
        done <<EOF
$(find "$SRC" -maxdepth 4 -name 'SubModule.xml' 2>/dev/null)
EOF
    done
fi

log "modules en place dans $MODS_DIR :"
ls -1 "$MODS_DIR" 2>/dev/null | sed 's/^/  /' || true

log "=============================================================="
log " a indiquer dans l'outil Coodsz, bouton « Set server folder » :"
log "   Z:\\AMP\\coodszcoop\\server\\DedicatedServer"
log "   (BannerlordCoopServer.exe est dans ce dossier)"
log "=============================================================="
