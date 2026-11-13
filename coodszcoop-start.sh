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

# --- 2b. Mot de passe et adresse de l'interface ---
# L'entrypoint de l'image genere le mot de passe et l'ecrit dans $HOME, mais sa
# sortie ne va que dans `podman logs` : la console AMP ne relaie que ce qu'ecrit
# l'application. C'est donc ici qu'on le reaffiche, a chaque demarrage.
PW_FILE="${HOME:-/home/amp}/.coodsz-vnc.pass"
log "interface : http://<adresse>:8642/vnc.html (port publie pour l'interface, onglet Ports)"
# Le fichier est la seule valeur sure : c'est lui que l'entrypoint a passe a
# vncpasswd, donc c'est lui que Xvnc exige — que le mot de passe vienne du
# reglage VNC Password, d'un demarrage precedent ou d'une generation.
if [ -s "$PW_FILE" ]; then
    log "mot de passe VNC : $(cat "$PW_FILE")"
else
    log "mot de passe VNC : introuvable dans $PW_FILE (regarde la console du conteneur : podman logs)"
fi

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
