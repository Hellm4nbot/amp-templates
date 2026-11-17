#!/usr/bin/env python3
"""Manifestes de modpack : verification des modules et construction du jeton.

Le serveur Coop dedie recoit la liste des modules a charger en argument, sous la
forme :

    _MODULES_*Native*SandBoxCore*SandBox*Coop*_MODULES_

Ce fichier construit ce jeton depuis un manifeste ordonne et verifie, avant de
lancer quoi que ce soit, que chaque module annonce est reellement present et que
son identifiant correspond a celui declare dans son SubModule.xml.

Usage :
    modpack.py etat     <manifeste.json> <dossier Modules>
    modpack.py verifier <manifeste.json> <dossier Modules>
    modpack.py jeton    <manifeste.json> <dossier Modules>
    modpack.py compat   <compatibilite.json> [<manifeste.json>]

Codes de sortie : 0 tout va bien, 1 module manquant ou incoherent, 2 manifeste
illisible.
"""

import json
import os
import sys
import xml.etree.ElementTree as ET


def charger(chemin):
    with open(chemin, encoding="utf-8-sig") as f:
        return json.load(f)


def _valeur(racine, balise):
    """Valeur d'une balise de SubModule.xml.

    Bannerlord ecrit indifferemment <Id value="Coop"/> (attribut value) ou
    <Id>Coop</Id> (texte) : les deux formes existent selon les mods, et un
    parseur qui ne lit qu'une des deux annonce « identifiant absent » sur un mod
    parfaitement valide.
    """
    noeud = racine.find(balise)
    if noeud is None:
        return ""
    valeur = noeud.get("value")
    if valeur is None:
        valeur = noeud.text
    return (valeur or "").strip()


def identifiant_module(dossier):
    """Identifiant declare par SubModule.xml, ou None si absent/illisible."""
    chemin = os.path.join(dossier, "SubModule.xml")
    if not os.path.isfile(chemin):
        return None
    try:
        racine = ET.parse(chemin).getroot()
    except ET.ParseError:
        return None
    for balise in ("Id", "Name"):
        valeur = _valeur(racine, balise)
        if valeur:
            return valeur
    return None


def version_module(dossier):
    chemin = os.path.join(dossier, "SubModule.xml")
    if not os.path.isfile(chemin):
        return ""
    try:
        racine = ET.parse(chemin).getroot()
    except ET.ParseError:
        return ""
    return _valeur(racine, "Version")


def source_decrite(source):
    """Resume lisible de la provenance d'un module."""
    if source == "engine":
        return "paquet du serveur"
    if isinstance(source, dict):
        if "atelier" in source:
            return "atelier %s" % source["atelier"]
        if "archive" in source:
            return "archive %s/%s" % (source["archive"], source.get("dossier", "?"))
        if "dossier_packs" in source:
            return "dossier de packs : %s" % source["dossier_packs"]
    return "provenance inconnue"


def etat(manifeste, modules_dir):
    lignes = []
    for entree in manifeste.get("modules", []):
        ident = (entree.get("id") or "").strip()
        if not ident:
            continue
        source = entree.get("source", "")
        dossier_attendu = ident
        if isinstance(source, dict) and source.get("dossier"):
            dossier_attendu = source["dossier"]
        chemin = os.path.join(modules_dir, dossier_attendu)
        if not os.path.isdir(chemin):
            chemin = os.path.join(modules_dir, ident)
        present = os.path.isdir(chemin)
        reel = identifiant_module(chemin) if present else None
        lignes.append(
            {
                "id": ident,
                "dossier": dossier_attendu,
                "present": present,
                "id_reel": reel,
                "version": version_module(chemin) if present else "",
                "source": source_decrite(source),
                "coherent": present and (reel is None or reel == ident),
            }
        )
    return lignes


def _normalise(texte):
    return "".join(c for c in (texte or "").lower() if c.isalnum())


