# mlv2Resolve — version 0.2

## Intention

Renommer mlv2dng en mlv2Resolve et rendre le parcours montage virtuel → synchro gyro → Resolve lisible dans une fenêtre macOS. Les demandes fonctionnelles viennent du message utilisateur du 26 octobre 2026. Les choix précisés ci-dessous sont des propositions de réalisation à valider.

## Fenêtre principale

Quatre sections verticales distinctes dans une fenêtre redimensionnable avec défilement :

1. **Monter / Mount** : choix du dossier, nom et nombre de plans par tournage, interrupteur natif de montage/démontage par dossier, progression et désactivation pendant l'opération. « Tout démonter » et accès aux DNG dans Finder dans cette section.
2. **Synchro gyro / Gyro sync** : progression générale et état de chaque tournage/plan. Si aucun objectif n'est déclaré, invitation visible même avant montage, avec accès direct au tiroir des réglages, section Objectifs. Conserver objectifs par défaut, attribution par plan, positions du capteur et régénération avec protection des fichiers existants. Chaque plan dispose d'une vignette et d'un aperçu agrandi à la demande afin d'identifier son objectif. Chargement asynchrone depuis une image du plan monté, cache borné, état indisponible explicite et invalidation au démontage ; aucun décodage lourd dans le fil de l'interface. Proposition : aperçu fixe pour cette version.
3. **Resolve** : logo de DaVinci Resolve et quatre actions distinctes, conformément aux quatre actions énumérées dans la demande malgré la mention « 3 boutons ». « Créer projet » prépare un projet par tournage monté avec ses médias, son audio et son format. « Ouvrir projet » retrouve les associations mémorisées et propose un choix si plusieurs projets sont liés ; aucune création implicite. « Ouvrir Resolve » lance simplement l'application. « Desqueeze dans Resolve » conserve l'action dédiée. Afficher les états occupé, absent et aucun projet lié. Conserver les protections de sauvegarde et de changement du projet actif. La création réussie mémorise l'association stable entre le dossier source et le projet dans la bibliothèque Resolve ; les erreurs ne créent pas d'association.
4. **Réglages et conseils / Settings & Tips** : bouton du tiroir et conseils concis sur le montage virtuel, la synchro et Resolve. L'installation de FUSE-T reste accessible si nécessaire.

## Tiroir gauche

Les réglages se déploient à gauche **dans la même fenêtre** et se referment par un bouton visible. Les accès du menu et le raccourci des réglages ciblent aussi ce tiroir. Largeur proposée : environ 380–420 points, avec défilement indépendant ; la fenêtre conserve une zone principale utilisable.

Conserver langue, lancement à la connexion, objectifs/profils, position du gyro, corrections de pixels, journaux et informations de version.

Déplacer **Dual ISO** dans les réglages avec explication des deux modes :

- **Montage fluide** : aperçu Dual ISO rapide pour favoriser la lecture et le montage.
- **Qualité étalonnage** : interpolation Dual ISO complète, plus exigeante, à privilégier pour l'étalonnage et le rendu final.

Le changement conserve le comportement actuel du moteur pour les dossiers déjà montés.

Section **Resolve** :

- Taille de timeline persistante : **Automatique** (comportement majoritaire actuel), **UHD 3840 × 2160**, **HD 1920 × 1080**.
- Conserver la cadence déduite des rushs. UHD/HD adaptent le zoom de chaque plan pour montrer toute l'image, désanamorphose incluse, sans recadrage ; des bandes sont possibles. Respecter les limitations existantes de Resolve Free et signaler tout repli.
- Appliquer le format à la création ; ouvrir un projet lié ne modifie pas ses timelines ou ses choix de cadrage.
- **Effacer les associations de projets** : retirer uniquement les liens mémorisés permettant « Ouvrir projet ». Ne pas supprimer de projet dans Resolve, de rush, de montage virtuel ou de fichier utilisateur. Expliquer cette portée à côté du bouton.

## Apparence Tahoe

