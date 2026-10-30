# Grades de groupe — 29 octobre 2026

Cette correction remplace la structure décrite dans le rapport du 28 octobre. Elle s'applique aux créations de projets ; un import dans un projet existant conserve ses grades et ses timelines.

Tous les plans vidéo de la timeline créée appartiennent au groupe **All**. Le graphe **Timeline** contient zéro nœud. Le nœud Gyroflow reste au niveau Clip.

| Niveau | Conversion Rec709-A | Kodak 2383 |
|---|---|---|
| Group Pre Clip | P3-D60 / Linear → DaVinci Wide Gamut / DaVinci Intermediate | Identique |
| Group Post Clip | DWG / Intermediate → Rec.709 / Rec.709-A | DWG / Intermediate → Rec.709 / Cineon Film Log ; LUT Film Looks / Rec709 Kodak 2383 D60 |

Les CST d'entrée et de préparation Kodak utilisent Tone Mapping None, Gamut Mapping None et aucun OOTF. Le CST de sortie utilise Tone Mapping DaVinci, Adaptation 9 et Gamut Mapping None. La LUT native est liée par `SetLUT(2, ...)` et vérifiée par `GetLUT` ; aucune donnée de LUT n'est redistribuée.

## Modèles et création

Les ressources `resolve-color-rec709-a.drt` et `resolve-color-kodak2383.drt` initialisent le groupe à partir d'un seul plan fictif hors ligne. Le modèle conserve les connecteurs et la géométrie sérialisés par Resolve ; seuls les processeurs des nœuds sont adaptés. Le grade primaire est neutre. Le chemin du plan fictif est sous `/tmp`, sans référence aux rushs utilisateur.

Le modèle `resolve-timeline-empty.drt` fournit ensuite une timeline avec zéro nœud Timeline. Chaque plan ajouté reçoit le groupe All ; la création vérifie l'appartenance sur toutes les pistes vidéo avant de supprimer les objets temporaires capturés. Cette méthode contourne le refus de `ApplyGradeFromDRX` sur les graphes de groupe observé dans Resolve 21.1.1. Le groupe et ses grades sont conservés après suppression du dernier plan fictif, même si la timeline finale est vide.

Les réglages du projet restent DaVinci YRGB, DaVinci WG/Intermediate, sortie Rec.709-A et Camera Raw Project / P3 D60 / Linear. La cadence est établie avant l'import des modèles puis contrôlée après import.

## Validation et livraison

- Tests indépendants des archives : nombres de nœuds, espaces et gammas des CST, modes Tone Mapping, connecteurs et liaisons vers des nœuds existants.
- Tests Lua : groupe pré/post, activation des nœuds, liaison de la LUT, erreurs explicites, absence de nœuds Timeline et préservation des projets existants.
- Suite complète : 281 tests, 11 tests optionnels ignorés, aucun échec.
- Essai réel supplémentaire dans Resolve Studio 21.1.1 : deux plans dans chacun des deux modes à 25 fps, puis timeline Conversion vide à 29,97 fps. Sauvegarde/réouverture, persistance des grades, appartenance All et graphe Timeline vide vérifiés.
- Projet utilisateur UPDLV sauvegardé/exporté avant validation, puis rouvert : All contient toujours 42 plans, pré 1, post 1, Timeline 0. Les treize projets temporaires ont été supprimés.
- Version de livraison : **0.2.5**, build local **108**, après validation initiale en 0.2.4 (107). Archive : `build/releases/mlv2Resolve-0.2.5-macos-arm64.zip`. Le build GitHub Actions reçoit un numéro supérieur à 1000.

L'application installée et la session de montage en cours ne sont pas remplacées automatiquement.

## Mise à jour du 30 octobre — Kodak à deux nœuds

Le Group Post Clip Kodak conserve uniquement le CST DWG/Intermediate → Rec.709/Cineon Film Log et la LUT Kodak 2383 D60. Le troisième nœud de conversion Rec.709 → Rec.709-A est supprimé ; la sortie du graphe est reliée directement à la LUT. Sur le CST Kodak, Forward OOTF et Inverse OOTF sont désactivés ; White Point Adaptation conserve sa valeur par défaut activée. Tone Mapping et Gamut Mapping restent à None. Cette modification du preset s’applique aux nouveaux projets ; les projets existants ne sont pas réécrits.
