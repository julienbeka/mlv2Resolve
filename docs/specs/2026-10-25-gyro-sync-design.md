# mlv2dng — synchro gyro SenseFlow A1 intégrée (remplace NiYien Tool)

*Document de conception — 25 octobre 2026*

## Intention

Aujourd'hui, stabiliser des rushs Magic Lantern filmés avec le logger NiYien SenseFlow A1 demande NiYien Tool :
deux clips de référence (log + MLV lancés en même temps) pour caler les horloges, puis NiYien découpe le log
continu en un `.gyroflow` par vidéo, avec un profil d'objectif qu'il génère. Sur les DNG de mlv2dng, la
synchro automatique de Gyroflow (NiYien) échoue (son décodeur d'analyse ne lit aucune image : « ffmpeg Error
22 »), et l'appariement horaire de NiYien échoue sur des exports ProRes (date d'export ≠ date de tournage).

Validé le 25/10/2026 avec l'utilisateur sur le clip M24-1845 : en calculant le décalage par l'analyse du
mouvement de l'image (R² 0,78, pic suivant 0,23) et en l'écrivant dans le `.gyroflow`, le plugin Gyroflow de
Resolve passe à « Synced » et la stabilisation est correcte.

**But :** mlv2dng crée lui-même, sans NiYien Tool ni clips de référence, un `.gyroflow` synchronisé par MLV,
avec le bon profil d'objectif, visible dans le dossier de DNG monté. Dans Resolve, l'utilisateur n'a plus qu'à
cliquer « Load for current file ».

## Objectifs

1. Détection automatique des logs A1 (`*_mix.bin`, format décodé dans `poc/NOTES.md`) dans le dossier du
   tournage ou un sous-dossier, au montage et quand un log apparaît.
2. Pour chaque MLV sans `.gyroflow` : présélection du log et de la zone par les horloges, décalage exact par
   l'analyse du mouvement (méthode de `poc/mlv_motion.py` + `poc/sync_gyro.py`), écriture d'un `.gyroflow`.
3. Gestion des objectifs : liste déclarée par l'utilisateur, objectif par défaut par tournage, modifiable plan
   par plan ; profil calculé ou profil calibré importé.
4. Position du SenseFlow : par tournage (défaut « Top »), modifiable plan par plan.
5. État visible par plan : synchronisé (avec indice de confiance), aucun log ne couvre le plan, mouvement
   insuffisant / correspondance faible, en cours.

## Hors périmètre

- Rendu stabilisé par mlv2dng (Gyroflow / le plugin Resolve s'en chargent).
- Calibration d'objectif dans mlv2dng (elle se fait dans Gyroflow ; mlv2dng importe le `.json`).
- Autres loggers / caméras que SenseFlow A1 et EOS M (le code ne doit pas l'interdire, mais ce n'est pas testé).
- Application automatique du profil dans Resolve (le plugin lit le `.gyroflow`).

## Anti-objectifs

- Écraser un `.gyroflow` existant (p. ex. fait avec NiYien) sans demande explicite (« Régénérer »).
- Écrire un `.gyroflow` sur une correspondance douteuse (mieux vaut rien et un message clair).
- Modifier les MLV ou les logs ; créer des fichiers découpés (`Temp/` à la NiYien).
- Bloquer l'interface ou la lecture dans Resolve pendant les calculs.

## Décisions prises avec l'utilisateur

- Les `.gyroflow` sont écrits **à côté du MLV** (dossier d'origine), donc visibles dans le dossier de DNG
  monté (mécanisme des fichiers ajoutés déjà en place). Nom : celui que produit NiYien,
  `<dossier du clip>_000000.gyroflow` (ex. `M24-1845MLV_1_2026-10-24_0001_C0000_000000.gyroflow`), que le
  plugin Resolve retrouve.
- Plus besoin des deux clips de référence ; s'ils existent, ce sont des plans comme les autres.
- Objectifs de l'utilisateur (exemple, pas en dur) : 7artisans 25 mm f/1.8, 7artisans 12 mm f/2.8,
  Helios 44 58 mm. La focale écrite par Magic Lantern dans le MLV n'est pas fiable (50 mm sur des plans tournés
  au 25 mm) : elle ne sert jamais de source.
- Profil choisi plan par plan (objectif par défaut du tournage, modifiable par plan). Changer l'objectif d'un
  plan régénère son `.gyroflow`.
- Position du SenseFlow par défaut « Top », modifiable (par tournage, et par plan).

## Comment c'est construit

### Synchro (validée)

- Horloges : début du log = date de l'en-tête A1 ; début du clip = RTCI + (timestamp du 1er VIDF − timestamp
  RTCI). L'horloge de la caméra peut être très fausse (vu : 55 jours ; 8 s après réglage manuel). La
  présélection doit donc tolérer un grand écart : chercher dans tous les logs du tournage et, si l'écart
  horloge entre caméra et A1 a pu être estimé sur un plan bien synchronisé du même tournage, le réutiliser
  pour réduire la zone de recherche des autres plans.