Conserver SwiftUI/AppKit. Employer les composants système, une hiérarchie typographique claire, des surfaces regroupées arrondies, des espacements plus généreux, une barre d'outils et un tiroir translucides. Réserver Liquid Glass à la navigation et aux contrôles ; garder les listes de plans lisibles. Utiliser les API macOS 26 derrière des contrôles de disponibilité, avec un rendu natif compatible macOS 14 et 15. Respecter apparence sombre, réduction de transparence/mouvements et libellés d'accessibilité. Référence : https://developer.apple.com/videos/play/wwdc2025/323/ et https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass.

## Renommage et version

Nom public **mlv2Resolve**, prochaine release **v0.2** (version applicative 0.2). Mettre à jour interface FR/EN, sources et noms de cibles/modules, scripts, ressources Resolve, documentation et workflows GitHub. Préserver les données des installations précédentes par migration des anciens chemins/clés, y compris objectifs, profils calibrés, sauvegardes et préférences ; les références à mlv2dng ne restent que pour compatibilité ou explication historique nécessaire. Ne pas modifier les sources tierces sans rapport.

Déjà réalisé le 26 octobre : dépôt GitHub renommé en `julienbeka/mlv2Resolve`, release `v0.1.18` et tag distant supprimés, URL `origin` locale actualisée. Ne pas publier v0.2 tant que l'implémentation et les vérifications ne sont pas terminées.

## Vérification attendue

Choix de réalisation après revue : prendre une image centrale pour l'aperçu fixe ; effacer toutes les associations via le bouton de cache ; conserver l'identifiant applicatif existant pour préserver préférences et autorisations, tout en migrant les chemins de données vers le nouveau nom. Si « Créer projet » trouve une association existante, proposer d'ouvrir le projet lié ou de créer un projet au nom distinct, sans écrasement. Si un projet lié est introuvable dans la bibliothèque active, afficher cet état et permettre de retirer son association, sans création implicite.

Tests ciblés sur format automatique/UHD/HD et cadrage anamorphique, mémorisation/ouverture/effacement des associations, migration des données et traductions. Compiler l'application et exécuter les tests existants pertinents. Vérifier visuellement sections, tiroir, états vides, liste longue, clair/sombre et aperçu. Les opérations nécessitant des rushs réels ou une session Resolve doivent être validées dans l'environnement disponible ; signaler précisément ce qui ne peut pas être exercé.

## Ajout utilisateur — gestion couleur

À la création : espace de travail DaVinci Wide Gamut, gamma DaVinci Intermediate. Graphe de **timeline** : CST 01 actif P3/Linear → DWG/Intermediate ; CST 02 désactivé DWG/Intermediate → Rec.709/Rec.709-A, à activer seulement avant un export Rec.709. Le modèle doit être livré avec l'app et appliqué sur chaque nouvelle timeline, sans configuration manuelle obligatoire chez les autres utilisateurs. Conserver DaVinci YRGB pour éviter une double transformation implicite avec les CST ; régler l'espace/gamma de travail du projet. Tout échec d'application du graphe doit être signalé, et les projets existants ne sont pas modifiés.

## Ajout utilisateur — timeline All shots

Les réglages Resolve comprennent une option pour ajouter tous les rushs importés à une nouvelle timeline, nommée **All shots** par défaut et renommable via un champ. Choix de réalisation annoncé : option activée par défaut ; désactivée, elle laisse une timeline vide avec les CST préparés. Champ vide → All shots. Conserver les préférences entre lancements. Ne jamais remplir une timeline d'un projet existant lors d'une simple ouverture.

## Ajout utilisateur — cadence réglable

Cadence de timeline automatique = cadence majoritaire des rushs montés (par projet/tournage), avec choix manuel persistant dans les réglages Resolve parmi les cadences standard prises en charge (16 à 120 i/s, dont 23,976 et 29,97). Le réglage manuel s'applique uniquement aux nouvelles timelines. Le modèle CST portable est finalement une timeline DRT vide, car le test réel d'application DRX via Graph.ApplyGradeFromDRX a provoqué un plantage de Resolve. L'import DRT, les deux outils CST, les états des nœuds, le changement de cadence et le redimensionnement ont été vérifiés dans Resolve 21.1.1.
