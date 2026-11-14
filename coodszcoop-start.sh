#!/bin/bash
# Lance l'outil Coodsz dans l'ecran virtuel monte par l'image coodsz-amp:amp3.
#
# Execute par l'agent AMP 3 avec les variables du template : DISPLAY=:99,
# WINEPREFIX=<racine de l'instance>.wine, WINEDEBUG=-all.
# Le prefixe Wine est prepare ici et non a la construction de l'image : il doit
# appartenir a l'utilisateur de l'instance et survivre aux recreations du
# conteneur.
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
log() { echo "[coodsz] $*"; }

EXE="$(find "$ROOT/app" -maxdepth 3 -name 'Coodsz Coop Server Tool.exe' 2>/dev/null | head -1)"
if [ -z "$EXE" ]; then
    log "outil absent. Lance une mise a jour (Update) : l'archive officielle sera telechargee depuis GitHub."
    exit 1
fi

export DISPLAY="${DISPLAY:-:99}"
export WINEPREFIX="${WINEPREFIX:-$ROOT/.wine}"
export WINEDEBUG="${WINEDEBUG:--all}"
log "prefixe Wine : $WINEPREFIX"

# --- 1. Prefixe ---
if [ ! -d "$WINEPREFIX/drive_c" ]; then
    log "creation du prefixe Wine"
    wineboot -i >/tmp/wineboot.log 2>&1
    wineserver -w 2>/dev/null
fi

# --- 2. Polices ---
# Sans les vraies Arial/Times/Courier, WPF meurt sur MapUnresolvedCharacters.
FD="$WINEPREFIX/drive_c/windows/Fonts"
mkdir -p "$FD"
# Garde sur un temoin, jamais sur arial.ttf : le repli Liberation ecrit ce meme
# fichier, donc un garde sur arial.ttf ferait sauter winetricks pour toujours
# apres un premier echec, et WPF replanterait sans que rien ne le signale.
STAMP="$WINEPREFIX/.corefonts-ok"
if [ ! -f "$STAMP" ]; then
    if command -v winetricks >/dev/null 2>&1; then
        log "installation des corefonts (winetricks), cela prend une minute"
        if winetricks -q corefonts >/tmp/corefonts.log 2>&1; then
            wineserver -w 2>/dev/null
            [ -f "$FD/arial.ttf" ] && touch "$STAMP"
        else
            log "winetricks a echoue, voir /tmp/corefonts.log"
        fi
    fi
fi
if [ ! -f "$STAMP" ]; then
    # Repli : Liberation est metriquement compatible et suffit a WPF pour demarrer.
    LIB=/usr/share/fonts/truetype/liberation
    log "corefonts indisponibles, repli sur Liberation"
    cp -f "$LIB/LiberationSans-Regular.ttf"     "$FD/arial.ttf"    2>/dev/null
    cp -f "$LIB/LiberationSans-Bold.ttf"        "$FD/arialbd.ttf"  2>/dev/null
    cp -f "$LIB/LiberationSans-Italic.ttf"      "$FD/ariali.ttf"   2>/dev/null
    cp -f "$LIB/LiberationSans-BoldItalic.ttf"  "$FD/arialbi.ttf"  2>/dev/null
    cp -f "$LIB/LiberationSerif-Regular.ttf"    "$FD/times.ttf"    2>/dev/null
    cp -f "$LIB/LiberationSerif-Bold.ttf"       "$FD/timesbd.ttf"  2>/dev/null
    cp -f "$LIB/LiberationMono-Regular.ttf"     "$FD/cour.ttf"     2>/dev/null
    cp -f "$LIB/LiberationSans-Regular.ttf"     "$FD/segoeui.ttf"  2>/dev/null
    cp -f "$LIB/LiberationSans-Bold.ttf"        "$FD/segoeuib.ttf" 2>/dev/null
    cp -f "$LIB/LiberationSans-Regular.ttf"     "$FD/tahoma.ttf"   2>/dev/null
    cp -f "$LIB/LiberationSans-Regular.ttf"     "$FD/calibri.ttf"  2>/dev/null
    cp -f "$LIB/LiberationSans-Bold.ttf"        "$FD/calibrib.ttf" 2>/dev/null
fi
log "polices presentes : $(ls "$FD" 2>/dev/null | wc -l) fichiers"

# --- 2b. Mot de passe VNC : appliquer le reglage du panneau, et l'afficher ---
# L'entrypoint de l'image (PID 1) ne recoit pas les variables du template : il
# choisit le mot de passe sans jamais voir le reglage « VNC Password ». Ici elles
# arrivent, puisque c'est l'agent AMP qui nous lance avec App.EnvironmentVariables.
# Donc : quand le reglage est renseigne, on reecrit le fichier d'authentification
# et on redemarre Xvnc — necessaire, Xvnc ne lit son rfbauth qu'au demarrage.
# Sans reglage, on ne touche a rien : le mot de passe de l'entrypoint, conserve
# avec l'instance, reste en vigueur.
VNC_HOME="${HOME:-/home/amp}"
PW_FILE="$VNC_HOME/.coodsz-vnc.pass"
RFB_FILE="$VNC_HOME/.coodsz-vnc.rfbauth"
vncpw=""
origine=""

case "${COODSZ_VNC_PASSWORD:-}" in
    ''|*'{{'*)
        # vide, ou jeton que AMP n'a pas substitue : ne pas le prendre au mot
        ;;
    *)
        vncpw="$COODSZ_VNC_PASSWORD"
        origine="reglage VNC Password"
        ;;
