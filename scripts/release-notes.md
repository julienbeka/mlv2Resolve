## English

### Changes in @VERSION@

- Add **Desqueeze in Resolve** for mounted anamorphic CinemaDNG sequences, through the Resolve Studio scripting API. Existing custom sizing choices are preserved; WAV audio and GIF previews are skipped.
- Create the `mlv2dng 1x3` and `mlv2dng 1x5` presets as needed in the default local project library, only while Resolve is closed and after saving a backup. Other libraries and unsupported settings formats use manual instructions.
- Install a **Workspace → Scripts → mlv2dng Desqueeze** shortcut in Resolve, with English and French feedback.
- Keep one local `mlv2dng.app` and increment its version beyond the last local build and highest known release tag.

**mlv2dng** mounts Magic Lantern MLV footage as virtual CinemaDNG sequences for DaVinci Resolve, from the macOS menu bar. No conversion, no copy. It drives the (patched) MLVFS engine on FUSE-T.

**Requirements:** Apple Silicon Mac, macOS 14 or later. FUSE-T is installed by the app on first launch if missing.

**Install:** unzip, move `mlv2dng.app` to `/Applications`, open it. The app is not notarized (no Apple Developer account), so macOS blocks the first launch: open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**, then confirm.

Verify the download: `shasum -a 256 -c mlv2dng-@VERSION@-macos-arm64.zip.sha256`

Source (GPL-3.0-or-later): https://github.com/@REPO@/tree/@TAG@

## Français

### Nouveautés de @VERSION@

- Ajout de **Désqueezer dans Resolve** pour les séquences CinemaDNG anamorphiques montées, via l’API de scripting de Resolve Studio. Les presets personnalisés existants sont conservés ; les fichiers WAV et les aperçus GIF sont ignorés.
- Création au besoin des presets `mlv2dng 1x3` et `mlv2dng 1x5` dans la bibliothèque locale par défaut, uniquement lorsque Resolve est fermé et après sauvegarde. Les autres bibliothèques et les formats de réglages non pris en charge disposent d’instructions manuelles.
- Installation du raccourci **Workspace → Scripts → mlv2dng Desqueeze** dans Resolve, avec des messages en français et en anglais.
- Conservation d’une seule application locale `mlv2dng.app`, avec une version supérieure au dernier build local et au plus haut tag de release connu.

**mlv2dng** monte vos rushs Magic Lantern (MLV) en séquences CinemaDNG virtuelles pour DaVinci Resolve, depuis la barre des menus macOS, sans conversion ni copie. Elle pilote le moteur MLVFS (modifié) sur FUSE-T.

**Prérequis :** Mac Apple Silicon, macOS 14 ou plus récent. FUSE-T est installé par l'app au premier lancement s'il manque.

**Installation :** décompressez, placez `mlv2dng.app` dans `/Applications`, ouvrez-la. L'app n'est pas notarisée (pas de compte Apple Developer) : macOS bloque le premier lancement. Allez dans **Réglages Système → Confidentialité et sécurité**, faites défiler et cliquez sur **Ouvrir quand même**, puis confirmez.

Vérifier le téléchargement : `shasum -a 256 -c mlv2dng-@VERSION@-macos-arm64.zip.sha256`

Code source (GPL-3.0-or-later) : https://github.com/@REPO@/tree/@TAG@
