#!/bin/sh
#
# FreeBSD Pos-Instalacao
# ----------------------
# Interface de terminal (setas + Enter) que:
#   1. da as boas-vindas
#   2. atualiza o sistema (freebsd-update + pkg upgrade)
#   3. instala o sudo e coloca seu usuario no grupo wheel/sudo
#   4. detecta a placa de video e instala o driver certo
#   5. deixa voce escolher o ambiente grafico (KDE, GNOME, XFCE...)
#   6. configura tudo e reinicia
#
# Como usar:
#   - Logo apos o bsdinstall, escolha "Open a shell in the newly installed system"
#     e rode:  sh pos-install.sh
#   - Ou, com o sistema ja instalado e iniciado, como root:  sh pos-install.sh
#
# Obs.: os textos da interface ficam sem acentos de proposito, porque o console
# do FreeBSD mostra "?" no lugar deles.
#

LOG=/var/log/pos-install.log
RCFILE=/tmp/.pos-install.rc

export LC_ALL=C
export ASSUME_ALWAYS_YES=yes
export BATCH=yes
export PAGER=cat
export PATH="$PATH:/usr/local/bin:/usr/local/sbin"
[ -n "$TERM" ] || export TERM=xterm

# quebra de linha real (evita depender de "\n" no texto)
NL='
'

die() { echo "ERRO: $*" >&2; exit 1; }

[ "$(uname -s)" = "FreeBSD" ] || die "este script e so para FreeBSD."
[ "$(id -u)" -eq 0 ] || die "execute como root."

: > "$LOG" 2>/dev/null || LOG=/tmp/pos-install.log

# ------------------------------------------------- texto sem acentos -------
Tf() {
    LC_ALL=C sed \
        -e 's/á/a/g' -e 's/à/a/g' -e 's/â/a/g' -e 's/ã/a/g' -e 's/ä/a/g' \
        -e 's/é/e/g' -e 's/è/e/g' -e 's/ê/e/g' -e 's/ë/e/g' \
        -e 's/í/i/g' -e 's/ì/i/g' -e 's/î/i/g' -e 's/ï/i/g' \
        -e 's/ó/o/g' -e 's/ò/o/g' -e 's/ô/o/g' -e 's/õ/o/g' -e 's/ö/o/g' \
        -e 's/ú/u/g' -e 's/ù/u/g' -e 's/û/u/g' -e 's/ü/u/g' \
        -e 's/ç/c/g' -e 's/ñ/n/g' \
        -e 's/Á/A/g' -e 's/À/A/g' -e 's/Â/A/g' -e 's/Ã/A/g' \
        -e 's/É/E/g' -e 's/Ê/E/g' -e 's/Í/I/g' \
        -e 's/Ó/O/g' -e 's/Ô/O/g' -e 's/Õ/O/g' -e 's/Ú/U/g' -e 's/Ç/C/g'
}
T() { printf '%s' "$1" | Tf; }

# ---------------------------------------------------------------- rede ----
ensure_network() {
    ping -c1 -t5 1.1.1.1 >/dev/null 2>&1 || return 1
    if ! getent hosts pkg.freebsd.org >/dev/null 2>&1; then
        printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
        getent hosts pkg.freebsd.org >/dev/null 2>&1 || return 1
    fi
    return 0
}

ensure_network || die "sem internet. Configure a rede (ex.: dhclient em0) e rode de novo."

# ------------------------------------------------------ ferramenta de TUI --
if command -v bsddialog >/dev/null 2>&1; then
    DIALOG=bsddialog
elif command -v dialog >/dev/null 2>&1; then
    DIALOG=dialog
else
    echo "Instalando o 'dialog' para montar a interface..."
    pkg bootstrap -f >>"$LOG" 2>&1 && pkg install -y dialog >>"$LOG" 2>&1 \
        || die "nao consegui instalar o dialog (veja $LOG)."
    DIALOG=dialog
fi

# -------------------------------------------------------- helpers de TUI ---
msg()   { $DIALOG --title "$(T "$1")" --msgbox "$(T "$2")" 0 0; }
yesno() { $DIALOG --title "$(T "$1")" --yesno "$(T "$2")" 0 0; }

