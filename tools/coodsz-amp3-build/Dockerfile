FROM cubecoders/amp3base:debian

ENV DEBIAN_FRONTEND=noninteractive

# Wine + serveur X/VNC integre + noVNC + polices.
# wine32:i386 est indispensable : sans lui, regedit.exe manque dans syswow64 et
# l'installation des polices echoue, ce qui casse WPF au demarrage.
# TigerVNC (Xvnc) plutot que Xvfb + x11vnc : dans amp3base, x11vnc 0.9.17
# acceptait le TCP sans jamais servir le client, ce qui bloquait noVNC.
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        wine wine64 wine32:i386 \
        tigervnc-standalone-server tigervnc-tools xfonts-base \
        novnc websockify fluxbox x11-utils xdotool feh \
        fonts-liberation2 fonts-dejavu-core fonts-noto-core \
        cabextract p7zip-full unzip curl ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# winetricks : absent des depots Debian 13, indispensable pour corefonts
# (WPF meurt sur MapUnresolvedCharacters sans les vraies Arial/Times/Courier).
RUN curl -fsSL https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks \
        -o /usr/local/bin/winetricks && \
    chmod +x /usr/local/bin/winetricks && \
    /usr/local/bin/winetricks --version 2>/dev/null | head -1

# Enveloppe de l'entrypoint : serveur X/VNC + noVNC, puis /ampstart.sh d'origine.
COPY coodsz-desktop.sh /coodsz-desktop.sh
RUN chmod +x /coodsz-desktop.sh

# noVNC 1.6.0 (paquet Debian) leve « Cannot read properties of undefined
# (reading 'focus') » quand on clique la poignee du panneau lateral avant que la
# session RFB soit connectee : closeControlbar() appelle UI.rfb.focus() et UI.rfb
# n'existe pas encore. L'erreur casse le bouton, pas la session.
# On protege les quatre appels de la page complete. vnc_lite.html n'a pas de
# panneau et reste utilisable telle quelle. Place en fin de fichier pour ne pas
# invalider le cache des couches precedentes.
RUN set -eu; \
    F=/usr/share/novnc/app/ui.js; \
    sed -i -E 's|^([[:space:]]*)UI\.rfb\.focus\(\);|\1if (UI.rfb) { UI.rfb.focus(); }|' "$F"; \
    n="$(grep -c 'if (UI.rfb) { UI.rfb.focus(); }' "$F")"; \
    echo "ui.js : $n appels proteges"; \
    [ "$n" -eq 4 ] || { echo "correctif noVNC non applique ($n/4 attendus)"; exit 1; }

# Les binaires de l'outil Coodsz NE SONT PAS dans cette image : sa licence les
# reserve a un usage prive, aucune redistribution. Ils sont telecharges dans
# l'instance par l'etape de mise a jour du template (releases GitHub + digest).
#
# Le point d'entree de l'image de base doit rester joignable : on l'enveloppe.
ENTRYPOINT ["/usr/bin/tini", "--", "/coodsz-desktop.sh"]
