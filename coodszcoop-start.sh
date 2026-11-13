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

# --- 3. Registre : substitutions de polices et rendu WPF sans GPU ---
for paire in "Segoe UI:Liberation Sans" "Arial:Liberation Sans" "Calibri:Liberation Sans" "Tahoma:Liberation Sans" "Times New Roman:Liberation Serif" "Courier New:Liberation Mono"; do
    nom=${paire%%:*}
    remp=${paire#*:}
    wine reg add "HKCU\\Software\\Wine\\Fonts\\Replacements" /v "$nom" /d "$remp" /f >/dev/null 2>&1
done
wine reg add "HKCU\\Software\\Microsoft\\Avalon.Graphics" /v DisableHWAcceleration \
    /t REG_DWORD /d 1 /f >/dev/null 2>&1

# --- 4. Lancement ---
log "lancement de $EXE"
cd "$(dirname "$EXE")" || exit 1
exec wine "$EXE"