esac

if [ -z "$vncpw" ]; then
    if [ -s "$PW_FILE" ]; then
        vncpw="$(cat "$PW_FILE")"
        origine="conserve avec l'instance"
    else
        vncpw="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | cut -c1-12)"
        printf '%s' "$vncpw" > "$PW_FILE"
        chmod 600 "$PW_FILE" 2>/dev/null
        origine="genere maintenant, conserve dans $PW_FILE"
    fi
fi

# Fiabilite d'abord : si le redemarrage de Xvnc ne prend pas, on le signale et on
# laisse le mot de passe precedent plutot que d'annoncer un mot de passe faux.
if [ "$origine" = "reglage VNC Password" ] && [ "$vncpw" != "$(cat "$PW_FILE" 2>/dev/null || true)" ]; then
    log "reglage VNC Password different de celui en vigueur : redemarrage de Xvnc"
    pkill -x fluxbox 2>/dev/null
    pkill -x Xvnc 2>/dev/null
    for _ in $(seq 1 20); do pgrep -x Xvnc >/dev/null 2>&1 || break; sleep 0.5; done
    rm -f /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null
    printf '%s\n' "$vncpw" | vncpasswd -f > "$RFB_FILE" 2>/dev/null
    chmod 600 "$RFB_FILE" 2>/dev/null
    Xvnc :99 -geometry 1280x900 -depth 24 -rfbport 5900 \
         -rfbauth "$RFB_FILE" -SecurityTypes VncAuth \
         -AlwaysShared -desktop coodsz >/tmp/xvnc.log 2>&1 &
    sleep 3
    if pgrep -x Xvnc >/dev/null 2>&1; then
        log "Xvnc redemarre : le reglage VNC Password est applique"
    else
        log "ATTENTION : Xvnc n'a pas redemarre (voir /tmp/xvnc.log) — mot de passe inchange"
        vncpw="$(cat "$PW_FILE" 2>/dev/null || echo '?')"
        origine="precedent, le redemarrage de Xvnc a echoue"
    fi
    fluxbox >/tmp/fluxbox.log 2>&1 &
    sleep 1
fi

log "=============================================================="
log " interface de l'outil : http://<adresse>:8642/vnc.html"
log "   <adresse> = machine qui heberge AMP ; 8642 = port TCP de l'onglet Ports"
log " mot de passe VNC : $vncpw"
log "   origine : $origine"
log "=============================================================="

# --- 3. Registre : substitutions de polices et rendu WPF sans GPU ---
for paire in "Segoe UI:Liberation Sans" "Arial:Liberation Sans" "Calibri:Liberation Sans" "Tahoma:Liberation Sans" "Times New Roman:Liberation Serif" "Courier New:Liberation Mono"; do
    nom=${paire%%:*}
    remp=${paire#*:}
    wine reg add "HKCU\\Software\\Wine\\Fonts\\Replacements" /v "$nom" /d "$remp" /f >/dev/null 2>&1
done
wine reg add "HKCU\\Software\\Microsoft\\Avalon.Graphics" /v DisableHWAcceleration \
    /t REG_DWORD /d 1 /f >/dev/null 2>&1

# --- 3b. Dossier serveur prerempli dans host.json ---
# L'outil garde ses reglages dans %LOCALAPPDATA%\Coodsz\Coop\host.json, et le
# chemin du serveur dedie est la cle ServerExecutable (bouton « Set server
# folder »). Le preremplir evite la boite de dialogue de fichiers sous Wine, qui
# est penible en VNC. Rien n'est touche si l'operateur a deja choisi un chemin
# valide, ni si le fichier n'existe pas encore (l'outil le cree a son premier
# lancement : le preremplissage prend effet au demarrage suivant).
SERVER_EXE="$ROOT/server/DedicatedServer/BannerlordCoopServer.exe"
HOST_JSON="$WINEPREFIX/drive_c/users/$(id -un 2>/dev/null || echo amp)/AppData/Local/Coodsz/Coop/host.json"
if [ -f "$SERVER_EXE" ] && [ -f "$HOST_JSON" ] && command -v python3 >/dev/null 2>&1; then
    ZWIN="Z:$(printf '%s' "$SERVER_EXE" | tr '/' '\\\\')"
    python3 - "$HOST_JSON" "$ZWIN" <<'PYSQL'
import json, os, sys
chemin, exe = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(chemin))
except Exception as e:
    print("[coodsz] host.json illisible (%s) : laisse tel quel" % e)
    raise SystemExit(0)
actuel = d.get("ServerExecutable") or ""
# Z: est la racine du conteneur : un chemin deja renseigne se verifie sur place.
if actuel and os.path.exists(actuel.replace("Z:", "", 1).replace("\\", "/")):
    print("[coodsz] dossier serveur deja renseigne : %s" % actuel)
    raise SystemExit(0)
d["ServerExecutable"] = exe
tmp = chemin + ".tmp"
json.dump(d, open(tmp, "w"), indent=2)
os.replace(tmp, chemin)
print("[coodsz] dossier serveur prerempli dans host.json : %s" % exe)
PYSQL
fi

# --- 4. Lancement ---
log "lancement de $EXE"
cd "$(dirname "$EXE")" || exit 1
exec wine "$EXE"
