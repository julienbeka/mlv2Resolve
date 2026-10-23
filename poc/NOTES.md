# Preuve de concept MLVFS + NiYien A1 → Gyroflow → Resolve

## Matériel de test
- Caméra : Canon EOS M (1), Magic Lantern, 12 bits, 4.8K 1x3 (anamorphique).
  MLV enregistré en 1600×2040, à désanamorphoser ×3 horizontalement → 4800×2040.
- Resolve Studio 21.0.4 (scripting externe disponible).
- NiYien SenseFlow A1, firmware V1.2.8 / hardware V1.2.3.

## Format du log A1 (`*_mix.bin`), décodé
- En-tête 0x200 octets : `SenseFlow`, modèle, n° de série, orientation `XYZ` à 0x3c,
  date/heure de début à 0x40 (aa mm jj hh mi ss, 1 octet chacun, précision 1 s),
  quaternion de montage (4 float32) à 0x4c, paramètres (1000, 8…) ensuite.
- Enregistrements de 16 octets : `aa 55 03` + ax ay az gx gy gz (int16 LE) + 1 octet de contrôle
  (algorithme inconnu, ignoré).
- Un marqueur `55 aa 40` tous les 1000 échantillons (1 par seconde).
- 1000 Hz ; accéléromètre 4096 LSB/g (±8 g) ; gyroscope 32,8 LSB/(°/s) (±1000 °/s).
  Échelle et signe du gyro vérifiés par intégration contre la gravité (erreur médiane 1,9° sur 2 s).

## Horodatage MLV
Début du clip = date du bloc RTCI + (timestamp du 1er VIDF − timestamp du RTCI).
Précision d'horloge 1 s des deux côtés → marge de 2 s, l'autosync Gyroflow affine.

Les horloges ne sont pas fiables : l'EOS M de test retarde de 55 j 4 h 51 min (photo de l'écran),
et même recalé, le clip tombait ~4–5 min après la fin du log A1. → synchro par le signal.

## Outils
- `a1_to_gcsv.py LOG.bin [CLIP.MLV ...]` : `.gcsv` par clip d'après les horloges (t=0 = 1re image).
- `mlv_motion.py CLIP.MLV [squeeze]` : mouvement image par image (corrélation de phase sur les images
  LJ92 décodées, ~3 s pour 320 images). Nécessite numpy + imagecodecs.
- `sync_gyro.py LOG.bin CLIP.motion.csv` : cherche le décalage où le gyro intégré explique le mieux le
  mouvement image, puis écrit `CLIP.gcsv` recalé.

## Résultat sur M29-0615.MLV
Clip trouvé à 100,118 s dans le log (11:02:15 heure A1), R² = 0,56 contre 0,315 pour le meilleur pic
ailleurs. Axes : gx → dx (~2000 px/rad), gy → −dy (~1500 px/rad). La théorie pour un 50 mm donnerait
~2900 px/rad : focale réelle, échelle gyro ou recadrage du mode 1x3 à vérifier.

## Gyroflow 1.6.3 (CLI)
- Détecte le .gcsv comme « gcsv niyien a1 » et lit le gyro à l'identique (0,272°/image dans les deux cas).
- Ignore les timestamps négatifs : le .gcsv est recalé sur son 1er échantillon. Avec 2 s de marge avant,
  l'autosync trouve −2003 ms ; sans marge −4,7 ms → notre synchro et la sienne concordent à ~5 ms.
- `-s` est ignoré ; l'autosync s'active via `--preset` avec une section `synchronization` complète
  (sinon division par zéro).
- Le lissage par défaut est trop faible. `Plain 3D`, `time_constant` 2 s, `integration_method` 3,
  orientation `XYZ` : tremblement 8,07 → 3,43 px sur M29-0615 (optimum théorique 3,44 px).
- `proxy` : `mlv_proxy.py` (1200×510 désanamorphosé, ~20 s pour 320 images).

## Second test : M23-1246.MLV + log 12-46-53
Synchro signal : 1re image à 7,984 s du log (12:47:00,98 heure A1), R² 0,666 contre 0,315.
Les horloges réglées à la main donnaient 12:46:47 → ~14 s d'écart. M23-1249 n'est pas dans ce log.
Clip à grands panoramiques et flous : la mesure de tremblement n'y est pas fiable → contrôle visuel
(`out/*_avant_apres.mp4`).

## Reste à valider
- Repère d'axes A1 → caméra dans Gyroflow (selon le montage ; le quaternion d'en-tête n'est pas exploité).
- Profil d'objectif Gyroflow pour l'EOS M en 4.8K 1x3 (calibration à faire).
- Chargement du .gcsv dans Gyroflow et application au clip MLVFS dans Resolve.
