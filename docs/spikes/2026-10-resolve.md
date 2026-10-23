# Validation dans DaVinci Resolve — 23 octobre 2026

Montage : `build/engine/mlvfs` (commits jusqu'à ff3803c) sur FUSE-T 1.2.9 (NFS), lecture seule,
`~/MLV Switch/Test EOS M`, options `--resolve-naming --bad-pix --dual-iso-preview --fpm-dir --index-dir`.
Machine : Apple M4, 24 Go, macOS 26. Resolve Studio 21.0.4, timeline 25 i/s. Test fait par l'utilisateur.

| Point | Résultat |
|---|---|
| Import des séquences `M29-0615` et `M23-1246` | OK |
| Image correcte (décodage LJ92) | OK |
| Focus pixels | Aucun point visible (OK) |
| Lecture temps réel en « Half » sans image perdue | OK |
| Désanamorphose 1x3 | **Non appliquée automatiquement** : Resolve ignore le tag DNG DefaultScale (3/1). L'utilisateur règle le rapport 3:1 à la main, comme il l'a toujours fait. |
| Bascule dual ISO | Non testée : aucun des clips de test n'est en dual ISO (bloc DISO, mode 0). |
| Clip non dual ISO identique en preview / full | Non testé pour la même raison (aucun traitement dual ISO déclenché). |

## Décision

**GO** pour la phase 2 avec FUSE-T (backend NFS par défaut) : montage stable, lecture fluide.

- Rapport de pixel : la v1 affiche un rappel lors du montage d'un tournage anamorphosé ; l'application
  automatique du 3:1 via le scripting de Resolve Studio sera la première fonction de l'étape « Resolve ».
  Étirer les DNG eux-mêmes est écarté (perte du RAW, ×3 de données).
- Dual ISO : à valider plus tard avec un clip dual ISO fourni par l'utilisateur.
