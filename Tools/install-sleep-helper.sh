#!/bin/bash
# Autorise BatteryLimitMenu à basculer la veille capot fermé sans mot de passe.
#
#   Tools/install-sleep-helper.sh            installe la règle
#   Tools/install-sleep-helper.sh uninstall  la retire et réactive la veille
#
# Un `sudo` une fois, ici, et plus jamais ensuite. Ce qui est accordé est
# volontairement minuscule : un seul utilisateur, deux commandes exactes, avec
# leurs arguments écrits en toutes lettres. `pmset` ne peut donc rien faire
# d'autre sous ce droit — ni changer un autre réglage, ni tourner sans argument.
set -euo pipefail

RULE=/etc/sudoers.d/batterylimitmenu-disablesleep
# `id -un` et non $USER : sous sudo, $USER vaut déjà root et la règle serait
# écrite pour le mauvais compte — donc inopérante, et sans le dire.
ACCOUNT="${SUDO_USER:-$(id -un)}"

case "${1:-install}" in
uninstall)
    sudo rm -f "$RULE"
    # Remis à zéro avant de partir : sans ça, retirer la règle laisserait le Mac
    # avec la veille désactivée et plus aucun moyen de la réactiver depuis l'app.
    sudo /usr/bin/pmset -a disablesleep 0
    echo "Retiré. La veille capot fermé est réactivée."
    ;;

install)
    draft="$(mktemp)"
    trap 'rm -f "$draft"' EXIT

    cat > "$draft" <<EOF
# Posé par macos-charge-limit (Tools/install-sleep-helper.sh).
# Laisse BatteryLimitMenu basculer la veille capot fermé sans mot de passe.
# Retrait : Tools/install-sleep-helper.sh uninstall
$ACCOUNT ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
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

    echo "OK. BatteryLimitMenu peut désormais couvrir le capot fermé pour $ACCOUNT."
    echo "Vérification :  sudo -n -l /usr/bin/pmset -a disablesleep 1"
    ;;

*)
    echo "Usage: ${0##*/} [install|uninstall]" >&2
    exit 2
    ;;
esac
