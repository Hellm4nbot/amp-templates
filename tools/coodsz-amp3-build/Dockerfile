FROM cubecoders/amp3base:debian

ENV DEBIAN_FRONTEND=noninteractive

# Wine + pile graphique virtuelle + polices.
# wine32:i386 est indispensable : sans lui, regedit.exe manque dans syswow64 et
# l'installation des polices echoue, ce qui casse WPF au demarrage.
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        wine wine64 wine32:i386 \
        xvfb x11vnc novnc websockify fluxbox x11-utils xdotool \
        fonts-liberation2 fonts-dejavu-core fonts-noto-core \
        cabextract p7zip-full unzip curl ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# winetricks : absent des depots Debian 13, indispensable pour corefonts
# (WPF meurt sur MapUnresolvedCharacters sans les vraies Arial/Times/Courier).
RUN curl -fsSL https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks \
        -o /usr/local/bin/winetricks && \
    chmod +x /usr/local/bin/winetricks && \
    /usr/local/bin/winetricks --version 2>/dev/null | head -1

# Enveloppe de l'entrypoint : ecran virtuel + noVNC, puis /ampstart.sh d'origine.
COPY coodsz-desktop.sh /coodsz-desktop.sh
RUN chmod +x /coodsz-desktop.sh

# Les binaires de l'outil Coodsz NE SONT PAS dans cette image : sa licence les
# reserve a un usage prive, aucune redistribution. Ils sont telecharges dans
# l'instance par l'etape de mise a jour du template (releases GitHub + digest).
#
# Le point d'entree de l'image de base doit rester joignable : on l'enveloppe.
ENTRYPOINT ["/usr/bin/tini", "--", "/coodsz-desktop.sh"]
