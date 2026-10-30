# Analyse gyro par passages — 29 octobre 2026

La synchronisation analysait chaque paire d’images de chaque clip. Le SSD externe
observé lisait environ 389 Mo/s ; le décodage LJ92 et la comparaison de mouvement
restaient nécessaires sur toutes les images.

`mlvmotion --sampled` analyse trois passages (début, milieu, fin). Chaque passage
comprend au moins 64 paires adjacentes et deux secondes d’images. À 25 i/s, cela
donne 192 mesures au total. Les numéros d’images originaux sont conservés ; aucune
paire ne traverse les intervalles sautés. Les plans trop courts et les cadences
invalides utilisent directement l’analyse complète.

Le coordinateur conserve les seuils R² et de contraste existants. En l’absence de
correspondance acceptée, il reprend l’analyse complète avant toute écriture. Un
premier passage qui contient déjà toutes les paires n’est pas répété. Le cache
des journaux et l’apprentissage du décalage d’horloge restent utilisés.

## Mesures

Compilation Release arm64, SSD externe USB ExFAT, cache des rushs préchargé avant
de chronométrer les deux méthodes. Comparaison en lecture seule avec les extraits
SenseFlow déjà présents. Les durées ci-dessous concernent l’analyse des images ;
elles ne mesurent pas le montage, les miniatures ni l’écriture des projets.

| Clip | Paires complètes → choisies | Complet | Passages | Écart accepté | Repli complet |
| --- | --- | --- | --- | --- | --- |
| M28-2316 | 445 → 192 | 1,488 s | 0,733 s | 0 ms | Non |
| M28-2030 | 231 → 192 | 0,845 s | 0,804 s | 0 ms | Non |
| M28-1922 | 349 → 192 | 1,201 s | 0,737 s | 1 ms | Non |
| M28-2315 | 490 → 192 | 1,724 s | 0,753 s | — | Oui, passages ambigus |
| M28-2251 | 450 → 192 | 1,573 s | 0,751 s | 1 ms | Non |

L’analyse par passages atteint environ 2× sur deux de ces clips. Un repli ajoute
le coût du premier passage à celui de l’analyse complète : les plans incertains
peuvent donc être plus lents. L’échantillonnage peut changer le R² et la précision
du décalage ; les seuils identiques ne prouvent pas une précision identique sur
tous les rushs. Les correspondances acceptées de cet essai diffèrent de 0–1 ms.

## Validation

- Tests du moteur : vrais JPEG sans perte générés, mesures identiques au complet,
  numéros d’images, décodage limité aux passages, images corrompues, plans courts,
  cadence de 120 i/s et chemins d’erreur.
- Coordinateur : succès sans repli, résultat ambigu suivi d’un succès complet,
  refus complet sans écriture, annulation, absence de répétition d’un passage complet.
- Suite Swift : 287 tests, 12 tests optionnels ignorés, aucune erreur.
- Comparaison réelle ci-dessus : réussie, quatre résultats acceptés et un repli.
- Application macOS compilée et signature vérifiée.
