# Group Post Clip Kodak : liaison ignorée par Resolve

## Défaut et correction

Le modèle `resolve-color-kodak2383.drt` contenait deux liaisons série avec le même
identifiant de connexion (champ protobuf 7 = 2). Resolve affichait les trois nœuds,
mais supprimait la dernière liaison lors de la normalisation du graphe. Le
Group Post Clip n’avait alors aucun effet visible.

La correction modifie uniquement l’identifiant de la deuxième liaison de 2 à 3.
Les nœuds, leurs réglages CST, la LUT et les autres données restent identiques.
Les identifiants de nœuds et ceux des connexions sont des espaces distincts : leur
chevauchement n’est pas une erreur. Ce sont les identifiants des connexions qui
doivent être uniques entre eux.

## Vérification

- Comparaison avec une chaîne de trois nœuds créée nativement dans Resolve.
- Projet de diagnostic réimporté, enregistré, puis réexporté : les deux liaisons
  restent présentes, avec les identifiants 2 et 3.
- Contrôle visuel sur le même photogramme : activation/désactivation des trois
  nœuds modifie bien le contraste, les couleurs et les scopes.
- Le projet UPDLV initial est conservé sous un nom de sauvegarde et en DRP ; la
  copie corrigée conserve la timeline et ses 65 clips groupés.
- Tests : unicité des connexions et chemin complet passant par chaque nœud ;
  suite Swift de 287 tests, 12 tests optionnels ignorés, aucune erreur.
- Application 0.2.6 build 111 compilée et signée.

Attention pour les diagnostics : appeler `SaveProject()` avant `ExportProject()`
pour examiner les modifications actives. Un export seul peut refléter un état
précédent enregistré et induire en erreur sur les connexions réellement utilisées.
