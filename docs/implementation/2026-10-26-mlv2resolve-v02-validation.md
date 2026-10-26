# mlv2Resolve 0.2 — validation

## Résultat

- Application Release arm64 compilée avec Xcode 26.2, cible minimale macOS 14.
- 255 tests Swift : aucun échec ; 9 tests ignorés faute de rushs/fixtures réels.
- Contrôles moteur `resolve-name-test`, `sidecar-test`, `dual-iso-cache-test` réussis.
- Revue indépendante : deux défauts matériels corrigés (SDK des workflows GitHub et conservation de l’action d’ouverture lors d’un rafraîchissement du script Resolve Free).
- Vérification visuelle du composant principal dans une application de contrôle isolée : quatre sections, tiroir gauche, contrôles de taille/cadence, option All shots activée et nom modifiable. Apparence claire rendue ; apparence sombre vérifiée dans une vraie fenêtre macOS 26.
- Nouvelle icône fournie par l’utilisateur : suppression du damier imprimé pour recréer la transparence, génération des dix tailles, vérification alpha RGBA et coins transparents.

## Resolve 21.1.1 Studio — tests réels

Un projet modèle distinct a été créé. L’utilisateur a réglé les CST :

1. P3-D60 / Linear → DaVinci Wide Gamut / DaVinci Intermediate, actif, tone mapping None.
2. DaVinci Wide Gamut / DaVinci Intermediate → Rec.709 / Rec.709-A, désactivé.

L’application de grades DRX via l’API a provoqué un plantage de Resolve pendant les essais. Cette voie a été abandonnée et ne figure pas dans l’implémentation livrée. Le modèle embarqué est une timeline **DRT vide**. Son import conserve deux CST ; les états des nœuds sont explicitement réappliqués par le script. La timeline accepte une cadence et une résolution différentes de celles du modèle.

La création complète a été exercée avec trois images Bayer DNG synthétiques dans un nouveau projet :

- import d’une séquence DNG réussi ;
- timeline nommée `All shots test`, 25 i/s choisis malgré une source à 24 i/s, 1920 × 1080 ;
- espace de travail de projet `DaVinci WG`, gamma `DaVinci Intermediate`, sortie `Same as Timeline` ;
- deux nœuds CST sur la timeline ; le plan garde son graphe de clip par défaut à un nœud ;
- association retournée après sauvegarde ;
- réouverture via le script dédié : projet, nombre de timelines, nom, cadence et nombre de plans conservés.

L’import DRT ignore `importOptions.timelineName` dans cette version : un `SetName` explicite a été ajouté et testé. Les résultats attendus ont été confirmés par `INTEGRATION_OK` puis `OPEN_ONLY_OK`.

Les données synthétiques n’ont pas de WAV ni de préréglage Camera Raw personnel : les avertissements correspondants étaient attendus. Les anciens préréglages Camera Raw `mlv2dng` restent reconnus pour la migration ; les nouveaux utilisateurs peuvent enregistrer leur préréglage `mlv2Resolve`.

## Limites des vérifications

Les essais ne constituent pas une validation de décodage/lecture/gyro de nouveaux rushs caméra réels. Resolve Free n’est pas installé séparément : sa voie de script de menu est couverte par les tests Lua et les tests de conservation de l’action sélectionnée. L’import du modèle couleur est validé sur Resolve 21.1.1 ; les versions incompatibles reçoivent une erreur explicite.

La release publique v0.2 n’est pas publiée automatiquement par ce travail.
