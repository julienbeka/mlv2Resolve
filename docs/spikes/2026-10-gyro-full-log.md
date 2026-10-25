# Spike — log A1 complet dans le `.gyroflow` (25/10/2026)

**Question :** le plugin Gyroflow (NiYien) 1.6.3 de Resolve accepte-t-il le `*_mix.bin` complet (et pas
l'extrait découpé `Temp/…/…_1.bin` de NiYien Tool) ?

**Essai :** projet NiYien de M24-1845 modifié : `gyro_source.filepath` → log complet
`2026-10-24_18-44-36_mix.bin`, `offsets` recalés à −4192 ms (−1693 ms sur l'extrait, qui commence 2,499 s
plus tard), 3 points à 15/50/85 % du clip, `synchronization.do_autosync = false`.

**Résultat : OK.** Statut du plugin « OK », stabilisation correcte. Le log complet est utilisé partout, pas
de repli `.gcsv`.

**Reste :** « Open in Gyroflow » affiche encore « ffmpeg::Error(22: Invalid argument) ». Le journal de
Gyroflow montre qu'il relance quand même une synchro à l'ouverture (`optimsync`, `autosync`, « Not enough
data for sync! range.len: 0 ») : le profil d'objectif embarqué porte
`calibration_data.sync_settings.do_autosync = true`. Le générateur (tâche 7) écrit donc
`calibration_data.sync_settings.do_autosync = false`, `synchronization.do_autosync = false` et
`synchronization.auto_sync_points = false`. Sans effet sur le plugin Resolve, qui lit les `offsets`.
