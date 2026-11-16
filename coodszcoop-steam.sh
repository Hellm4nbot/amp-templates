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
    log "aucun compte Steam renseigne (reglage « Steam Username ») : etape ignoree, ce n'est pas une erreur."
    log "les fichiers du serveur dedie ne sont pas recuperes ; renseigne le compte puis relance Update."
    exit 0
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
# Steam ne garde pas forcement sa session : un jeton peut etre revoque (mot de
# passe change, appareils deauthorises, changement de machine). Sans mot de passe
# renseigne, SteamCMD ne peut alors que repondre « Cached credentials not found ».
# On dit donc lequel des deux cas on est, avant de tenter quoi que ce soit.
# Le seul marqueur fiable d'une session en cache est le fichier de sentry
# (ssfn*). config/config.vdf existe apres n'importe quelle execution de steamcmd,
# y compris sans authentification : le prendre pour un jeton faisait annoncer
# « jeton present » juste avant que Steam reponde « Cached credentials not found ».
jeton() {
    if ls "$HOME_SC"/Steam/ssfn* >/dev/null 2>&1; then
        echo present
    else
        echo absent
    fi
}
AVANT="$(jeton)"
# Le code Steam Guard ne se presente jamais d'avance : envoye sur une session
# valide, il la casse (« Two-factor code mismatch »). On ne le fournit qu'en
# second essai, et seulement si Steam le reclame.
if [ -n "$SPASS" ]; then
    set -- +login "$SUSER" "$SPASS"
elif [ "$AVANT" = "present" ]; then
    set -- +login "$SUSER"
    log "session Steam en cache : connexion sans mot de passe"
else
    set -- +login "$SUSER"
    log "aucune session Steam en cache et aucun mot de passe renseigne :"
    log "  renseigne « Steam Password » (et un code Steam Guard frais) puis relance Update."
fi

log "connexion Steam et telechargement de l'atelier $ITEM"
HOME="$HOME_SC" "$SC/steamcmd.sh" "$@" \
    +workshop_download_item 261550 "$ITEM" validate \
    +quit 2>&1 | tee "$LOG"

# Ce que Steam a retenu de la connexion : sans jeton ecrit, le prochain Update
# redemandera le mot de passe, et c'est utile a savoir tout de suite.
# Le code, seulement s'il est reclame.
if ! grep -q "Success. Downloaded item" "$LOG" 2>/dev/null \
    && [ -n "${SGUARD:-}" ] && [ -n "$SPASS" ] \
    && grep -qiE "Steam Guard code|Two-factor code required|need two-factor" "$LOG" 2>/dev/null \
    && ! grep -qiE "Two-factor code mismatch|Invalid Two-factor" "$LOG" 2>/dev/null; then
    log "Steam demande un code : nouvelle tentative avec le code fourni"
    HOME="$HOME_SC" "$SC/steamcmd.sh" +login "$SUSER" "$SPASS" "$SGUARD" \
        +workshop_download_item 261550 "$ITEM" validate \
        +quit 2>&1 | tee "$LOG"
fi

APRES="$(jeton)"
if [ "$APRES" = "present" ] && [ "$AVANT" = "absent" ]; then
    log "jeton Steam ecrit : les prochains Update se passeront du mot de passe"
elif [ "$APRES" = "absent" ] && [ -n "$SPASS" ]; then
    log "aucune session enregistree par SteamCMD : le mot de passe sera redemande au prochain update"
    log "  (mesure : aucun fichier ssfn* n'est ecrit dans ce conteneur, quelle que soit la connexion)"
fi

CONTENT="$HOME_SC/Steam/steamapps/workshop/content/261550"
EXE="$(find "$CONTENT/$ITEM" -maxdepth 3 -name 'BannerlordCoopServer.exe' 2>/dev/null | head -1)"
if [ -z "$EXE" ]; then
    if grep -q "Cached credentials not found" "$LOG" 2>/dev/null; then
        log "Steam n a aucune session en cache pour ce compte, et aucun mot de passe n a ete fourni."
        log "  renseigne « Steam Password » (plus un code Steam Guard frais si le compte en exige un),"
        log "  relance Update, puis vide le mot de passe : la session sera reutilisee ensuite."
    elif grep -qiE 'Invalid Password|Account Logon Denied|Two-factor|Rate Limit|FAILED' "$LOG"; then
        log "CONNEXION STEAM REFUSEE. Renseigne « Steam Password » et, si le compte en exige un,"
        log "un code Steam Guard frais (il expire en ~30 s), relance Update, puis vide les deux champs."
    elif grep -qiE 'Two-factor code mismatch' "$LOG"; then
        log "Le code Steam Guard fourni est perime ou errone : il ne vaut que ~30 secondes."
        log "  si la session existe deja, vide le champ et relance : aucun code n est necessaire."
    else
        log "BannerlordCoopServer.exe introuvable sous $CONTENT/$ITEM — voir $LOG"
    fi
    exit 1
