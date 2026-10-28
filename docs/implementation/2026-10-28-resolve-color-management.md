# Choix de gestion des couleurs — 28 octobre 2026

## Comportement

Le sélecteur Resolve « Gestion des couleurs » propose Conversion Rec709-A (valeur initiale) et Kodak 2383. La préférence `resolveColorManagement` est mémorisée, propagée à la création directe et aux scripts Workspace, y compris lors de leur régénération automatique. Un choix absent ou inconnu utilise Conversion Rec709-A.

Les nouvelles créations utilisent DaVinci YRGB, `separateColorSpaceAndGamma=0`, `colorSpaceTimeline=DaVinci WG/Intermediate` et `colorSpaceOutput=Rec.709-A`. Les projets existants conservent leurs paramètres. Camera Raw reste Project / P3 D60 / Linear.

- Conversion Rec709-A : un nœud CST actif, P3-D60 / Linear → DaVinci Wide Gamut / Rec.709-A, conformément à la capture fournie.
- Kodak 2383 : deux nœuds actifs. CST P3-D60 / Linear → Rec.709 / Cineon Film Log, puis LUT `Film Looks/Rec709 Kodak 2383 D60.cube`.
- Tone Mapping et Gamut Mapping : None. Forward OOTF désactivé.

## Modèles

Deux DRT vides dédiés conservent les paramètres Camera Raw et la structure du modèle portable existant. Les paramètres OFX du CST Kodak ont été extraits d'une copie exportée de la timeline utilisateur ; ses réglages de cadrage n'ont pas été repris. Le modèle à un nœud réutilise un graphe sérialisé à un nœud, en remplaçant le grade par le CST demandé.

La LUT est liée lors de la préparation par `Graph.SetLUT(2, relativePath)`, puis vérifiée avec `GetLUT`. Cela utilise la LUT fournie par l'installation locale de Resolve et évite de redistribuer la LUT ou de conserver une liaison sérialisée dépendante du projet source. Une LUT absente interrompt la préparation avec son chemin explicite.

## Validation

- Test de régression initial : cinq assertions en échec sur l'ancien réglage à deux CST et la sortie DWG / Intermediate, puis passage après modification.
- Tests : préférence mémorisée, génération et installation des scripts Workspace, activation des deux nœuds Kodak, liaison de la LUT et erreur si elle manque ; adaptation des vérifications du format et des états de nœuds.
- Suite Swift : 269 tests, 9 ignorés, aucun échec.
- Resolve Studio : import des deux DRT dans un projet temporaire ; vérification d'un ou deux nœuds, CST présent, LUT Kodak effectivement appliquée par l'API, réglages de projet conformes et héritage par la timeline.
- Réexport Resolve : espaces et gammas des CST conservés, Forward OOTF désactivé. L'export du projet conserve les trois paramètres CinemaDNG Project / P3 D60 / Linear.
- Le projet utilisateur MLV test a été sauvegardé avant la vérification puis rouvert ; seul le projet temporaire a été supprimé.