ask_menu() { # titulo texto tag item [tag item ...]
    _t=$(T "$1"); _x=$(T "$2"); shift 2
    _n=$(($# / 2))
    _i=0; _c=$#
    while [ $_i -lt $_c ]; do
        set -- "$@" "$(T "$1")"; shift
        _i=$((_i + 1))
    done
    $DIALOG --title "$_t" --menu "$_x" 0 0 "$_n" "$@" 3>&1 1>&2 2>&3
}

ask_input() { # titulo texto
    $DIALOG --title "$(T "$1")" --inputbox "$(T "$2")" 0 0 3>&1 1>&2 2>&3
}

ask_pass() { # titulo texto
    $DIALOG --title "$(T "$1")" --passwordbox "$(T "$2")" 0 0 3>&1 1>&2 2>&3
}

# Executa um comando em segundo plano (saida vai para o log) e mostra as
# ultimas linhas do log numa caixa de informacao enquanto ele roda.
run() { # titulo comando [args...]
    _title=$(T "$1"); shift
    rm -f "$RCFILE"
    ( "$@" >>"$LOG" 2>&1; echo $? > "$RCFILE" ) &
    _pid=$!
    while kill -0 "$_pid" 2>/dev/null; do
        _tail=$(tail -n 40 "$LOG" | tr '\r' '\n' | tr -cd '[:print:]\n' \
                | tail -n 8 | cut -c1-70 | Tf)
        $DIALOG --title "$_title" --infobox "Aguarde, isso pode demorar...${NL}${NL}${_tail}" 16 76
        sleep 2
    done
    wait "$_pid" 2>/dev/null
    [ "$(cat "$RCFILE" 2>/dev/null || echo 1)" -eq 0 ]
}

FAILED=""

run_or_ask() { # titulo funcao
    if ! run "$1" "$2"; then
        yesno "Algo deu errado" "A etapa \"$1\" falhou.${NL}${NL}Detalhes em $LOG${NL}${NL}Continuar mesmo assim?" \
            || { clear; echo "Interrompido. Veja $LOG"; exit 1; }
        FAILED="$FAILED${NL} - $1"
    fi
}

pkg_first() { # devolve o primeiro pacote que existir no repositorio
    for _p in "$@"; do
        if [ -n "$(pkg rquery -e "%n == $_p" %n 2>/dev/null)" ]; then
            echo "$_p"; return 0
        fi
    done
    return 1
}

add_kld() {
    for _m in "$@"; do
        case " $(sysrc -n kld_list 2>/dev/null) " in
            *" $_m "*) ;;
            *) sysrc kld_list+=" $_m" ;;
        esac
    done
}

# ----------------------------------------------------- deteccao de GPU -----
detect_gpu() {
    GPU_IDS=$(pciconf -l 2>/dev/null | grep 'class=0x03' \
        | sed -n 's/.*vendor=0x\([0-9a-f]*\).*/\1/p')
    GPU_NAME=$(pciconf -lv 2>/dev/null | grep -A4 '^vgapci' \
        | sed -n "s/^ *device *= *'\(.*\)'/\1/p" | head -n 2 | tr '\n' ' ')
    HAS_INTEL=0; HAS_AMD=0; HAS_NVIDIA=0; HAS_VBOX=0; HAS_VMWARE=0
    for _id in $GPU_IDS; do
        case $_id in
            8086) HAS_INTEL=1 ;;
            1002) HAS_AMD=1 ;;
            10de) HAS_NVIDIA=1 ;;
            80ee) HAS_VBOX=1 ;;
            15ad) HAS_VMWARE=1 ;;
        esac
    done
    # Prioridade: VM > AMD > Intel (KMS livre) > NVIDIA
    if   [ $HAS_VBOX -eq 1 ];   then GPU_KIND=vbox;   GPU_LABEL="VirtualBox (maquina virtual)"
    elif [ $HAS_VMWARE -eq 1 ]; then GPU_KIND=vmware; GPU_LABEL="VMware (maquina virtual)"
    elif [ $HAS_AMD -eq 1 ];    then GPU_KIND=amd;    GPU_LABEL="AMD/Radeon -> drm-kmod (amdgpu)"
    elif [ $HAS_INTEL -eq 1 ];  then GPU_KIND=intel;  GPU_LABEL="Intel -> drm-kmod (i915kms)"
    elif [ $HAS_NVIDIA -eq 1 ]; then GPU_KIND=nvidia; GPU_LABEL="NVIDIA -> nvidia-driver"
    else GPU_KIND=generic; GPU_LABEL="nao identificada -> driver generico (modesetting/scfb)"
    fi
    if [ $HAS_NVIDIA -eq 1 ] && [ "$GPU_KIND" != nvidia ] && [ "$GPU_KIND" != vbox ] && [ "$GPU_KIND" != vmware ]; then
        GPU_LABEL="$GPU_LABEL${NL}                (NVIDIA hibrida detectada: sera usada a Intel/AMD)"
    fi
}

# ---------------------------------------------------------------- etapas ---
step_update() {
    echo ">> Preparando o pkg..."
    pkg bootstrap -f || return 1
    pkg update -f || return 1
    echo ">> Atualizando pacotes..."
    pkg upgrade -y
}

