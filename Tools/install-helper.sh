#!/bin/bash
# Autorise BatteryLimitMenu à basculer sans mot de passe trois réglages qui
# exigent root : la veille capot fermé, le mode économie d'énergie, et la
# suspension de charge.
#
#   Tools/install-helper.sh            installe la règle
#   Tools/install-helper.sh uninstall  la retire et remet les réglages à zéro
#
# Un `sudo` une fois, ici, et plus jamais ensuite. Ce qui est accordé est
# volontairement minuscule : un seul utilisateur, six commandes exactes, avec
# leurs arguments écrits en toutes lettres. `pmset` ne peut donc rien faire
# d'autre sous ce droit — ni changer un autre réglage, ni tourner sans argument.
#
# LE HELPER SMC EST LE POINT DÉLICAT. Une règle sudoers désigne un CHEMIN. Si le
# binaire qui s'y trouve est modifiable par l'utilisateur, la règle cesse d'être
# une permission étroite et devient une élévation de privilège : il suffit de
# remplacer le fichier pour faire exécuter n'importe quoi en root, sans mot de
# passe. Le helper est donc copié HORS du dépôt, en root:wheel et 755 — jamais
# exécuté depuis .build/ ou depuis le bundle, que l'utilisateur peut réécrire.
set -euo pipefail

RULE=/etc/sudoers.d/batterylimitmenu
# Ancien nom, du temps où la règle ne couvrait que la veille. Retiré à l'install
# comme à la désinstallation, sinon les deux fichiers coexisteraient.
LEGACY=/etc/sudoers.d/batterylimitmenu-disablesleep
HELPER=/usr/local/libexec/batterylimitmenu-smc
# `id -un` et non $USER : sous sudo, $USER vaut déjà root et la règle serait
# écrite pour le mauvais compte — donc inopérante, et sans le dire.
ACCOUNT="${SUDO_USER:-$(id -un)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

case "${1:-install}" in
uninstall)
    # La charge d'abord, tant que la règle existe encore : après suppression,
    # plus rien ne pourrait la rendre sans mot de passe.
    if [ -x "$HELPER" ]; then sudo "$HELPER" off >/dev/null 2>&1 || true; fi
    sudo rm -f "$RULE" "$LEGACY" "$HELPER"
    # Remis à zéro avant de partir : sans ça, retirer la règle laisserait le Mac
    # avec la veille désactivée et le mode économie forcé, sans plus aucun moyen
    # de les remettre depuis l'app.
    sudo /usr/bin/pmset -a disablesleep 0
    sudo /usr/bin/pmset -a lowpowermode 0
    echo "Retiré. Veille, mode économie et charge sont revenus à la normale."
    ;;

install)
    # Le helper est compilé depuis les sources du dépôt : ce qui tournera en root
    # est donc exactement ce qui est lisible dans Sources/SMCChargeHelper.
    echo "Compilation du helper…"
    ( cd "$ROOT" && swift build -c release --product SMCChargeHelper >/dev/null )
    built="$(cd "$ROOT" && swift build -c release --show-bin-path)/SMCChargeHelper"
    [ -x "$built" ] || { echo "Helper introuvable après compilation." >&2; exit 1; }

    # -o root -g wheel -m 755 : exécutable par tous, modifiable par root seul.
    # C'est cette propriété, et non le chemin en lui-même, qui empêche la règle
    # sudoers de devenir une porte dérobée.
    sudo install -d -o root -g wheel -m 755 "$(dirname "$HELPER")"
    sudo install -m 755 -o root -g wheel "$built" "$HELPER"

    draft="$(mktemp)"
    trap 'rm -f "$draft"' EXIT

    cat > "$draft" <<EOF
# Posé par macos-charge-limit (Tools/install-helper.sh).
# Laisse BatteryLimitMenu basculer sans mot de passe la veille capot fermé, le
# mode économie d'énergie et la suspension de charge.
# Retrait : Tools/install-helper.sh uninstall
$ACCOUNT ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a lowpowermode 1, /usr/bin/pmset -a lowpowermode 0, $HELPER on, $HELPER off
EOF

    # Étape non négociable. Une faute de frappe dans un fichier de /etc/sudoers.d
    # casse `sudo` ENTIÈREMENT — y compris la commande qu'il faudrait pour
    # réparer. On valide donc la syntaxe avant de poser le fichier, jamais après.
    if ! sudo visudo -c -f "$draft" >/dev/null; then
        echo "Refusé : la règle générée ne compile pas. Rien n'a été installé." >&2
        exit 1
    fi

    # 0440 root:wheel, exigé par sudo : il ignore — silencieusement — tout
    # fichier de sudoers.d dont les droits sont plus larges.
    sudo install -m 0440 -o root -g wheel "$draft" "$RULE"
    # Migration : si l'ancienne règle traîne, elle ferait doublon.
    sudo rm -f "$LEGACY"

    echo "OK. BatteryLimitMenu peut désormais couvrir le capot fermé, basculer le"
    echo "mode économie et suspendre la charge pour $ACCOUNT, sans mot de passe."
    echo "Vérification :  $HELPER status"
    ;;

*)
    echo "Usage: ${0##*/} [install|uninstall]" >&2
    exit 2
    ;;
esac
