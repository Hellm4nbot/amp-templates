#!/usr/bin/env python3
"""Ecrit les reglages exposes au panneau dans CoopData/mod-config.json.

Pourquoi ce fichier existe : les champs « mc_* » du template portent un
ParamFieldName du genre `$.modOptions.warSails`, mais AMP ne fusionne que dans
le fichier declare par le metaconfig (server-config.json), ou ces chemins
n existent pas — mesure du 21/11 : « 34 JSONPath target(s) not found », et
aucun mod-config.json cree. Les valeurs du panneau n atteignaient donc jamais le
mod. On les ecrit ici, dans le seul fichier que Coop lit.

Le fichier du mod est du JSONC : commentaires, virgules finales, BOM. On ne le
reecrit pas entier — on remplace la valeur des cles concernees et on insere les
absentes dans leur section, en laissant le reste du texte intact.

Usage :
    modconfig.py ecrire <chemin/mod-config.json> <fichier-de-paires>
    modconfig.py etat   <chemin/mod-config.json>

Le fichier de paires porte une ligne par reglage : `section.cle=valeur`.
Les types sont deduits de la valeur : true/false -> booleen, nombre -> nombre,
[..] ou liste separee par des virgules -> tableau, le reste -> chaine.
"""

import json
import os
import re
import sys

VRAI = {"true", "yes", "on"}
FAUX = {"false", "no", "off"}


def valeur_json(brut):
    """Convertit une valeur du panneau en valeur JSON.

    L ordre compte : « 0 » doit rester l entier 0 et non le booleen false, et une
    liste d identifiants Steam separes par des virgules ne doit pas etre prise
    pour un nombre decimal — les deux erreurs ont ete vues a la mise au point.
    """
    v = brut.strip()
    if v == "":
        return None
    bas = v.lower()
    if bas in VRAI:
        return True
    if bas in FAUX:
        return False
    if re.fullmatch(r"-?\d+", v):
        return int(v)
    if re.fullmatch(r"-?\d+\.\d+", v):
        return float(v)
    if v.startswith("[") and v.endswith("]"):
        try:
            return json.loads(v)
        except ValueError:
            interieur = v[1:-1].strip()
            return [x.strip().strip('"') for x in interieur.split(",")] if interieur else []
    if "," in v:
        return [x.strip() for x in v.split(",") if x.strip()]
    return v


def sans_commentaires(texte):
    """Retire commentaires // et /* */ en respectant les chaines."""
    sortie = []
    i = 0
    dedans = False
    while i < len(texte):
        c = texte[i]
        if dedans:
            sortie.append(c)
            if c == "\\":
                if i + 1 < len(texte):
                    sortie.append(texte[i + 1])
                    i += 2
                    continue
            elif c == '"':
                dedans = False
            i += 1
            continue
        if c == '"':
            dedans = True
            sortie.append(c)
        elif texte.startswith("//", i):
            fin = texte.find("\n", i)
            i = len(texte) if fin < 0 else fin
            continue
        elif texte.startswith("/*", i):
            fin = texte.find("*/", i + 2)
            i = len(texte) if fin < 0 else fin + 2
            continue
        else:
            sortie.append(c)
        i += 1
    propre = "".join(sortie)
    # virgules finales : autorisees par le mod, refusees par json
    return re.sub(r",(\s*[}\]])", r"\1", propre)


def valeur_en_texte(valeur):
    if isinstance(valeur, bool):
        return "true" if valeur else "false"
    if isinstance(valeur, (list, tuple)):
        return "[" + ", ".join(json.dumps(x, ensure_ascii=False) for x in valeur) + "]"
    return json.dumps(valeur, ensure_ascii=False)


def plage_section(texte, section):
    """Renvoie (debut, fin) de l interieur d une section objet, ou None."""
    m = re.search(r'"%s"\s*:\s*\{' % re.escape(section), texte)
    if not m:
        return None
    debut = m.end()
    profondeur = 1
    i = debut
    dedans = False
    while i < len(texte):
        c = texte[i]
        if dedans:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                dedans = False
        elif c == '"':
            dedans = True
        elif c == "{":
            profondeur += 1
        elif c == "}":
            profondeur -= 1
            if profondeur == 0:
                return (debut, i)
        i += 1
    return None


def fin_valeur(texte, debut):
    """Renvoie la fin de la valeur JSON qui commence a `debut` (espaces ignores).

    Un motif regulier ne suffit pas ici : une valeur de tableau contient des
    virgules (`["7656...", "7656..."]`), et s arreter a la premiere virgule
    coupe le tableau en deux — c est ce qui a casse le fichier au deuxieme
    passage lors de la mise au point.
    """
    i = debut
    while i < len(texte) and texte[i] in " \t\r\n":
        i += 1
    if i >= len(texte):
        return i
    c = texte[i]
    if c == '"':
        i += 1
        while i < len(texte):
            if texte[i] == "\\":
                i += 2
                continue
            if texte[i] == '"':
                return i + 1
            i += 1
        return i
    if c in "[{":
        ferm = "]" if c == "[" else "}"
        profondeur = 0
        dedans = False
        while i < len(texte):
            ch = texte[i]
            if dedans:
                if ch == "\\":
                    i += 2
                    continue
                if ch == '"':
                    dedans = False
            elif ch == '"':
                dedans = True
            elif ch == c:
                profondeur += 1
            elif ch == ferm:
                profondeur -= 1
                if profondeur == 0:
                    return i + 1
            i += 1
        return i
    while i < len(texte) and texte[i] not in ",}\r\n":
        i += 1
    return i