step_fbupdate() {
    case "$(freebsd-version 2>/dev/null)" in
        *-RELEASE*) ;;
        *) echo ">> Versao nao e RELEASE; pulando freebsd-update."; return 0 ;;
    esac
    command -v freebsd-update >/dev/null 2>&1 || { echo ">> freebsd-update indisponivel; pulando."; return 0; }
    echo ">> Baixando e instalando patches do sistema base..."
    freebsd-update --not-running-from-cron fetch install
    # "nada a atualizar" nao e erro
    return 0
}

step_sudo() {
    pkg install -y sudo || return 1
    mkdir -p /usr/local/etc/sudoers.d
    echo '%wheel ALL=(ALL:ALL) ALL' > /usr/local/etc/sudoers.d/10-wheel
    chmod 440 /usr/local/etc/sudoers.d/10-wheel
    if ! /usr/local/sbin/visudo -cf /usr/local/etc/sudoers.d/10-wheel; then
        rm -f /usr/local/etc/sudoers.d/10-wheel
        return 1
    fi
    pw groupmod wheel -m "$TARGET_USER" || return 1
    pw groupmod video -m "$TARGET_USER" 2>/dev/null
    echo ">> $TARGET_USER agora esta no grupo wheel e pode usar sudo."
}

step_drivers() {
    case $GPU_KIND in
        intel)
            pkg install -y drm-kmod || return 1
            pkg install -y gpu-firmware-intel-kmod 2>/dev/null
            add_kld i915kms
            ;;
        amd)
            pkg install -y drm-kmod || return 1
            pkg install -y gpu-firmware-amd-kmod 2>/dev/null
            add_kld amdgpu
            ;;
        nvidia)
            pkg install -y nvidia-driver nvidia-settings || return 1
            add_kld nvidia-modeset
            echo ">> Se sua NVIDIA for antiga, talvez precise de nvidia-driver-470/390."
            ;;
        vbox)
            pkg install -y virtualbox-ose-additions || return 1
            sysrc vboxguest_enable=YES vboxservice_enable=YES
            ;;
        vmware)
            pkg install -y open-vm-tools xf86-video-vmware || return 1
            sysrc vmware_guestd_enable=YES vmware_guest_vmblock_enable=YES \
                  vmware_guest_vmmemctl_enable=YES
            ;;
        *)
            echo ">> Nenhum driver especifico necessario."
            ;;
    esac
    # audio
    sysrc -f /boot/loader.conf snd_hda_load=YES
    return 0
}

step_de() {
    [ "$DE" = none ] && { echo ">> Sem ambiente grafico; nada a fazer."; return 0; }

    pkg install -y xorg dbus || return 1
    pkg install -y dejavu 2>/dev/null

    case $DE in
        kde)
            MAIN=$(pkg_first plasma6-plasma plasma5-plasma kde) || { echo "pacote do KDE nao encontrado"; return 1; }
            EXTRAS="konsole dolphin"; DM=sddm; DMPKGS="sddm"
            ;;
        gnome)
            MAIN=$(pkg_first gnome gnome-lite) || { echo "pacote do GNOME nao encontrado"; return 1; }
            EXTRAS=""; DM=gdm; DMPKGS="gdm"
            ;;
        xfce)
            MAIN=xfce; EXTRAS="xfce4-goodies"; DM=lightdm; DMPKGS="lightdm lightdm-gtk-greeter"
            ;;
        mate)
            MAIN=mate; EXTRAS=""; DM=lightdm; DMPKGS="lightdm lightdm-gtk-greeter"
            ;;
        cinnamon)
            MAIN=cinnamon; EXTRAS=""; DM=lightdm; DMPKGS="lightdm lightdm-gtk-greeter"
            ;;
        lxqt)
            MAIN=lxqt; EXTRAS=""; DM=sddm; DMPKGS="sddm"
            ;;
    esac

    echo ">> Instalando $MAIN (pode demorar bastante)..."
    pkg install -y $MAIN $DMPKGS || return 1
    for _e in $EXTRAS; do pkg install -y "$_e" 2>/dev/null; done

    sysrc dbus_enable=YES
    case $DM in
        sddm)    sysrc sddm_enable=YES ;;
        gdm)     sysrc gdm_enable=YES gnome_enable=YES ;;
        lightdm) sysrc lightdm_enable=YES ;;
    esac
    return 0
}

step_finalize() {
    grep -q '^proc' /etc/fstab 2>/dev/null || echo 'proc /proc procfs rw 0 0' >> /etc/fstab
    echo ">> Configuracao concluida."
}

# ----------------------------------------------------------- 1. boas-vindas
msg "Bem-vindo ao FreeBSD Pos-Instalacao" \
"Este assistente vai:

  1. Atualizar o sistema
  2. Instalar o sudo e dar acesso ao seu usuario
  3. Detectar sua placa de video e instalar o driver ideal
  4. Instalar o ambiente grafico que voce escolher
  5. Reiniciar o computador

