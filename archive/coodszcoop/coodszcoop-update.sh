#!/bin/bash
# Etape de mise a jour du template Coodsz (AMP 3).
#
# Telecharge la derniere release de l'outil depuis GitHub, verifie son empreinte,
# puis remplace le contenu de <instance>/coodszcoop/app/.
#
# Pourquoi un telechargement et pas des binaires dans le depot ou l'image : la
# licence de Coodsz reserve la redistribution. Aucun miroir n'est autorise, donc
# on prend toujours l'archive officielle, et on la controle avec l'empreinte
# publiee dans la release (champ digest de l'API, sinon SHA256SUMS.txt).
#
# Usage : coodszcoop-update.sh <racine> [depot] [motif de l'archive]
#   depot par defaut : Coodsz/Coodsz-Coop-and-Friends
#   motif par defaut : ^Coodsz-Coop-Tools-.*\.zip$
#   variante TAOM    : Coodsz/Coodsz-TAOM   ^Coodsz-TAOM-Tools-.*\.zip$
# Les deux projets publient une archive « Tools » unique ; les archives par
# programme ne servent qu'aux anciennes versions pour se mettre a jour.
set -eu

ROOT="${1:-.}"
DEPOT="${2:-Coodsz/Coodsz-Coop-and-Friends}"
MOTIF="${3:-^Coodsz-Coop-Tools-.*\\.zip$}"
export MOTIF

[ -d "$ROOT" ] || { echo "[coodsz] racine introuvable : $ROOT"; exit 1; }
ROOT="$(cd "$ROOT" && pwd)"
APP="$ROOT/app"
API="https://api.github.com/repos/$DEPOT/releases/latest"

echo "[coodsz] racine : $ROOT"
echo "[coodsz] depot  : $DEPOT"

J="$(curl -fsSL "$API")" || { echo "[coodsz] GitHub injoignable"; exit 1; }

TAG="$(printf '%s' "$J" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("tag_name",""))')"
[ -n "$TAG" ] || TAG="(inconnue)"

read -r URL SIZE <<EOF
$(printf '%s' "$J" | python3 -c '
import os, sys, json, re
m = re.compile(os.environ["MOTIF"])
d = json.load(sys.stdin)
for a in d.get("assets", []):
    if m.match(a["name"]):
        print(a["browser_download_url"], round(a["size"] / 1048576))
        break
')
EOF
SHA="$(printf '%s' "$J" | python3 -c '
import os, sys, json, re
m = re.compile(os.environ["MOTIF"])
d = json.load(sys.stdin)
for a in d.get("assets", []):
    if m.match(a["name"]):
        print((a.get("digest") or "").replace("sha256:", ""))
        break
')"
SUMS_URL="$(printf '%s' "$J" | python3 -c '
import sys, json
d = json.load(sys.stdin)
for a in d.get("assets", []):
    if a["name"] == "SHA256SUMS.txt":
        print(a["browser_download_url"])
        break
')"

[ -n "${URL:-}" ] || { echo "[coodsz] aucune archive ne correspond a $MOTIF dans la release $TAG"; exit 1; }
echo "[coodsz] version $TAG, archive ${SIZE:-?} Mo"

# Sans digest dans l'API, on retombe sur le SHA256SUMS.txt publie dans la release.
if [ -z "$SHA" ] && [ -n "$SUMS_URL" ]; then
    NOM="$(basename "$URL")"
    SHA="$(curl -fsSL "$SUMS_URL" | awk -v n="$NOM" '$2 == n { print $1 }')"
fi

Z="$ROOT/coodsz.zip"
echo "[coodsz] telechargement : $(basename "$URL")"
curl -fsSL "$URL" -o "$Z" || { echo "[coodsz] telechargement echoue"; exit 1; }

if [ -n "$SHA" ]; then
    GOT="$(sha256sum "$Z" | awk '{print $1}')"
    if [ "$GOT" != "$SHA" ]; then
        echo "[coodsz] EMPREINTE NON CONFORME, archive rejetee"
        echo "[coodsz]   attendue : $SHA"
        echo "[coodsz]   obtenue  : $GOT"
        rm -f "$Z"
        exit 1
    fi
    echo "[coodsz] empreinte SHA256 verifiee"
else
    echo "[coodsz] ATTENTION : la release ne publie aucune empreinte, verification impossible"
fi

mkdir -p "$APP"
rm -rf "$APP"/*

# unzip renvoie 1 pour un simple avertissement, et cette archive en produit un
# (« appears to use backslashes as path separators ») alors que l'extraction est
# complete : seule la presence des programmes fait foi, pas le code de retour.
set +e
unzip -o -q "$Z" -d "$APP" 2>/tmp/coodsz-unzip.log
RC=$?
set -e

EXE="$(find "$APP" -maxdepth 3 -name 'Coodsz Coop Server Tool.exe' | head -1)"
if [ -z "$EXE" ]; then
    echo "[coodsz] extraction impossible (unzip code $RC)"
    sed -n '1,5p' /tmp/coodsz-unzip.log 2>/dev/null
    echo "[coodsz] contenu obtenu :"
    find "$APP" -maxdepth 2 2>/dev/null | head -10
    rm -f "$Z"
    exit 1
fi
if [ "$RC" -gt 1 ]; then
    echo "[coodsz] attention : unzip a signale le code $RC, programmes presents"
fi
rm -f "$Z"

echo "[coodsz] programmes presents :"
find "$APP" -maxdepth 3 -name '*.exe' -printf '  %P\n' 2>/dev/null

printf '%s\n' "$TAG" > "$ROOT/.coodsz-version"
echo "[coodsz] outil pret : $EXE (version $TAG)"
