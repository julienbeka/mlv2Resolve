## English

**mlv2dng** mounts Magic Lantern MLV footage as virtual CinemaDNG sequences for DaVinci Resolve, from the macOS menu bar. No conversion, no copy. It drives the (patched) MLVFS engine on FUSE-T.

**Requirements:** Apple Silicon Mac, macOS 14 or later. FUSE-T is installed by the app on first launch if missing.

**Install:** unzip, move `mlv2dng.app` to `/Applications`, open it. The app is not notarized (no Apple Developer account), so macOS blocks the first launch: open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**, then confirm.

Verify the download: `shasum -a 256 -c mlv2dng-@VERSION@-macos-arm64.zip.sha256`

Source (GPL-3.0-or-later): https://github.com/@REPO@/tree/@TAG@

## Français

**mlv2dng** monte vos rushs Magic Lantern (MLV) en séquences CinemaDNG virtuelles pour DaVinci Resolve, depuis la barre des menus macOS, sans conversion ni copie. Elle pilote le moteur MLVFS (modifié) sur FUSE-T.

**Prérequis :** Mac Apple Silicon, macOS 14 ou plus récent. FUSE-T est installé par l'app au premier lancement s'il manque.

**Installation :** décompressez, placez `mlv2dng.app` dans `/Applications`, ouvrez-la. L'app n'est pas notarisée (pas de compte Apple Developer) : macOS bloque le premier lancement. Allez dans **Réglages Système → Confidentialité et sécurité**, faites défiler et cliquez sur **Ouvrir quand même**, puis confirmez.

Vérifier le téléchargement : `shasum -a 256 -c mlv2dng-@VERSION@-macos-arm64.zip.sha256`

Code source (GPL-3.0-or-later) : https://github.com/@REPO@/tree/@TAG@
