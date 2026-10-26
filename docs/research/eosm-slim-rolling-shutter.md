# Temps de lecture du capteur — Canon EOS M, Crop Mood Slim

Relevé du 25 octobre 2026. Périmètre : modes accessibles dans la version Slim fournie par Julien, et non tous les boîtiers/builds Magic Lantern.

Source : [crop_rec.c, révision `14078c6ef4ff`](https://github.com/Amit199167/Crop-mood-eosm-slim-gui/blob/14078c6ef4ff97f57e8b21f20705b24836256051/modules/crop_rec/crop_rec.c). Le fichier téléchargé de main est identique à cette révision figée.

## Méthode et limites

- Horloge EOS M : 32 MHz. Un compteur Timer A écrit à N correspond à N + 1 cycles.
- Temps de lecture estimé (ms) = hauteur active réellement enregistrée × (Timer A + 1) / 32000.
- La hauteur doit être celle du MLV/DNG avant recadrage ou redimensionnement. Le désqueeze horizontal ×3 ne multiplie pas ce temps.
- Les valeurs sont calculées à partir des réglages standard, sans offsets/debug ni recadrage supplémentaire. Ce ne sont pas des mesures optiques.
- Le 1×3 Higher 2,39:1 à 1600×2008, 25 i/s, a été testé à 32,128 ms : Julien constate une nette réduction des ondulations. Les autres restent à valider.
- Le sens de balayage n’est pas mesuré ici ; conserver celui du test concluant, puis le vérifier si nécessaire.
- Les cadences « 24 » / « 30 » désignent les choix du menu ; les cadences exactes peuvent différer légèrement. Le temps de lecture reste identique lorsque seul Timer B change.
- La correction dépend aussi de la synchronisation gyro et du profil optique.

## 1×1 — crop sans sous-échantillonnage

| Ratio | Preset | Image enregistrée | Cadence / menu | µs / ligne | Lecture estimée (ms) |
|---|---|---|---|---:|---:|
| 2.33:1 | Highest | 2520 × 1080 | 24 / 25 / 30 | 22.375 | 24.165 |
| 2.35:1 | Higher | 2880 × 1226 | 24 / 25 | 25.188 | 30.880 |
| 2.35:1 | Highest | 3072 × 1308 | ~24 | 26.875 | 35.153 |
| 16:9 | Highest | 2560 × 1440 | 24 / 25 | 22.875 | 32.940 |
| 3:2 | Highest | 1920 × 1280 | 24 / 25 | 17.688 | 22.640 |
| 4:3 | Highest | 2160 × 1620 | ~23.943 | 19.812 | 32.096 |

## 1×3 — anamorphique

| Ratio | Preset | Image enregistrée | Cadence / menu | µs / ligne | Lecture estimée (ms) |
|---|---|---|---|---:|---:|
| 16:9 | Highest | 1504 × 2538 | ~22.250 | 16.000 | 40.608 |
| 16:9 | Higher | 1376 × 2322 | ~24 | 16.000 | 37.152 |
| 16:9 | Medium | 1280 × 2160 | 24 / 25 | 16.000 | 34.560 |
| 2:1 | Highest | 1600 × 2400 | ~23.300 | 16.000 | 38.400 |
| 2:1 | Higher | 1472 × 2208 | 24 / 25 | 16.000 | 35.328 |
| 2:1 | Medium | 1360 × 2040 | 24 / 25 | 16.000 | 32.640 |
| 2.20:1 | Highest | 1664 × 2268 | ~24 | 16.000 | 36.288 |
| 2.20:1 | Higher | 1552 × 2216 | 24 / 25 | 16.000 | 35.456 ⚠ |
| 2.20:1 | Medium | 1424 × 1942 | 24 / 25 | 16.000 | 31.072 |
| 2.35:1 | Highest | 1736 × 2214 | ~24 | 16.250 | 35.977 |
| 2.35:1 | Higher | 1600 × 2040 | 24 / 25 | 16.000 | 32.640 |
| 2.35:1 | Medium | 1472 × 1878 | 24 / 25 | 16.000 | 30.048 |
| 2.39:1 | Highest | 1736 × 2178 | ~24 | 16.250 | 35.392 |
| 2.39:1 | Higher | 1600 × 2008 | 24 / 25 | 16.000 | 32.128 ✓ |
| 2.39:1 | Medium | 1472 × 1846 | 24 / 25 | 16.000 | 29.536 |

## 3×3 — binning / cadence élevée

| Ratio | Preset | Image enregistrée | Cadence / menu | µs / ligne | Lecture estimée (ms) |
|---|---|---|---|---:|---:|
| 16:9 | High FPS | 1736 × 976 | High FPS | 16.500 | 16.104 |
| 2:1 | High FPS | 1736 × 868 | High FPS | 16.250 | 14.105 |
| 2.20:1 | High FPS | 1736 × 790 | High FPS | 16.250 | 12.838 |
| 2.35:1 | High FPS | 1736 × 738 | High FPS | 16.250 | 11.992 |
| 3:2 | Highest | 1736 × 1160 | 24 | 16.500 | 19.140 |
| 3:2 | Highest | 1736 × 1160 | 25 | 20.000 | 23.200 |
| 3:2 | Highest | 1736 × 1160 | 30 | 16.500 | 19.140 |

## LV — pleine résolution

| Ratio | Preset | Image enregistrée | Cadence / menu | µs / ligne | Lecture estimée (ms) |
|---|---|---|---|---:|---:|
| 3:2 | Highest | 5208 × 3478 | ~3 | 43.375 | 150.858 |

## Cas à vérifier avant utilisation automatique

- **1×3 2.20:1 Higher** : Incohérence firmware : UI 2216 lignes ; RAW_V=0x863, soit 2118 avec la marge observée de 29 lignes. Si le MLV contient 2118 lignes, utiliser 33.888 ms. La valeur du tableau suppose la hauteur annoncée par l’interface ; ne pas l’appliquer automatiquement avant lecture des métadonnées d’un rush.

Le 3×3 3:2 annonce 1160 lignes dans l’interface, alors que Preview_V vaut 1152 : ce dernier concerne la prévisualisation. Si le fichier livré mesure 1152 lignes, les temps deviennent 19,008 ms (24/30) ou 23,040 ms (25). Toujours privilégier la hauteur du fichier.

## Modes internes hors interface Slim courante

- 1×1 CROP_1080p, 1920×1080 : 19,103 ms (Timer A 0x235), présent dans le backend mais pas dans les choix 1×1 Slim.
- 1×3 Anam_FLV, 1736×3478 : 56,518 ms (Timer A 0x207, debug nul), option interne non exposée dans les presets Slim ordinaires.
- Le backend 3×3 contient aussi 1736×694 (2,50:1), soit 11,278 ms, et une variante 1736×726, soit 11,798 ms. Le dernier choix de l’interface Slim est redirigé vers le 3:2 ; ces variantes ne sont pas des choix supplémentaires du menu courant.

## Traçabilité

- Compteurs : reg_override_1X1, reg_override_1X3, reg_override_3X3.
- Modes et tailles annoncées : slim_1x1_resolve, slim_crop_expected_res.
- Accessibilité des variantes : slim_crop_apply_3x3_from_ar, slim_crop_fps_mask.
- Ne pas généraliser ces valeurs aux modes Canon natifs, à un autre firmware ou à un autre appareil.
- Le relevé initial ne modifiait aucun réglage. Les valeurs sont désormais intégrées dans mlv2Resolve (voir ci-dessous).

## Intégration dans mlv2Resolve — 0.1.17 (89)

Les nouveaux projets Gyroflow et les projets explicitement régénérés utilisent ces valeurs automatiquement. La sélection repose sur la taille RAWI, la cadence MLVI et la lecture RAWC (1×1, 3×1, 3×3). Une correction de désqueeze issue de SqueezeFix remplace aussi le rapport RAWC incorrect pour ce calcul.

Le profil optique et la section stabilization du projet reçoivent le même temps de lecture. Pour un mode reconnu, le temps du capteur remplace celui d’un profil optique générique importé. Pour un format inconnu, le temps fini du profil importé est conservé, y compris zéro ou un signe négatif ; sans valeur valide, la correction est désactivée (0 ms).

Le mode 1552×2216 / 1552×2118 est distingué par la hauteur réelle du fichier. Les projets existants ne sont pas modifiés automatiquement : utiliser « Régénérer », puis recharger le projet dans le plugin Resolve. Cette action régénère également la synchronisation selon le workflow existant et sauvegarde l’ancien projet.

Vérification : génération JSON des modes du tableau, passage des deux champs au plugin, formats inconnus, profils importés et correction d’en-tête ; contrôle en lecture seule sur les huit MLV du tournage 20261025.
