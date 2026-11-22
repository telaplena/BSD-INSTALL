#!/bin/sh
#
# FreeBSD Pós-Instalação
# ----------------------
# Interface de terminal (setas + Enter) que:
#   1. dá as boas-vindas
#   2. atualiza o sistema (freebsd-update + pkg upgrade)
#   3. instala o sudo e coloca seu usuário no grupo wheel/sudo
#   4. detecta a placa de vídeo e instala o driver certo
#   5. deixa você escolher o ambiente gráfico (KDE, GNOME, XFCE...)
#   6. configura tudo e reinicia
#
# Como usar:
#   - Logo após o bsdinstall, copie este script para o sistema novo
#       cp pos-install.sh /mnt/root/
#     e escolha "Open a shell in the newly installed system".
#   - Ou então, com o sistema já instalado e iniciado, como root:
#       sh pos-install.sh
#

LOG=/var/log/pos-install.log
RCFILE=/tmp/.pos-install.rc

export LC_ALL=C.UTF-8
export ASSUME_ALWAYS_YES=yes
export BATCH=yes
export PAGER=cat
[ -n "$TERM" ] || export TERM=xterm

die() { echo "ERRO: $*" >&2; exit 1; }

[ "$(uname -s)" = "FreeBSD" ] || die "este script é só para FreeBSD."
[ "$(id -u)" -eq 0 ] || die "execute como root."

: > "$LOG" 2>/dev/null || LOG=/tmp/pos-install.log

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
        || die "não consegui instalar o dialog (veja $LOG)."
    DIALOG=dialog
fi

# -------------------------------------------------------- helpers de TUI ---
msg() { $DIALOG --title "$1" --msgbox "$2" 0 0; }
yesno() { $DIALOG --title "$1" --yesno "$2" 0 0; }

ask_menu() { # titulo texto tag item [tag item ...]
    _t=$1; _x=$2; shift 2
    _n=$(($# / 2))
    $DIALOG --title "$_t" --menu "$_x" 0 0 "$_n" "$@" 3>&1 1>&2 2>&3
}

# Executa um comando mostrando a saída numa caixa de progresso.
run() { # titulo comando [args...]
    _title=$1; shift
    rm -f "$RCFILE"
    # trap '' PIPE: o comando não morre se a caixa fechar antes do fim
    { trap '' PIPE; "$@" 2>&1; echo $? > "$RCFILE"; } | tee -a "$LOG" \
        | $DIALOG --title "$_title" --programbox "Aguarde, isso pode demorar. Ao terminar, pressione Enter." 22 78
    [ "$(cat "$RCFILE" 2>/dev/null || echo 1)" -eq 0 ]
}

run_or_ask() { # titulo funcao
    if ! run "$1" "$2"; then
        yesno "Algo deu errado" "A etapa \"$1\" falhou.\n\nDetalhes em $LOG\n\nContinuar mesmo assim?" \
            || { clear; echo "Interrompido. Veja $LOG"; exit 1; }
        FAILED="$FAILED\n - $1"
    fi
}

FAILED=""

pkg_first() { # devolve o primeiro pacote que existir no repositório
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

# ----------------------------------------------------- detecção de GPU -----
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
    # Prioridade: VM > Intel/AMD (suportam KMS livre) > NVIDIA
    if   [ $HAS_VBOX -eq 1 ];   then GPU_KIND=vbox;   GPU_LABEL="VirtualBox (máquina virtual)"
    elif [ $HAS_VMWARE -eq 1 ]; then GPU_KIND=vmware; GPU_LABEL="VMware (máquina virtual)"
    elif [ $HAS_AMD -eq 1 ];    then GPU_KIND=amd;    GPU_LABEL="AMD/Radeon  -> drm-kmod (amdgpu)"
    elif [ $HAS_INTEL -eq 1 ];  then GPU_KIND=intel;  GPU_LABEL="Intel  -> drm-kmod (i915kms)"
    elif [ $HAS_NVIDIA -eq 1 ]; then GPU_KIND=nvidia; GPU_LABEL="NVIDIA  -> nvidia-driver"
    else GPU_KIND=generic; GPU_LABEL="não identificada -> driver genérico (modesetting/scfb)"
    fi
    if [ $HAS_NVIDIA -eq 1 ] && [ "$GPU_KIND" != nvidia ] && [ "$GPU_KIND" != vbox ] && [ "$GPU_KIND" != vmware ]; then
        GPU_LABEL="$GPU_LABEL\n   (NVIDIA híbrida detectada: será usada a placa Intel/AMD)"
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
        *) echo ">> Versão não é RELEASE; pulando freebsd-update."; return 0 ;;
    esac
    command -v freebsd-update >/dev/null 2>&1 || { echo ">> freebsd-update indisponível; pulando."; return 0; }
    echo ">> Baixando e instalando patches do sistema base..."
    freebsd-update --not-running-from-cron fetch install
    # "nada a atualizar" não é erro
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
    echo ">> $TARGET_USER agora está no grupo wheel e pode usar sudo."
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
            echo ">> Nenhum driver específico necessário."
            ;;
    esac
    # áudio
    sysrc -f /boot/loader.conf snd_hda_load=YES
    return 0
}

step_de() {
    [ "$DE" = none ] && { echo ">> Sem ambiente gráfico; nada a fazer."; return 0; }

    pkg install -y xorg dbus || return 1
    pkg install -y dejavu 2>/dev/null

    case $DE in
        kde)
            MAIN=$(pkg_first plasma6-plasma plasma5-plasma kde) || { echo "pacote do KDE não encontrado"; return 1; }
            EXTRAS="konsole dolphin"; DM=sddm; DMPKGS="sddm"
            ;;
        gnome)
            MAIN=$(pkg_first gnome gnome-lite) || { echo "pacote do GNOME não encontrado"; return 1; }
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
    echo ">> Configuração concluída."
}