def compatibilite(chemin_compat, chemin_manifeste=None):
    """Rapporte ce que les joueurs ont constate, sans rien deduire.

    Deux champs changent tout pour un serveur dedie : un mod heberge « jeu du
    joueur » ne tourne pas sur une instance AMP, et un mod « non teste » n'est pas
    un mod compatible. Les deux sont signales ici plutot que decouverts au
    demarrage.
    """
    try:
        with open(chemin_compat, encoding="utf-8-sig") as f:
            compat = json.load(f)
    except (OSError, ValueError) as e:
        print("compatibilite illisible : %s" % e)
        return 2

    mods = compat.get("mods", [])
    if chemin_manifeste:
        try:
            manifeste = charger(chemin_manifeste)
        except (OSError, ValueError) as e:
            print("manifeste illisible : %s" % e)
            return 2
        connus = {_normalise(m.get("nom")): m for m in mods}
        print("pack %s — rapports connus pour ses modules :" % manifeste.get("nom", "?"))
        trouve = 0
        for entree in manifeste.get("modules", []):
            nom = entree.get("mod") or entree.get("id")
            rapport = connus.get(_normalise(nom))
            if not rapport:
                continue
            trouve += 1
            alertes = []
            if rapport.get("etat") == "non teste":
                alertes.append("NON TESTE")
            if rapport.get("hebergement") == "jeu du joueur":
                alertes.append("heberge par le jeu du joueur : pas de serveur dedie")
            if rapport.get("war_sails") is False:
                alertes.append("War Sails requis desactive")
            print("  %-28s %s" % (nom, "; ".join(alertes) if alertes else "rien a signaler"))
            print("      source : %s" % rapport.get("source_rapport", "?"))
        if not trouve:
            print("  aucun rapport pour ce pack")
        return 0

    print("rapports connus au %s (%s)" % (compat.get("maj", "?"), compat.get("source", "?")))
    for m in mods:
        print(
            "  %-28s etat=%-10s hebergement=%-16s jeu=%s"
            % (m.get("nom", "?"), m.get("etat", "?"), m.get("hebergement", "?"), m.get("jeu", "?"))
        )
    return 0


def main(argv):
    if len(argv) >= 3 and argv[1] == "compat":
        return compatibilite(argv[2], argv[3] if len(argv) > 3 else None)

    if len(argv) != 4 or argv[1] not in ("etat", "verifier", "jeton"):
        print(__doc__.strip().splitlines()[0])
        print("usage : modpack.py {etat|verifier|jeton} <manifeste> <dossier Modules>")
        return 2
    _, action, chemin_manifeste, modules_dir = argv
    try:
        manifeste = charger(chemin_manifeste)
    except (OSError, ValueError) as e:
        print("manifeste illisible (%s) : %s" % (chemin_manifeste, e))
        return 2

    lignes = etat(manifeste, modules_dir)
    presents = [l for l in lignes if l["coherent"]]
    manquants = [l for l in lignes if not l["present"]]
    incoherents = [l for l in lignes if l["present"] and not l["coherent"]]

    if action == "etat":
        print(json.dumps(lignes, ensure_ascii=False, indent=2))
        return 0

    if action == "verifier":
        print("pack %s — %s" % (manifeste.get("nom", "?"), manifeste.get("libelle", "")))
        print("jeu attendu %s / Coop %s" % (manifeste.get("jeu", "?"), manifeste.get("coop", "?")))
        print("%-26s %-9s %-10s %s" % ("module", "present", "version", "provenance"))
        for l in lignes:
            etat_txt = "oui" if l["coherent"] else ("ABSENT" if not l["present"] else "INCOHERENT")
            print(
                "%-26s %-9s %-10s %s"
                % (
                    l["id"],
                    etat_txt,
                    (l["version"] or "-")[:10],
                    l["source"] if l["present"] else l["source"],
                )
            )
        if incoherents:
            for l in incoherents:
                print(
                    "  identifiant different : %s attendu, %s trouve dans le dossier %s"
                    % (l["id"], l["id_reel"] or "aucun SubModule.xml", l["dossier"])
                )
        if manquants or incoherents:
            print(
                "REFUS : %d module(s) manquant(s), %d incoherent(s) sur %d"
                % (len(manquants), len(incoherents), len(lignes))
            )
            return 1
        print("OK : %d modules verifies" % len(lignes))
        return 0

    # jeton
    if manquants or incoherents:
        noms = ", ".join(l["id"] for l in manquants + incoherents)
        print("jeton impossible, modules manquants ou incoherents : %s" % noms)
        return 1
    jeton = "_MODULES_" + "".join("*" + l["id"] for l in presents) + "*_MODULES_"
    print(jeton)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