Use as SETAS para navegar, TAB para trocar de botao e ENTER para confirmar.

Log completo em: $LOG"

# ------------------------------------------------------------ 2. usuario ---
create_user() {
    while :; do
        _name=$(ask_input "Novo usuario" "Nome do usuario (so letras minusculas, numeros, _ e -):") || return 1
        case $_name in
            ''|*[!a-z0-9_-]*|[0-9-]*) msg "Nome invalido" "Use so letras minusculas, numeros, _ e -, comecando por letra."; continue ;;
        esac
        id "$_name" >/dev/null 2>&1 && { msg "Ja existe" "O usuario $_name ja existe."; continue; }
        break
    done
    while :; do
        _p1=$(ask_pass "Senha" "Senha para $_name:") || return 1
        _p2=$(ask_pass "Senha" "Repita a senha:") || return 1
        [ -n "$_p1" ] || { msg "Senha vazia" "A senha nao pode ser vazia."; continue; }
        [ "$_p1" = "$_p2" ] || { msg "Senhas diferentes" "As senhas nao conferem. Tente de novo."; continue; }
        break
    done
    printf '%s\n' "$_p1" | pw useradd "$_name" -m -s /bin/sh -c "$_name" -G wheel,video -h 0 \
        || { msg "Erro" "Nao consegui criar o usuario."; return 1; }
    TARGET_USER=$_name
}

TARGET_USER=""
while [ -z "$TARGET_USER" ]; do
    set --
    for _u in $(awk -F: '$3>=1001 && $3<65534 {print $1}' /etc/passwd); do
        set -- "$@" "$_u" "usuario existente"
    done
    set -- "$@" "__novo__" "Criar um novo usuario"
    _choice=$(ask_menu "Usuario" "Qual usuario deve virar administrador (sudo)?" "$@") \
        || { clear; echo "Cancelado."; exit 0; }
    if [ "$_choice" = "__novo__" ]; then
        create_user || true
    else
        TARGET_USER=$_choice
    fi
done

# ------------------------------------------- 3. hardware + escolha de DE ---
detect_gpu

DE=$(ask_menu "Ambiente grafico" "Escolha a interface grafica (setas + Enter):" \
    kde      "KDE Plasma  - moderno e personalizavel" \
    gnome    "GNOME       - simples e elegante" \
    xfce     "XFCE        - leve e estavel" \
    mate     "MATE        - classico, estilo GNOME 2" \
    cinnamon "Cinnamon    - familiar, estilo tradicional" \
    lxqt     "LXQt        - super leve" \
    none     "Nenhum      - so terminal") \
    || { clear; echo "Cancelado."; exit 0; }

yesno "Confirmar" \
"Tudo pronto para comecar:

  Usuario sudo : $TARGET_USER
  Placa de video: ${GPU_NAME:-nao identificada}
  Driver        : $GPU_LABEL
  Interface     : $DE

O computador sera reiniciado no final.
Iniciar agora?" || { clear; echo "Cancelado."; exit 0; }

# -------------------------------------------------------------- 4. executa --
run_or_ask "1/5 Atualizando pacotes"                 step_update
run_or_ask "2/5 Atualizando o sistema base"          step_fbupdate
run_or_ask "3/5 Instalando e configurando o sudo"    step_sudo
run_or_ask "4/5 Instalando drivers de video/audio"   step_drivers
run_or_ask "5/5 Instalando a interface grafica ($DE)" step_de
run_or_ask "Finalizando"                             step_finalize

# --------------------------------------------------------------- 5. fim -----
_resumo="Pronto!

  Usuario sudo : $TARGET_USER
  Driver       : $GPU_LABEL
  Interface    : $DE"
if [ -n "$FAILED" ]; then
    _resumo="$_resumo${NL}${NL}Atencao, estas etapas falharam:$FAILED${NL}(veja $LOG)"
fi
_resumo="$_resumo${NL}${NL}Dica: se o sistema base recebeu atualizacao de kernel, depois do reboot rode:  freebsd-update install"
msg "Concluido" "$_resumo"

# Detecta se estamos num chroot do instalador (raiz montada em /mnt)
_root_mnt=$(df / 2>/dev/null | awk 'NR==2 {print $NF}')
if [ -n "$_root_mnt" ] && [ "$_root_mnt" != "/" ]; then
    msg "Quase la" "Voce esta dentro do shell do instalador.${NL}${NL}Digite  exit  e escolha  Reboot  no menu do bsdinstall para reiniciar com seguranca."
    clear
    exit 0
fi

if yesno "Reiniciar" "Reiniciar o computador agora?"; then
    clear
    echo "Reiniciando..."
    sync
    shutdown -r now
else
    clear
    echo "Ok. Reinicie quando quiser com:  shutdown -r now"
fi
