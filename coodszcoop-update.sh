#!/bin/bash
# Etape de mise a jour du template Coodsz Coop (AMP 3).
#
# Telecharge la derniere release de l'outil depuis GitHub, verifie son empreinte,
# puis remplace le contenu de <instance>/coodszcoop/app/.
#
# Pourquoi un telechargement et pas des binaires dans le depot ou l'image : la
# licence de Coodsz reserve la redistribution. Aucun miroir n'est autorise, donc
# on prend toujours l'archive officielle, et on la controle avec l'empreinte
# publiee dans la release (champ digest de l'API, sinon SHA256SUMS.txt).
#
# Usage : coodszcoop-update.sh <racine de l'instance>
set -eu

ROOT="${1:-.}"
[ -d "$ROOT" ] || { echo "[coodsz] racine introuvable : $ROOT"; exit 1; }
ROOT="$(cd "$ROOT" && pwd)"
APP="$ROOT/app"
API="https://api.github.com/repos/Coodsz/Coodsz-Coop-and-Friends/releases/latest"

echo "[coodsz] racine : $ROOT"

J="$(curl -fsSL "$API")" || { echo "[coodsz] GitHub injoignable"; exit 1; }

TAG="$(printf '%s' "$J" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("tag_name",""))')"
[ -n "$TAG" ] || TAG="(inconnue)"

# L'archive a prendre est celle des outils. L'autre zip de la release
# (Coodsz-Coop-and-Friends) ne sert qu'aux anciennes versions pour se mettre a
# jour elles-memes : la description de la release le dit explicitement.
read -r URL SIZE <<EOF
$(printf '%s' "$J" | python3 -c '
import sys, json, re
d = json.load(sys.stdin)
for a in d.get("assets", []):
    if re.match(r"^Coodsz-Coop-Tools-.*\.zip$", a["name"]):
        print(a["browser_download_url"], round(a["size"] / 1048576))
        break
')
EOF
SHA="$(printf '%s' "$J" | python3 -c '
import sys, json, re
d = json.load(sys.stdin)
for a in d.get("assets", []):
    if re.match(r"^Coodsz-Coop-Tools-.*\.zip$", a["name"]):
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

[ -n "${URL:-}" ] || { echo "[coodsz] aucune archive Coodsz-Coop-Tools dans la release $TAG"; exit 1; }
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
unzip -o -q "$Z" -d "$APP" || { echo "[coodsz] extraction impossible"; rm -f "$Z"; exit 1; }
rm -f "$Z"

EXE="$(find "$APP" -maxdepth 3 -name 'Coodsz Coop Server Tool.exe' | head -1)"
[ -n "$EXE" ] || { echo "[coodsz] Coodsz Coop Server Tool.exe introuvable dans l'archive"; exit 1; }

printf '%s\n' "$TAG" > "$ROOT/.coodsz-version"
echo "[coodsz] outil pret : $EXE (version $TAG)"
