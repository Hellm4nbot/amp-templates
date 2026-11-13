#!/bin/bash
# Ecran virtuel + acces navigateur pour une image AMP 3.
#
# L'entrypoint d'amp3base (/ampstart.sh) ne connait aucun crochet /ampstart.d :
# il execute directement l'agent du shard. On l'enveloppe donc : ce script monte
# le serveur X avec VNC integre et noVNC, puis passe la main a /ampstart.sh sans
# rien changer a son comportement.
set +e

log() { echo "[Coodsz] $*"; }

export DISPLAY=:99

# --- 1. Serveur X avec VNC integre (TigerVNC) ---
# Xvnc remplace Xvfb + x11vnc : un seul processus, et l'authentification par mot
# de passe est celle du serveur, sans couche intermediaire.
# Motif : x11vnc 0.9.17 de Debian 13, dans amp3base, acceptait le TCP mais ne
# servait jamais le client (file d'ecoute pleine, aucune reponse RFB), y compris
# en loopback ; noVNC restait bloque sur « En cours de connexion ».
# Mot de passe, par ordre de priorite :
#   1. reglage « VNC Password » du template (variable COODSZ_VNC_PASSWORD) ;
#   2. celui conserve avec l'instance dans $HOME/.coodsz-vnc.pass ;
#   3. sinon, genere maintenant et conserve.
# Il est reaffiche a chaque demarrage, avec l'adresse de l'interface, pour que
# l'operateur n'ait pas a fouiller le conteneur. Le panneau AMP est le seul a
# voir cette console.
VNPASS_FILE="${HOME:-/home/amp}/.coodsz-vnc.pass"
RFB_FILE="${HOME:-/home/amp}/.coodsz-vnc.rfbauth"
vncpw=""
origine=""

if [ -n "${COODSZ_VNC_PASSWORD:-}" ]; then
    case "$COODSZ_VNC_PASSWORD" in
        *'{{'*)
            # AMP n'a pas substitue le reglage : ne pas prendre le jeton au mot.
            log "reglage VNC Password non substitue, mot de passe genere a la place"
            ;;
        *)
            vncpw="$COODSZ_VNC_PASSWORD"
            origine="impose par le reglage VNC Password"
            ;;
    esac
fi

if [ -z "$vncpw" ] && [ -s "$VNPASS_FILE" ]; then
    vncpw="$(cat "$VNPASS_FILE")"
    origine="conserve avec l'instance (genere au premier demarrage)"
fi

if [ -z "$vncpw" ]; then
    vncpw="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | cut -c1-12)"
    printf '%s' "$vncpw" > "$VNPASS_FILE"
    chmod 600 "$VNPASS_FILE" 2>/dev/null
    origine="genere maintenant, conserve dans $VNPASS_FILE"
fi

# Adresse de l'interface : AMP publie le port declare 6080 ; l'hote et le port
# reel sont ceux de l'onglet Ports de l'instance.
log "=============================================================="
log " interface de l'outil : http://<adresse>:<port>/vnc.html"
log "   <adresse> = machine qui heberge AMP ; <port> = port publie"
log "   pour le port 6080 (onglet Ports de l'instance)."
log " mot de passe VNC : $vncpw"
log "   origine : $origine"
log "=============================================================="

if ! pgrep -x Xvnc >/dev/null 2>&1; then
    # Format de mot de passe TigerVNC (obfusque), ecrit par vncpasswd.
    printf '%s\n' "$vncpw" | vncpasswd -f > "$RFB_FILE" 2>/dev/null
    chmod 600 "$RFB_FILE" 2>/dev/null
    Xvnc :99 -geometry 1280x900 -depth 24 -rfbport 5900 \
         -rfbauth "$RFB_FILE" -SecurityTypes VncAuth \
         -AlwaysShared -desktop coodsz >/tmp/xvnc.log 2>&1 &
    sleep 3
    if pgrep -x Xvnc >/dev/null 2>&1; then
        log "Xvnc en ecoute sur 5900, authentification par mot de passe"
    else
        log "ATTENTION : Xvnc n'a pas demarre (voir /tmp/xvnc.log)"
    fi
fi

# --- 2. Gestionnaire de fenetres (barre de titre, fenetres de dialogue) ---
if ! pgrep -x fluxbox >/dev/null 2>&1; then
    fluxbox >/tmp/fluxbox.log 2>&1 &
    sleep 1
    log "fluxbox demarre"
fi

# --- 3. noVNC : le seul port que le conteneur publie ---
# Le numero vient de COODSZ_WEB_PORT, fixe par le template et declare a l'identique
# dans <name>ports.json : AMP fige le port hote a la creation de l'instance, donc un
# numero courant (6080) y entre en collision avec les services deja installes.
WEBPORT="${COODSZ_WEB_PORT:-6080}"
case "$WEBPORT" in
    ''|*'{{'*) WEBPORT=6080 ;;   # reglage non substitue : ne pas prendre le jeton au mot
esac
if ! pgrep -f websockify >/dev/null 2>&1; then
    websockify --web=/usr/share/novnc "$WEBPORT" 127.0.0.1:5900 >/tmp/websockify.log 2>&1 &
    sleep 1
    if curl -fsS -o /dev/null "http://127.0.0.1:${WEBPORT}/vnc.html"; then
        log "noVNC sur ${WEBPORT}"
    else
        log "ATTENTION : noVNC ne repond pas sur ${WEBPORT} (voir /tmp/websockify.log)"
    fi
fi

# --- 4. Transmettre DISPLAY a l'agent : /ampstart.sh nettoie l'environnement
#        avec env -i et ne garde que ce qui est nomme dans AMP_ADDITIONAL_ENV_VARS.
AMP_ADDITIONAL_ENV_VARS="${AMP_ADDITIONAL_ENV_VARS:-} DISPLAY"
export AMP_ADDITIONAL_ENV_VARS
log "DISPLAY transmis a l'agent AMP"

exec /ampstart.sh
