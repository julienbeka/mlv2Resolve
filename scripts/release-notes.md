## English

### Changes in @VERSION@

- **Resolve project preparation:** create or open a project per mounted shoot, import CinemaDNG and matching WAV audio, and synchronize audio by timecode. Existing projects keep their settings and timelines; later runs import only missing clips.
- **Majority-based project format:** choose the most common desqueezed resolution and frame rate, with the larger resolution winning ties. Resolve Free receives a fitted UHD Rushs timeline through Workspace → Scripts → mlv2dng.
- **Anamorphic sizing:** apply matching Input Sizing presets, including fit variants, while preserving custom sizing choices. Supported preset installation backs up the local library and runs only while Resolve is closed.
- **Built-in SenseFlow A1 gyro sync:** choose lenses and sensor mounting positions, generate per-clip Gyroflow projects, import calibrated lens profiles, and follow progress in the window and menu bar. Existing files are backed up before explicit regeneration.
- **Mode-specific rolling shutter:** select EOS M Crop Mood Slim readout times from the actual recording format, including 32.128 ms for 4.8K and 35.3925 ms for 5.2K in 2.39:1. The 4.8K setting has been visually tested; other source-derived modes remain to be validated visually.
- **Header correction:** follow the majority sampling of same-size clips when an MLV reports the wrong anamorphic format, including during Gyroflow generation.
- **Startup fix:** skip Resolve’s empty, unsaved Untitled Project without requiring a save, while preserving confirmation and save checks for projects containing work.

**mlv2dng** mounts Magic Lantern MLV footage as virtual CinemaDNG sequences for DaVinci Resolve, from the macOS menu bar. No conversion, no copy. It drives the (patched) MLVFS engine on FUSE-T.

**Requirements:** Apple Silicon Mac, macOS 14 or later. FUSE-T is installed by the app on first launch if missing.

**Install:** unzip, move `mlv2dng.app` to `/Applications`, open it. The app is not notarized (no Apple Developer account), so macOS blocks the first launch: open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**, then confirm.

Verify the download: `shasum -a 256 -c mlv2dng-@VERSION@-macos-arm64.zip.sha256`

Source (GPL-3.0-or-later): https://github.com/@REPO@/tree/@TAG@

## Français

### Nouveautés de @VERSION@

- **Préparation des projets Resolve :** création ou ouverture d’un projet par tournage monté, import des CinemaDNG et WAV associés, synchronisation audio par timecode. Les projets existants conservent leurs réglages et timelines ; seuls les plans manquants sont ajoutés ensuite.
- **Format majoritaire :** choix de la résolution désanamorphosée et de la cadence les plus fréquentes ; la plus grande résolution départage les égalités. Resolve gratuit reçoit une timeline UHD Rushs ajustée via Workspace → Scripts → mlv2dng.
- **Désanamorphose :** application des préréglages Input Sizing adaptés, y compris les variantes de cadrage, en conservant les choix personnalisés. L’installation compatible sauvegarde la bibliothèque locale et s’effectue uniquement lorsque Resolve est fermé.
- **Synchro SenseFlow A1 intégrée :** choix des objectifs et positions du capteur, génération d’un projet Gyroflow par plan, import de profils optiques calibrés, suivi dans la fenêtre et la barre des menus. Les fichiers existants sont sauvegardés avant régénération explicite.
- **Rolling shutter par mode :** choix des temps de lecture EOS M Crop Mood Slim selon le format réel, dont 32,128 ms pour le 4,8K et 35,3925 ms pour le 5,2K en 2,39:1. Le 4,8K a été testé visuellement ; les autres modes calculés depuis le code restent à valider sur l’image.
- **Correction d’en-tête :** utilisation de l’échantillonnage majoritaire des plans de même taille lorsqu’un MLV annonce un mauvais format anamorphique, y compris pour la génération Gyroflow.
- **Correction au démarrage :** le projet Sans titre vide et non enregistré de Resolve est ignoré sans demander d’enregistrement ; les projets contenant du travail restent protégés par la confirmation et l’enregistrement préalable.

**mlv2dng** monte vos rushs Magic Lantern (MLV) en séquences CinemaDNG virtuelles pour DaVinci Resolve, depuis la barre des menus macOS, sans conversion ni copie. Elle pilote le moteur MLVFS (modifié) sur FUSE-T.

**Prérequis :** Mac Apple Silicon, macOS 14 ou plus récent. FUSE-T est installé par l'app au premier lancement s'il manque.

**Installation :** décompressez, placez `mlv2dng.app` dans `/Applications`, ouvrez-la. L'app n'est pas notarisée (pas de compte Apple Developer) : macOS bloque le premier lancement. Allez dans **Réglages Système → Confidentialité et sécurité**, faites défiler et cliquez sur **Ouvrir quand même**, puis confirmez.

Vérifier le téléchargement : `shasum -a 256 -c mlv2dng-@VERSION@-macos-arm64.zip.sha256`

Code source (GPL-3.0-or-later) : https://github.com/@REPO@/tree/@TAG@