fi

# --- 3. Assemblage du dossier serveur ---
mkdir -p "$SRV"
DS_SRC="$(dirname "$EXE")"
# Une copie interrompue laissait un dossier present mais vide, et le controle
# « deja present » la figeait : le serveur ne pouvait plus demarrer, faute du
# script PowerShell et du bootstrap. On verifie donc le contenu, pas l'existence.
MANQUANTS=""
for f in BannerlordCoopServer.exe Coodsz-Start-ModdedServer.ps1 BannerlordCoop.RuntimeBootstrap.dll; do
    [ -f "$SRV/DedicatedServer/$f" ] || MANQUANTS="$MANQUANTS $f"
done
[ -d "$SRV/DedicatedServer/engine/Modules" ] || MANQUANTS="$MANQUANTS engine/Modules"
if [ -z "$MANQUANTS" ]; then
    log "dossier serveur complet : laisse tel quel (sauvegardes, mods et reglages de l'outil)"
else
    log "dossier serveur incomplet (manque:$MANQUANTS)"
    NEUF=0
    [ -d "$SRV/DedicatedServer" ] || NEUF=1
    mkdir -p "$SRV/DedicatedServer"
    if [ "$NEUF" = "1" ]; then
        # Premiere installation : copie complete, sinon les fichiers non testes
        # (licences, autres scripts, DLL du paquet) manqueraient.
        log "  premiere installation : copie complete du paquet"
        cp -a "$DS_SRC/." "$SRV/DedicatedServer/" || { log "copie du serveur echouee"; exit 1; }
    fi
    # On ne copie QUE ce qui manque : recopier les 2 a 3 Go du paquet pour deux
    # fichiers absents faisait durer chaque Update plusieurs minutes. Un dossier
    # est fusionne (cp -a dir/. dest/), un fichier copie tel quel ; rien n'est
    # efface, donc les mods et les fichiers de l'outil survivent.
    for manque in $([ "$NEUF" = "1" ] && echo "" || echo "$MANQUANTS"); do
        if [ -d "$DS_SRC/$manque" ]; then
            mkdir -p "$SRV/DedicatedServer/$manque"
            cp -a "$DS_SRC/$manque/." "$SRV/DedicatedServer/$manque/" || { log "copie de $manque echouee"; exit 1; }
        else
            cp -a "$DS_SRC/$manque" "$SRV/DedicatedServer/$manque" || { log "copie de $manque echouee"; exit 1; }
        fi
        log "  $manque copie depuis le paquet"
    done
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

# $MODS_DIR ne recoit que les mods d'atelier supplementaires : les modules du
# serveur lui-meme vivent dans engine/Modules, copies avec le paquet. Afficher un
# dossier vide sans le dire laissait croire que rien n'avait ete installe.
SUPPL="$(ls -1 "$MODS_DIR" 2>/dev/null)"
if [ -n "$SUPPL" ]; then
    log "mods d'atelier supplementaires dans $MODS_DIR :"
    printf '%s\n' "$SUPPL" | sed 's/^/  /'
else
    log "aucun mod d'atelier supplementaire : les modules du serveur sont dans engine/Modules"
fi

HOST_JSON="$(find "${WINEPREFIX:-${ROOT}.wine}/drive_c/users" -maxdepth 6 \
    -path '*AppData/Local/Coodsz/Coop/host.json' 2>/dev/null | head -1)"
if [ -n "$HOST_JSON" ] && grep -qi 'DedicatedServer.BannerlordCoopServer.exe' "$HOST_JSON" 2>/dev/null; then
    log "dossier serveur deja renseigne dans l'outil : rien a faire dans « Set server folder »"
else
    log "=============================================================="
    log " a indiquer dans l'outil Coodsz, bouton « Set server folder » :"
    log "   Z:\\AMP\\coodszcoop\\server\\DedicatedServer"
    log "   (BannerlordCoopServer.exe est dans ce dossier)"
    log "=============================================================="
fi