- Décalage : intégration du gyro sur chaque intervalle d'image, régression linéaire gyro → déplacement image
  (corrélation de phase sur images LJ92 décodées et réduites), choix du décalage maximisant R². Accepter si
  R² ≥ seuil absolu ET marge sur le meilleur pic hors voisinage (valeurs à fixer par le constructeur à partir
  des mesures : M29-0615 R² 0,56 / 0,315 ; M23-1246 0,666 / 0,315 ; M24-1845 0,783 / 0,234 ; un plan sans
  log a donné 0,094 / 0,080).
- Un MLV peut être couvert par un log qui commence ou finit pendant le clip : accepter tant que la
  corrélation porte sur une durée suffisante (à fixer), sinon « aucun log ne couvre le plan ».

### Format `.gyroflow` (validé sur un cas réel)

- `gyro_source.filepath` : URL `file://` du log complet (pas d'extrait).
- `offsets` : objet dont les clés sont des timestamps gyro en µs, chaîne entière = (temps vidéo ms − offset)
  × 1000, et les valeurs l'offset en ms (négatif si le log commence avant le clip). Écrire 3 points
  répartis sur le clip.
- `synchronization.do_autosync = false` (sinon Gyroflow relance son autosync à l'ouverture et affiche
  l'erreur ffmpeg).
- `videofile` : motif de séquence `…_%06d.dng` du dossier monté (encodé comme NiYien : `%2506d`),
  `image_sequence_start` 0, `image_sequence_fps` = fps du MLV ; `video_info` (largeur/hauteur = taille DNG
  exposée par le moteur, p. ex. 1600×2008 ; nombre d'images ; fps ; durée).
- Le reste (stabilisation, sortie…) : valeurs par défaut de Gyroflow. Référence de structure : un projet
  produit par NiYien Tool (Gyroflow NiYien 1.6.3) — en obtenir un exemplaire anonymisé pour les tests ;
  ne pas committer de projet contenant des chemins personnels.
- Position du capteur : champ de `gyro_source` correspondant à « Mounting position » (Top…) tel qu'écrit par
  NiYien ; correspondance exacte à relever sur un projet NiYien.

### Profils d'objectif

- Format Gyroflow (exemple fourni : `CANON_M_APSC_Horizontal_Squeeze_3.00_…_25.00mm.json`, distorsion nulle,
  `input_horizontal_stretch` 3).
- Profil calculé : distorsion nulle, `input_horizontal_stretch` = facteur d'anamorphose lu dans le RAWC
  (binning/skipping, comme le moteur), dimensions de calibration = image désanamorphosée, focale en pixels =
  focale mm / pas des photosites dans ces coordonnées (EOS M : 22,3 mm / 5184 px ≈ 4,30 µm), centre optique
  au centre. Le recadrage du mode est déduit du RAWC/RAWI. Vérifier sur les clips de test que le profil
  calculé pour le 25 mm donne le même résultat que celui de NiYien.
- Profil calibré : import d'un `.json` Gyroflow, associé à un objectif ET à un mode (dimensions) ; si les
  dimensions ne correspondent pas au plan, ne pas l'utiliser et le signaler.
- L'app conseille un profil calibré pour les focales courtes (12 mm).

### Interface (choix du concepteur, à affiner)

- Réglages → « Objectifs » : liste (nom, focale, profil calibré optionnel) ; « Gyro » : position par défaut.
- Fenêtre mlv2dng : par tournage, objectif par défaut et position ; liste des plans avec état gyro, objectif
  (menu), et « Régénérer ».
- Calculs en arrière-plan, un plan à la fois, avec progression ; reprise au relancement.

## Précisions après relecture (choix du concepteur, marqués comme tels)

- **Log complet dans le `.gyroflow` — à vérifier en premier.** Le test validé pointait vers l'extrait NiYien
  (`Temp/…/…_1.bin`), qui est au même format A1 que le log complet ; Gyroflow (NiYien) lit ce format nativement.
  Première étape du plan : vérifier que le plugin Resolve accepte le `*_mix.bin` complet avec l'offset recalé
  (attendu pour M24-1845 : −4192 ms). *Choix du concepteur* si ça échoue : convertir chaque log complet, une
  fois, en un `.gcsv` complet du même nom, à côté du log (un fichier par log, pas par plan) — exception assumée
  à l'anti-objectif « pas de fichiers découpés ». Le chemin du log peut rester dans le dossier d'origine (le
  plugin a déjà accepté un chemin hors montage).
- **Références disponibles.** Le projet NiYien de M24-1845 (et sa copie d'origine), le profil NiYien 25 mm
  (`~/Desktop/Tests mlv2dng/CANON_M_APSC_Horizontal_Squeeze_3.00_1920x1080_25fps_25.00mm.json`) et le jeu
  « Test Gyroflow » (`~/Desktop/Tests mlv2dng/Test Gyroflow` : M24-1843/1844/1845 et trois logs) peuvent servir
  de référence et de jeu de test, en lecture seule (copies/clones APFS pour les tests ; ne jamais committer de
  MLV, de log ni de fichier contenant des chemins personnels). Plugin utilisé : Gyroflow (NiYien) 1.6.3
  (« DaVinci 2.1.2.60 ») — c'est la version cible du format.
- **Portée des logs (choix du concepteur).** Un plan peut utiliser tout log trouvé dans le dossier choisi par
  l'utilisateur (qui peut contenir plusieurs tournages) et ses sous-dossiers, pas seulement dans le dossier du
  tournage. La synchro ne tourne que pour les tournages montés. L'écart d'horloge estimé est partagé entre
  les tournages du même dossier choisi.
- **Changement d'objectif sur un `.gyroflow` fait par NiYien (choix du concepteur).** Changer l'objectif d'un
  plan vaut demande explicite de régénération, avec copie de l'ancien fichier dans
  `~/Library/Application Support/mlv2dng/gyroflow-backups/<tournage>/` (jamais dans les rushs). mlv2dng note
  quels `.gyroflow` il a écrits pour distinguer les deux cas dans l'interface.

## Laissé au constructeur

- Langage du calcul (Swift avec Accelerate/vDSP, ou C dans le moteur) — performances : ≈ 3 s par clip de
  320 images en Python dans la preuve de concept.
- Seuils exacts, stratégie de recherche multi-logs, persistance des réglages par plan (index du tournage ou
  réglages de l'app), messages exacts (EN/FR).

## Critères de réussite

- Sur « Test Gyroflow » (M24-1843, M24-1844, M24-1845 et les trois logs) : `.gyroflow` créés sans NiYien, plugin
  « Synced », stabilisation correcte dans Resolve ; M24-1845 retrouve le décalage validé (−1693 ms par rapport à
  l'extrait NiYien, soit 4,192 s dans le log complet) à ±10 ms près.
- Un plan sans log couvrant est signalé, aucun fichier créé.
- Un `.gyroflow` existant n'est pas écrasé ; « Régénérer » le remplace (avec copie de l'ancien).
- Changer l'objectif d'un plan régénère son `.gyroflow` avec le nouveau profil.