def ecrire_cle(texte, section, cle, valeur):
    """Ecrit une cle dans une section. Regarde (texte, action)."""
    entete = re.search(r'"%s"\s*:\s*\{' % re.escape(section), texte)
    if not entete:
        return texte, "section absente"
    plage = plage_section(texte, section)
    if not plage:
        return texte, "section illisible"
    debut, fin = plage
    bloc = texte[debut:fin]
    entete_cle = re.search(r'("?%s"?\s*:\s*)' % re.escape(cle), bloc)
    neuf = valeur_en_texte(valeur)
    if entete_cle:
        i_debut = entete_cle.end()
        i_fin = fin_valeur(bloc, i_debut)
        if bloc[i_debut:i_fin].strip() == neuf:
            return texte, "deja"
        bloc = bloc[:i_debut] + neuf + bloc[i_fin:]
        return texte[:debut] + bloc + texte[fin:], "remplace"
    corps = bloc.rstrip()
    sep = "" if corps.strip() == "" else ("," if not corps.rstrip().endswith(",") else "")
    insertion = '%s\n    "%s": %s' % (sep, cle, neuf)
    if corps == "":
        insertion = '\n    "%s": %s\n  ' % (cle, neuf)
    return texte[:debut] + bloc[:len(corps)] + insertion + bloc[len(corps):] + texte[fin:], "ajoute"


def creation(sections_voulues):
    """Fichier minimal quand aucun mod-config.json n existe encore."""
    base = {}
    for section, cles in sections_voulues.items():
        base[section] = dict(cles)
    return json.dumps(base, indent=2, ensure_ascii=False) + "\n"


def main():
    if len(sys.argv) < 3:
        print((__doc__ or "").strip().splitlines()[0])
        return 2
    action, chemin = sys.argv[1], sys.argv[2]

    if action == "etat":
        if not os.path.exists(chemin):
            print("absent")
            return 0
        brut = open(chemin, "rb").read().decode("utf-8-sig", "replace")
        try:
            donnees = json.loads(sans_commentaires(brut))
        except ValueError as exc:
            print("illisible : %s" % exc)
            return 1
        options = donnees.get("modOptions", {})
        print("warSails=%s battleSize=%s (%d cles modOptions)"
              % (options.get("warSails"), options.get("battleSize"), len(options)))
        return 0

    if action != "ecrire" or len(sys.argv) < 4:
        print("usage : modconfig.py ecrire <fichier> <paires>")
        return 2

    paires = []
    with open(sys.argv[3], encoding="utf-8") as f:
        for ligne in f:
            ligne = ligne.rstrip("\n")
            if not ligne or "=" not in ligne:
                continue
            nom, brut = ligne.split("=", 1)
            if "." not in nom:
                continue
            section, cle = nom.split(".", 1)
            valeur = valeur_json(brut)
            if valeur is None:
                continue
            paires.append((section, cle, valeur))

    if not paires:
        print("aucun reglage a ecrire")
        return 0

    bom = False
    texte = None
    if os.path.exists(chemin):
        brut = open(chemin, "rb").read()
        bom = brut.startswith(b"\xef\xbb\xbf")
        texte = brut.decode("utf-8-sig", "replace")
    if texte is None:
        voulues = {}
        for section, cle, valeur in paires:
            voulues.setdefault(section, {})[cle] = valeur
        texte = creation(voulues)
        ecrites, ajoutees, faites = len(paires), len(paires), []
    else:
        ecrites = ajoutees = 0
        faites = []
        manquantes = {}
        for section, cle, valeur in paires:
            texte, action_cle = ecrire_cle(texte, section, cle, valeur)
            if action_cle == "section absente":
                manquantes.setdefault(section, {})[cle] = valeur
                continue
            faites.append("%s.%s:%s" % (section, cle, action_cle))
            if action_cle == "ajoute":
                ajoutees += 1
            ecrites += 1
        # une section entierement absente (fichier d une version plus ancienne) :
        # on l ajoute avant la derniere accolade, sans toucher au reste.
        for section, cles in manquantes.items():
            corps = ",\n  \"%s\": %s" % (
                section,
                json.dumps(cles, indent=2, ensure_ascii=False).replace("\n", "\n  "),
            )
            fin = texte.rstrip()
            if fin.endswith("}"):
                texte = fin[:-1].rstrip() + corps + "\n}\n"
                ecrites += len(cles)
                ajoutees += len(cles)
                faites.append("%s:+section" % section)

    donnees = texte.encode("utf-8")
    if bom:
        donnees = b"\xef\xbb\xbf" + donnees
    dossier = os.path.dirname(chemin)
    if dossier:
        os.makedirs(dossier, exist_ok=True)
    with open(chemin, "wb") as f:
        f.write(donnees)

    # verification : le fichier doit rester lisible par le mod
    relu = open(chemin, "rb").read().decode("utf-8-sig", "replace")
    try:
        json.loads(sans_commentaires(relu))
    except ValueError as exc:
        print("ATTENTION : resultat illisible (%s)" % exc)
        return 1
    print("%d reglage(s) ecrit(s), %d ajoute(s) : %s" % (ecrites, ajoutees, ", ".join(faites[:6])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
