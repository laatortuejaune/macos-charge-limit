#!/bin/bash
# Autorise BatteryLimitMenu à basculer sans mot de passe deux réglages qui
# exigent root : la veille capot fermé, et le mode économie d'énergie.
#
#   Tools/install-helper.sh            installe la règle
#   Tools/install-helper.sh uninstall  la retire et remet les réglages à zéro
#
# Un `sudo` une fois, ici, et plus jamais ensuite. Ce qui est accordé est
# volontairement minuscule : un seul utilisateur, quatre commandes exactes, avec
# leurs arguments écrits en toutes lettres. `pmset` ne peut donc rien faire
# d'autre sous ce droit — ni changer un autre réglage, ni tourner sans argument.
set -euo pipefail

RULE=/etc/sudoers.d/batterylimitmenu
# Ancien nom, du temps où la règle ne couvrait que la veille. Retiré à l'install
# comme à la désinstallation, sinon les deux fichiers coexisteraient.
LEGACY=/etc/sudoers.d/batterylimitmenu-disablesleep
# `id -un` et non $USER : sous sudo, $USER vaut déjà root et la règle serait
# écrite pour le mauvais compte — donc inopérante, et sans le dire.
ACCOUNT="${SUDO_USER:-$(id -un)}"

case "${1:-install}" in
uninstall)
    sudo rm -f "$RULE" "$LEGACY"
    # Remis à zéro avant de partir : sans ça, retirer la règle laisserait le Mac
    # avec la veille désactivée et le mode économie forcé, sans plus aucun moyen
    # de les remettre depuis l'app.
    sudo /usr/bin/pmset -a disablesleep 0
    sudo /usr/bin/pmset -a lowpowermode 0
    echo "Retiré. Veille capot fermé et mode économie sont revenus à la normale."
    ;;

install)
    draft="$(mktemp)"
    trap 'rm -f "$draft"' EXIT

    cat > "$draft" <<EOF
# Posé par macos-charge-limit (Tools/install-helper.sh).
# Laisse BatteryLimitMenu basculer sans mot de passe la veille capot fermé et
# le mode économie d'énergie. Retrait : Tools/install-helper.sh uninstall
$ACCOUNT ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a lowpowermode 1, /usr/bin/pmset -a lowpowermode 0
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

    echo "OK. BatteryLimitMenu peut désormais couvrir le capot fermé et basculer"
    echo "le mode économie pour $ACCOUNT, sans mot de passe."
    echo "Vérification :  sudo -n -l /usr/bin/pmset -a lowpowermode 1"
    ;;

*)
    echo "Usage: ${0##*/} [install|uninstall]" >&2
    exit 2
    ;;
esac
