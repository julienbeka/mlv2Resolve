# « Ouvrir Resolve » — validation

## Fonctionnement livré

- Un projet nommé comme chaque tournage monté ; les projets existants conservent leurs réglages, leurs clips et leurs timelines.
- À la création : préréglage utilisateur « mlv2dng », puis P3-D60 / Linear, cadence majoritaire, résolution désanamorphosée majoritaire. Égalité du nombre de plans : plus grande résolution.
- Exemple : 5 rushs 4800×2008 et 2 rushs 5208×2178 donnent 4800×2008.
- Import explicite des DNG et WAV ; synchro audio par paire ; aucun GIF, log ou gyroflow dans le chutier.
- Désanamorphose dès le chutier. Les formats anamorphiques d’un autre rapport utilisent des préréglages « Fit » adaptés à la taille réelle du projet. Leur installation conserve les mêmes protections que les préréglages existants : bibliothèque locale reconnue, sauvegarde, aucun remplacement de préréglage utilisateur, aucune écriture pendant que Resolve tourne. Une bibliothèque partagée, un préréglage absent ou une dimension personnalisée non préparée donne les valeurs à enregistrer manuellement.
- Version gratuite : script Workspace → Scripts → mlv2dng ; à la création du projet, timeline UHD « Rushs » avec zoom ajusté par plan. Lors des ouvertures suivantes, seuls les plans absents sont ajoutés au chutier, conformément à la règle de préservation des timelines existantes.
- Le choix « Attendre » ouvre Resolve une fois la synchro gyro terminée. Le choix « Ouvrir quand même » poursuit immédiatement.
- Confirmation « Enregistrer et ouvrir » avant chaque bascule depuis un projet utilisateur ; un refus d’enregistrer empêche la bascule. Le projet de démarrage « Sans titre », vide et non enregistré, est ignoré sans enregistrement.
- Connexion attendue au maximum environ 60 secondes ; les imports ont un délai distinct de 120 secondes. L’interface reste disponible.

## Vérifications automatisées

`cd app && swift test`

Les tests du worker Lua utilisent le véritable interpréteur fuscript, avec une API Resolve contrôlée : aucun projet utilisateur n’est ouvert ni modifié. Ils couvrent création, second passage sans doublon, consentement, audio par paire, erreur partielle, UHD, préréglages utilisateur et cadrage contre la taille existante lorsque la majorité change. Les tests Swift couvrent les fichiers, les en-têtes, les corrections d’anamorphose, la majorité, les délais et l’avancement gyro.

Compilation distribuable : `scripts/build-app.sh` ; résultat : `build/mlv2dng.app`.

## Vérification manuelle restant à faire dans Resolve

1. Studio, montage 20261025 : vérifier 4800×2008, 25 i/s, P3-D60 / Linear et les 8 plans avec audio. Vérifier visuellement le cadre des 4.8K et 5.2K et les réglages Camera Raw hérités du préréglage.
2. Ajouter un plan, rouvrir : seul ce plan doit être importé ; ne pas modifier le projet ou les timelines déjà présents.
3. Partir d’un autre projet, refuser puis accepter la bascule ; vérifier que les modifications sont enregistrées uniquement après consentement.
4. Version gratuite : exécuter Workspace → Scripts → mlv2dng, vérifier la timeline UHD Rushs et ses bandes noires.
5. Synchronisation gyro active : observer le compteur et l’icône, puis tester Attendre et Ouvrir quand même.
6. Préréglage « mlv2dng » absent : vérifier le guide ; les réglages Camera Raw restent à configurer et à enregistrer par l’utilisateur.

Les rendus réels Studio et gratuit n’ont pas été vérifiés automatiquement : la compilation et les doubles d’API ne remplacent pas cette inspection visuelle.
