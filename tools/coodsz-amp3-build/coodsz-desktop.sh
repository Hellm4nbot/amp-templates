#!/bin/bash
# Ecran virtuel + acces navigateur pour une image AMP 3.
#
# L'entrypoint d'amp3base (/ampstart.sh) ne connait aucun crochet /ampstart.d :
# il execute directement l'agent du shard. On l'enveloppe donc : ce script monte
# l'ecran virtuel, le serveur VNC protege par mot de passe et noVNC, puis passe
# la main a /ampstart.sh sans rien changer a son comportement.
set +e

log() { echo "[Coodsz] $*"; }

export DISPLAY=:99

# --- 1. Ecran virtuel ---
if ! pgrep -x Xvfb >/dev/null 2>&1; then
    Xvfb :99 -screen 0 1280x900x24 >/tmp/xvfb.log 2>&1 &
    sleep 2
    log "Xvfb demarre sur :99"
fi

# --- 2. Gestionnaire de fenetres (barre de titre, fenetres de dialogue) ---
if ! pgrep -x fluxbox >/dev/null 2>&1; then
    fluxbox >/tmp/fluxbox.log 2>&1 &
    sleep 1
    log "fluxbox demarre"
fi

# --- 3. VNC, uniquement en local, servi par le navigateur ---
# noVNC n'a aucune authentification propre et le port 6080 est publie : le mot
# de passe est donc demande par le serveur VNC lui-meme, au premier affichage.
#   - COODSZ_VNC_PASSWORD a la priorite si fourni ;
#   - sinon mot de passe genere une fois, conserve dans $HOME/.coodsz-vnc.pass
#     ($HOME est un montage persistant prepare par le spire d'AMP 3).
VNPASS_FILE="${HOME:-/home/amp}/.coodsz-vnc.pass"
RFB_FILE="${HOME:-/home/amp}/.coodsz-vnc.rfbauth"
if [ -n "${COODSZ_VNC_PASSWORD:-}" ]; then
    vncpw="$COODSZ_VNC_PASSWORD"
elif [ -s "$VNPASS_FILE" ]; then
    vncpw="$(cat "$VNPASS_FILE")"
else
    vncpw="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | cut -c1-12)"
    printf '%s' "$vncpw" > "$VNPASS_FILE"
    chmod 600 "$VNPASS_FILE" 2>/dev/null
    log "mot de passe VNC genere : $vncpw  (conserve dans $VNPASS_FILE)"
fi

if ! pgrep -x x11vnc >/dev/null 2>&1; then
    if ! x11vnc -storepasswd "$vncpw" "$RFB_FILE" >/dev/null 2>&1; then
        log "ATTENTION : x11vnc -storepasswd a echoue"
    fi
    chmod 600 "$RFB_FILE" 2>/dev/null
    x11vnc -display :99 -localhost -rfbport 5900 -rfbauth "$RFB_FILE" \
           -forever -shared -quiet >/tmp/x11vnc.log 2>&1 &
    sleep 1
    if pgrep -x x11vnc >/dev/null 2>&1; then
        log "x11vnc en ecoute locale sur 5900, authentification par mot de passe"
    else
        log "ATTENTION : x11vnc n'a pas demarre (voir /tmp/x11vnc.log)"
    fi
fi

# --- 4. noVNC : le seul port que le conteneur publie ---
if ! pgrep -f websockify >/dev/null 2>&1; then
    websockify --web=/usr/share/novnc 6080 localhost:5900 >/tmp/websockify.log 2>&1 &
    sleep 1
    if curl -fsS -o /dev/null http://127.0.0.1:6080/vnc.html; then
        log "noVNC sur 6080"
    else
        log "ATTENTION : noVNC ne repond pas sur 6080 (voir /tmp/websockify.log)"
    fi
fi

# --- 5. Transmettre DISPLAY a l'agent : /ampstart.sh nettoie l'environnement
#        avec env -i et ne garde que ce qui est nomme dans AMP_ADDITIONAL_ENV_VARS.
AMP_ADDITIONAL_ENV_VARS="${AMP_ADDITIONAL_ENV_VARS:-} DISPLAY"
export AMP_ADDITIONAL_ENV_VARS
log "DISPLAY transmis a l'agent AMP"

exec /ampstart.sh
