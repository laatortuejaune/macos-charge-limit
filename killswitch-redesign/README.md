# Script Kill Switch — redesign (principes Apple)

Refonte **front-end uniquement** du tableau de bord *Script Kill Switch*
(worker Cloudflare `script-killswitch`), d'après le skill
[apple-design](https://github.com/emilkowalski/skills/blob/main/skills/apple-design/SKILL.md) :
typographie système SF, matériaux translucides (backdrop-blur), mouvement
« spring » iOS, profondeur, thèmes clair **et** sombre, et prise en charge de
`reduced-motion` / `reduced-transparency` / `contrast`.

Le **back-end n'est pas touché** : le client parle toujours à `/admin/api/*`,
`/admin/login`, `/admin/logout`, `/admin/prototype`. Aucune route serveur, aucune
base D1, aucun beacon n'a été modifié.

## Contenu

| Chemin | Rôle |
| --- | --- |
| `index.html` | **Prévisualisation autonome.** Le site complet (connexion → tableau de bord → prototype) avec des **données de démonstration**, sans back-end. C'est la version à regarder. |
| `worker/admin-ui.js` | **Drop-in** pour `src/admin-ui.ts` du worker : `STYLE`, `CLIENT_JS` (API réelle), `loginPage()`, `dashboardPage()`. |
| `worker/prototype-ui.js` | **Drop-in** pour `src/prototype-ui.ts` : `prototypePage()` (chrome redessiné, panneaux in-game conservés). |
| `backup/worker-script-killswitch.js` | **Sauvegarde** du worker actuellement en ligne (récupéré depuis Cloudflare avant toute modification). |

## La connexion « qui ne bloque pas »

- Dans la **prévisualisation** (`index.html`), l'écran de connexion est redessiné et
  porte une **croix (✕)** + un lien *« Continuer sans se connecter → »* : on voit
  tout le site sans back-end.
- Sur le **site live**, la connexion protège les **vraies commandes** (couper /
  réactiver un script). Le drop-in la **garde donc** — redessinée, mais fonctionnelle.
  La rendre publique exposerait tes contrôles à n'importe qui.
- Si tu veux *vraiment* un tableau de bord public : dans le routeur (`handleAdmin`),
  fais renvoyer `dashboardPage()` au lieu de `loginPage(false)` pour `GET /admin`,
  et retire le garde d'auth des lectures `GET /admin/api/*`. **Déconseillé.**

## Déployer sur Cloudflare

Je n'ai pas pu pousser directement : les outils Cloudflare disponibles dans cette
session sont en **lecture seule** (lister / lire un worker, pas le redéployer). À
faire depuis ton dépôt du worker :

```bash
# 1. Remplace le contenu des deux fichiers source du worker par les drop-ins :
#      src/admin-ui.ts      <-  worker/admin-ui.js
#      src/prototype-ui.ts  <-  worker/prototype-ui.js
#    (adapte les extensions .ts / les types si besoin ; le code est du JS valide.)

# 2. Vérifie en local
npx wrangler dev

# 3. Déploie
npx wrangler deploy
```

Les signatures exportées (`STYLE`, `CLIENT_JS`, `loginPage`, `dashboardPage`,
`prototypePage`) sont **identiques** à l'original, donc `src/routes/admin.ts`
fonctionne sans changement.

## Vérifié

Rendu au navigateur (Chromium) en clair et sombre, plus la feuille de détails, la
feuille de création, la vue prototype et le mode mobile (feuille qui remonte du bas).
Aucune erreur JS. Les pages générées par le drop-in sont identiques, au pixel près,
à la prévisualisation.