# ----------------------------------------------------------- 1. boas-vindas
msg "Bem-vindo ao FreeBSD Pós-Instalação" \
"Este assistente vai:

  1. Atualizar o sistema
  2. Instalar o sudo e dar acesso ao seu usuário
  3. Detectar sua placa de vídeo e instalar o driver ideal
  4. Instalar o ambiente gráfico que você escolher
  5. Reiniciar o computador

Use as SETAS para navegar, TAB para trocar de botão e ENTER para confirmar.

Log completo em: $LOG"

# ------------------------------------------------------------ 2. usuário ---
create_user() {
    while :; do
        _name=$($DIALOG --title "Novo usuário" \
            --inputbox "Nome do usuário (só letras minúsculas, números, _ e -):" 0 0 3>&1 1>&2 2>&3) || return 1
        case $_name in
            ''|*[!a-z0-9_-]*|[0-9-]*) msg "Nome inválido" "Use só letras minúsculas, números, _ e -, começando por letra."; continue ;;
        esac
        id "$_name" >/dev/null 2>&1 && { msg "Já existe" "O usuário $_name já existe."; continue; }
        break
    done
    while :; do
        _p1=$($DIALOG --title "Senha" --passwordbox "Senha para $_name:" 0 0 3>&1 1>&2 2>&3) || return 1
        _p2=$($DIALOG --title "Senha" --passwordbox "Repita a senha:" 0 0 3>&1 1>&2 2>&3) || return 1
        [ -n "$_p1" ] || { msg "Senha vazia" "A senha não pode ser vazia."; continue; }
        [ "$_p1" = "$_p2" ] || { msg "Senhas diferentes" "As senhas não conferem. Tente de novo."; continue; }
        break
    done
    printf '%s\n' "$_p1" | pw useradd "$_name" -m -s /bin/sh -c "$_name" -G wheel,video -h 0 \
        || { msg "Erro" "Não consegui criar o usuário."; return 1; }
    TARGET_USER=$_name
}

TARGET_USER=""
while [ -z "$TARGET_USER" ]; do
    set --
    for _u in $(awk -F: '$3>=1001 && $3<65534 {print $1}' /etc/passwd); do
        set -- "$@" "$_u" "usuário existente"
    done
    set -- "$@" "__novo__" "Criar um novo usuário"
    _choice=$(ask_menu "Usuário" "Qual usuário deve virar administrador (sudo)?" "$@") \
        || { clear; echo "Cancelado."; exit 0; }
    if [ "$_choice" = "__novo__" ]; then
        create_user || true
    else
        TARGET_USER=$_choice
    fi
done

# ------------------------------------------- 3. hardware + escolha de DE ---
detect_gpu

DE=$(ask_menu "Ambiente gráfico" "Escolha a interface gráfica (setas + Enter):" \
    kde      "KDE Plasma  - moderno e personalizável" \
    gnome    "GNOME       - simples e elegante" \
    xfce     "XFCE        - leve e estável" \
    mate     "MATE        - clássico, estilo GNOME 2" \
    cinnamon "Cinnamon    - familiar, estilo tradicional" \
    lxqt     "LXQt        - super leve" \
    none     "Nenhum      - só terminal") \
    || { clear; echo "Cancelado."; exit 0; }

yesno "Confirmar" \
"Tudo pronto para começar:

  Usuário sudo : $TARGET_USER
  Placa de vídeo: ${GPU_NAME:-não identificada}
  Driver        : $GPU_LABEL
  Interface     : $DE

O computador será reiniciado no final.
Iniciar agora?" || { clear; echo "Cancelado."; exit 0; }

# -------------------------------------------------------------- 4. executa --
run_or_ask "1/5 Atualizando pacotes"        step_update
run_or_ask "2/5 Atualizando o sistema base" step_fbupdate
run_or_ask "3/5 Instalando e configurando o sudo" step_sudo
run_or_ask "4/5 Instalando drivers de vídeo/áudio" step_drivers
run_or_ask "5/5 Instalando a interface gráfica ($DE)" step_de
run_or_ask "Finalizando" step_finalize

# --------------------------------------------------------------- 5. fim -----
_resumo="Pronto!

  Usuário sudo : $TARGET_USER
  Driver       : $GPU_LABEL
  Interface    : $DE"
[ -n "$FAILED" ] && _resumo="$_resumo\n\nAtenção, estas etapas falharam:$FAILED\n(veja $LOG)"
_resumo="$_resumo\n\nDica: se o sistema base recebeu atualização de kernel, depois do reboot rode:  freebsd-update install"
msg "Concluído" "$_resumo"

# Detecta se estamos num chroot do instalador (raiz montada em /mnt)
_root_mnt=$(df / 2>/dev/null | awk 'NR==2 {print $NF}')
if [ -n "$_root_mnt" ] && [ "$_root_mnt" != "/" ]; then
    msg "Quase lá" "Você está dentro do shell do instalador.\n\nDigite  exit  e escolha  Reboot  no menu do bsdinstall para reiniciar com segurança."
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
