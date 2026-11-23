#!/bin/sh
#
# FreeBSD Pos-Instalacao  v4
# --------------------------
# Assistente de terminal (setas + Enter) que deixa o FreeBSD pronto para uso:
#   - diagnostica o sistema e CORRIGE sozinho o que da (rede/DHCP, DNS, relogio,
#     catalogo do pkg, pacotes ausentes, modulos de kernel inexistentes...)
#   - atualiza o sistema, instala o sudo e da acesso ao seu usuario
#   - detecta a placa de video e instala o driver certo (inclusive NVIDIA antiga)
#   - instala o ambiente grafico escolhido
#   - aplica seguranca basica (firewall pf, sysctl, sem sendmail, ntpd)
#   - verifica tudo no final e reinicia
#
# Uso:  sh pos-install.sh [opcoes]      (veja: sh pos-install.sh --help)
#
# Obs.: os textos da interface ficam sem acentos de proposito, porque o console
# do FreeBSD mostra "?" no lugar deles.
#

VERSION="4.0"
R="${POS_ROOT:-}"            # prefixo de raiz (so para testes; vazio = sistema real)
umask 022

LOG="$R/var/log/pos-install.log"
BACKUP="$R/var/backups/pos-install"
LOCK="$R/var/run/pos-install.lock"
STAMP=$(date +%Y%m%d-%H%M%S)
WORK=""
BGPIDS=""
PKGUPD_PID=""
FBU_PID=""
FAILED=""

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

usage() {
    cat <<EOF
FreeBSD Pos-Instalacao v$VERSION

Uso: sh pos-install.sh [opcoes]

  -y, --auto        modo automatico: sem perguntas (usa padroes e as opcoes abaixo)
      --user NOME   usuario que vira administrador (e criado se nao existir)
      --de NOME     kde | gnome | xfce | mate | cinnamon | lxqt | none
      --nvidia PKG  nvidia-driver | nvidia-driver-580 | nvidia-driver-470 | nvidia-driver-390
      --no-harden   nao aplicar firewall pf nem endurecimento do sysctl
      --no-reboot   nao reiniciar no final
  -h, --help        mostra esta ajuda
EOF
}

# --------------------------------------------------------------- opcoes ----
AUTO=0; OPT_USER=""; OPT_DE=""; OPT_NV=""; NO_REBOOT=0; NO_HARDEN=0
while [ $# -gt 0 ]; do
    case $1 in
        -y|--auto)   AUTO=1 ;;
        --user)      [ $# -ge 2 ] || die "--user precisa de um nome"; OPT_USER=$2; shift ;;
        --de)        [ $# -ge 2 ] || die "--de precisa de um valor"; OPT_DE=$2; shift ;;
        --nvidia)    [ $# -ge 2 ] || die "--nvidia precisa de um pacote"; OPT_NV=$2; shift ;;
        --no-harden) NO_HARDEN=1 ;;
        --no-reboot) NO_REBOOT=1 ;;
        -h|--help)   usage; exit 0 ;;
        *)           usage >&2; die "opcao desconhecida: $1" ;;
    esac
    shift
done
case $OPT_DE in ''|kde|gnome|xfce|mate|cinnamon|lxqt|none) ;; *) die "--de invalido: $OPT_DE" ;; esac
case $OPT_NV in ''|nvidia-driver|nvidia-driver-580|nvidia-driver-470|nvidia-driver-390) ;; *) die "--nvidia invalido: $OPT_NV" ;; esac
case $OPT_USER in ''|*[!a-z0-9_-]*|[0-9-]*) [ -z "$OPT_USER" ] || die "--user invalido: $OPT_USER" ;; esac

[ "$(uname -s)" = "FreeBSD" ] || die "este script e so para FreeBSD."
[ "$(id -u)" -eq 0 ] || die "execute como root."

# ---------------------------------------------- travas, log e limpeza -------
mkdir -p "$R/var/run" "$R/var/log" "$BACKUP" 2>/dev/null
chmod 700 "$BACKUP" 2>/dev/null

if ! mkdir "$LOCK" 2>/dev/null; then
    _old=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$_old" ] && kill -0 "$_old" 2>/dev/null; then
        die "ja existe outra execucao em andamento (PID $_old)."
    fi
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null || die "nao consegui criar a trava $LOCK."
fi
echo $$ > "$LOCK/pid"

WORK=$(mktemp -d /tmp/pos-install.XXXXXX 2>/dev/null) || die "nao consegui criar pasta temporaria."
chmod 700 "$WORK"
: > "$WORK/report.txt"

[ -f "$LOG" ] && mv -f "$LOG" "$LOG.1" 2>/dev/null
: > "$LOG" 2>/dev/null || LOG="$WORK/pos-install.log"
chmod 600 "$LOG" 2>/dev/null

cleanup() {
    _rc=$?
    trap - EXIT INT TERM HUP
    # shellcheck disable=SC2086
    [ -n "$BGPIDS" ] && kill $BGPIDS 2>/dev/null
    rm -rf "$LOCK" "$WORK" 2>/dev/null
    exit $_rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

log()  { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG"; }
say()  { printf '%s\n' "$*"; log "$*"; }
note() { printf '%s\n' "$*" >> "$WORK/report.txt"; log "$*"; }

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

# ------------------------------------------------------ utilitarios --------
tmo() { # segundos comando... (usa timeout(1) se existir)
    _s=$1; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$_s" "$@"; else "$@"; fi
}

retry() { # tentativas comando...
    _n=$1; shift; _i=1
    while :; do
        "$@" && return 0
        [ "$_i" -ge "$_n" ] && return 1
        log "tentativa $_i falhou: $*"
        _i=$((_i + 1))
        sleep $((_i * 3))
    done
}

backup_file() {
    for _f in "$@"; do
        [ -f "$_f" ] || continue
        _b="$BACKUP/$(basename "$_f").$STAMP"
        [ -f "$_b" ] || cp -p "$_f" "$_b"
    done
}

conf_set() { # arquivo chave valor   (formato chave=valor, idempotente)
    _f=$1; _k=$2; _v=$3
    [ -f "$_f" ] || : > "$_f"
    if grep -q "^${_k}=" "$_f"; then
        sed "s|^${_k}=.*|${_k}=${_v}|" "$_f" > "$_f.tmp" && mv -f "$_f.tmp" "$_f"
    else
        printf '%s=%s\n' "$_k" "$_v" >> "$_f"
    fi
}

free_mb() { # caminho
    df -kP "$1" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024}'
}

# ============================================================ ETAPA 0 ======
# Diagnostico em texto simples (antes da interface): ferramentas, rede, relogio
# ===========================================================================
check_tools() {
    _missing=""
    for _t in pciconf awk sed grep sysrc pw pkg getent df tail cut tr kill sort \
              sleep sync shutdown ifconfig sysctl mktemp date head id mkdir chmod; do
        command -v "$_t" >/dev/null 2>&1 || _missing="$_missing $_t"
    done
    if [ -n "$_missing" ]; then
        die "ferramentas ausentes:$_missing (sistema base incompleto; em pkgbase instale o pacote FreeBSD-utilities)."
    fi
}

net_ok() { ping -c1 -t4 1.1.1.1 >/dev/null 2>&1 || ping -c1 -t4 8.8.8.8 >/dev/null 2>&1; }
dns_ok() { getent hosts pkg.freebsd.org >/dev/null 2>&1; }

fix_network() {
    if ! net_ok; then
        say "Sem rede: tentando DHCP automaticamente..."
        for _if in $(ifconfig -l); do
            case $_if in lo*|pflog*|pfsync*|enc*|bridge*|epair*|tap*|tun*|wlan*|gif*|stf*|ipfw*|vm-*) continue ;; esac
            ifconfig "$_if" 2>/dev/null | grep -q 'status: active' || continue
            ifconfig "$_if" up 2>/dev/null
            say "  DHCP em $_if..."
            tmo 30 dhclient "$_if" >>"$LOG" 2>&1
            if net_ok; then note "[CORRIGIDO] Rede configurada via DHCP em $_if"; break; fi
        done
    fi
    net_ok || return 1
    if ! dns_ok; then
        say "DNS nao responde: adicionando servidores publicos..."
        backup_file "$R/etc/resolv.conf"
        printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' >> "$R/etc/resolv.conf"
        dns_ok || return 1
        note "[CORRIGIDO] DNS ajustado (1.1.1.1 e 9.9.9.9)"
    fi
    return 0
}

fix_clock() {
    _y=$(date +%Y)
    [ "${_y:-0}" -ge 2025 ] && return 0
    say "Relogio fora de hora (ano $_y): sincronizando (certificados HTTPS dependem disso)..."
    printf 'server pool.ntp.org iburst\n' > "$WORK/ntp.conf"
    tmo 45 ntpd -g -q -c "$WORK/ntp.conf" >>"$LOG" 2>&1 \
        || tmo 45 sntp -S pool.ntp.org >>"$LOG" 2>&1
    _y=$(date +%Y)
    if [ "${_y:-0}" -ge 2025 ]; then
        note "[CORRIGIDO] Relogio sincronizado pela internet"
    else
        note "[AVISO] Relogio continua errado ($(date)); downloads HTTPS podem falhar"
    fi
}

stage0() {
    say "FreeBSD Pos-Instalacao v$VERSION"
    say "Verificando ferramentas..."
    check_tools
    say "Verificando rede..."
    fix_network || die "sem internet. Conecte o cabo (ou configure a rede: dhclient em0) e rode de novo."
    note "[OK] Internet e DNS funcionando"
    fix_clock

    if command -v bsddialog >/dev/null 2>&1; then
        DIALOG=bsddialog
    elif command -v dialog >/dev/null 2>&1; then
        DIALOG=dialog
    else
        say "Instalando o 'dialog' para montar a interface..."
        retry 3 pkg bootstrap -f >>"$LOG" 2>&1
        retry 3 pkg install -y dialog >>"$LOG" 2>&1 || die "nao consegui instalar o dialog (veja $LOG)."
        DIALOG=dialog
        note "[CORRIGIDO] Pacote 'dialog' instalado (interface de terminal)"
    fi
}
stage0

# -------------------------------------------------------- helpers de TUI ---
info() { $DIALOG --title "FreeBSD Pos-Instalacao" --infobox "$(T "$1")" 6 64; }

msg() {
    if [ "$AUTO" -eq 1 ]; then log "[$1] $2"; return 0; fi
    $DIALOG --title "$(T "$1")" --msgbox "$(T "$2")" 0 0
}
yesno() {
    [ "$AUTO" -eq 1 ] && return 0
    $DIALOG --title "$(T "$1")" --yesno "$(T "$2")" 0 0
}

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

ask_input() { $DIALOG --title "$(T "$1")" --inputbox "$(T "$2")" 0 0 3>&1 1>&2 2>&3; }
ask_pass()  { $DIALOG --title "$(T "$1")" --passwordbox "$(T "$2")" 0 0 3>&1 1>&2 2>&3; }

# Executa um comando em segundo plano (saida -> log) e mostra as ultimas
# linhas do log numa caixa de informacao enquanto ele roda.
run() { # titulo comando [args...]
    _title=$(T "$1"); shift
    rm -f "$WORK/rc"
    ( "$@" >>"$LOG" 2>&1; echo $? > "$WORK/rc" ) &
    _pid=$!
    BGPIDS="$BGPIDS $_pid"
    while kill -0 "$_pid" 2>/dev/null; do
        _tail=$(tail -n 40 "$LOG" | tr '\r' '\n' | tr -cd '[:print:]\n' \
                | tail -n 8 | cut -c1-70 | Tf)
        $DIALOG --title "$_title" --infobox "Aguarde, isso pode demorar...${NL}${NL}${_tail}" 16 76
        sleep 1
    done
    wait "$_pid" 2>/dev/null
    [ "$(cat "$WORK/rc" 2>/dev/null || echo 1)" -eq 0 ]
}

run_or_ask() { # titulo funcao
    if ! run "$1" "$2"; then
        FAILED="$FAILED${NL} - $1"
        yesno "Algo deu errado" "A etapa \"$1\" falhou.${NL}${NL}Detalhes em $LOG${NL}${NL}Continuar mesmo assim?" \
            || { clear; echo "Interrompido. Veja $LOG"; exit 1; }
    fi
}

# ------------------------------------------------ indice de pacotes --------
have_pkg() { grep -qx "$1" "$WORK/pkgs.idx" 2>/dev/null; }
pick()     { for _p; do have_pkg "$_p" && { echo "$_p"; return 0; }; done; return 1; }
pkg_installed() { pkg info -e "$1" >/dev/null 2>&1; }
is_pkgbase()    { pkg info -e FreeBSD-runtime >/dev/null 2>&1; }

add_kld() {
    for _m in "$@"; do
        case " $(sysrc -n kld_list 2>/dev/null) " in
            *" $_m "*) ;;
            *) sysrc kld_list+="$_m" >/dev/null ;;
        esac
    done
}

# ----------------------------------------------------- deteccao de GPU -----
detect_gpu() {
    GPU_IDS=$(pciconf -l 2>/dev/null | grep 'class=0x03' \
        | sed -n 's/.* vendor=0x\([0-9a-f]*\).*/\1/p')
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

nv_desc() {
    case $1 in
        nvidia-driver)     echo "RTX 2000 / GTX 1600 ou mais nova" ;;
        nvidia-driver-580) echo "GTX 750 / 900 / 1000 (Maxwell, Pascal)" ;;
        nvidia-driver-470) echo "GT 600 / 700 (Kepler)" ;;
        nvidia-driver-390) echo "GT 400 / 500 (Fermi)" ;;
    esac
}

# Escolhe o driver NVIDIA pela geracao da placa (a NVIDIA tirou o suporte a
# Maxwell/Pascal/Volta dos drivers novos; a serie 580 e a ultima para elas).
choose_nvidia() {
    _hex=$(pciconf -l 2>/dev/null | grep 'class=0x03' | grep 'vendor=0x10de' \
        | head -n 1 | sed -n 's/.* device=0x\([0-9a-f]*\).*/\1/p')
    _dec=$(printf '%d' "0x${_hex:-0}" 2>/dev/null || echo 0)
    if   [ "$_dec" -ge 7680 ]; then REC=nvidia-driver        # Turing (0x1e00) ou mais nova
    elif [ "$_dec" -ge 4928 ]; then REC=nvidia-driver-580    # Maxwell/Pascal/Volta (0x1340-0x1dff)
    else REC=nvidia-driver-470                               # Kepler/Fermi
    fi
    if [ -n "$OPT_NV" ]; then
        NV_PKG=$OPT_NV
    elif [ "$AUTO" -eq 1 ]; then
        NV_PKG=$REC
    else
        _txt="Placa NVIDIA detectada: ${GPU_NAME:-desconhecida} (ID 0x${_hex})${NL}${NL}O driver mais novo NAO funciona em placas antigas.${NL}Recomendado para a sua: $REC${NL}${NL}Escolha o driver:"
        set -- "$REC" "$(nv_desc $REC) [recomendado]"
        for _p in nvidia-driver nvidia-driver-580 nvidia-driver-470 nvidia-driver-390; do
            [ "$_p" = "$REC" ] || set -- "$@" "$_p" "$(nv_desc $_p)"
        done
        NV_PKG=$(ask_menu "Driver NVIDIA" "$_txt" "$@") || NV_PKG=$REC
    fi
    GPU_LABEL="NVIDIA -> $NV_PKG"
}

# ------------------------------------------------------- usuario ----------
create_user() { # [nome pre-definido]
    _name=$1
    while :; do
        if [ -z "$_name" ]; then
            [ "$AUTO" -eq 1 ] && die "modo automatico: informe --user NOME."
            _name=$(ask_input "Novo usuario" "Nome do usuario (so letras minusculas, numeros, _ e -):") || return 1
        fi
        case $_name in
            ''|*[!a-z0-9_-]*|[0-9-]*) msg "Nome invalido" "Use so letras minusculas, numeros, _ e -, comecando por letra."; _name=""; continue ;;
        esac
        [ ${#_name} -le 32 ] || { msg "Nome muito longo" "Use no maximo 32 caracteres."; _name=""; continue; }
        id "$_name" >/dev/null 2>&1 && { msg "Ja existe" "O usuario $_name ja existe."; _name=""; continue; }
        break
    done
    while :; do
        _p1=$(ask_pass "Senha" "Senha para $_name (minimo 8 caracteres):") || return 1
        _p2=$(ask_pass "Senha" "Repita a senha:") || return 1
        [ ${#_p1} -ge 8 ] || { msg "Senha curta" "Use pelo menos 8 caracteres."; continue; }
        [ "$_p1" = "$_p2" ] || { msg "Senhas diferentes" "As senhas nao conferem. Tente de novo."; continue; }
        break
    done
    printf '%s\n' "$_p1" | pw useradd "$_name" -m -s /bin/sh -c "$_name" -G wheel,video -h 0 \
        || { _p1=""; _p2=""; msg "Erro" "Nao consegui criar o usuario."; return 1; }
    _p1=""; _p2=""
    TARGET_USER=$_name
    note "[OK] Usuario $_name criado"
}

pick_user() {
    TARGET_USER=""
    if [ -n "$OPT_USER" ]; then
        if id "$OPT_USER" >/dev/null 2>&1; then TARGET_USER=$OPT_USER; return 0; fi
        create_user "$OPT_USER"; return $?
    fi
    _users=$(awk -F: '$3>=1001 && $3<65534 && $7 !~ /nologin|false/ {print $1}' "$R/etc/passwd" 2>/dev/null)
    _count=$(printf '%s\n' "$_users" | grep -c .)
    case $_count in
        0) while [ -z "$TARGET_USER" ]; do create_user "" || { [ "$AUTO" -eq 1 ] && return 1; }; done ;;
        1) TARGET_USER=$_users ;;
        *)
            if [ "$AUTO" -eq 1 ]; then
                TARGET_USER=$(printf '%s\n' "$_users" | head -n 1)
            else
                while [ -z "$TARGET_USER" ]; do
                    set --
                    for _u in $_users; do set -- "$@" "$_u" "usuario existente"; done
                    set -- "$@" "__novo__" "Criar um novo usuario"
                    _choice=$(ask_menu "Usuario" "Qual usuario deve virar administrador (sudo)?" "$@") \
                        || { clear; echo "Cancelado."; exit 0; }
                    if [ "$_choice" = "__novo__" ]; then create_user "" || true; else TARGET_USER=$_choice; fi
                done
            fi
            ;;
    esac
    [ -n "$TARGET_USER" ]
}

# ------------------------------------------ catalogo de pacotes / DE -------
start_background() {
    # Baixa o catalogo do pkg e (se aplicavel) os patches do base EM PARALELO,
    # enquanto voce responde as perguntas.
    ( retry 3 pkg update -f; echo $? > "$WORK/pkgupd.rc" ) >>"$LOG" 2>&1 &
    PKGUPD_PID=$!
    BGPIDS="$BGPIDS $PKGUPD_PID"
    case "$(freebsd-version 2>/dev/null)" in
        *-RELEASE*)
            if command -v freebsd-update >/dev/null 2>&1 && ! is_pkgbase; then
                ( freebsd-update --not-running-from-cron fetch; echo $? > "$WORK/fbu.rc" ) >>"$LOG" 2>&1 &
                FBU_PID=$!
                BGPIDS="$BGPIDS $FBU_PID"
            fi
            ;;
    esac
}

wait_catalog() {
    [ -n "$PKGUPD_PID" ] || return 0
    kill -0 "$PKGUPD_PID" 2>/dev/null && info "Baixando a lista de pacotes..."
    wait "$PKGUPD_PID" 2>/dev/null
    PKGUPD_PID=""
    _rc=$(cat "$WORK/pkgupd.rc" 2>/dev/null || echo 1)
    if [ "$_rc" -ne 0 ]; then
        info "Reparando o catalogo de pacotes..."
        log "pkg update falhou; reparando"
        pkg bootstrap -f >>"$LOG" 2>&1
        rm -rf "$R/var/db/pkg/repos/"* 2>/dev/null
        retry 2 pkg update -f >>"$LOG" 2>&1 || return 1
        note "[CORRIGIDO] Catalogo de pacotes reparado"
    fi
    pkg rquery -a '%n' 2>/dev/null | sort -u > "$WORK/pkgs.idx"
    [ -s "$WORK/pkgs.idx" ]
}

de_plan() { # de -> define MAIN EXTRAS DM DMPKGS; falha se algum pacote nao existir
    MAIN=""; EXTRAS=""; DM=""; DMPKGS=""
    case $1 in
        kde)      MAIN=$(pick plasma6-plasma plasma5-plasma kde) || return 1
                  EXTRAS="konsole dolphin"; DM=sddm; DMPKGS="sddm" ;;
        gnome)    MAIN=$(pick gnome gnome-lite) || return 1
                  DM=gdm; DMPKGS="gdm" ;;
        xfce)     MAIN=$(pick xfce) || return 1
                  EXTRAS="xfce4-goodies"; DM=lightdm; DMPKGS="lightdm lightdm-gtk-greeter" ;;
        mate)     MAIN=$(pick mate) || return 1
                  DM=lightdm; DMPKGS="lightdm lightdm-gtk-greeter" ;;
        cinnamon) MAIN=$(pick cinnamon) || return 1
                  DM=lightdm; DMPKGS="lightdm lightdm-gtk-greeter" ;;
        lxqt)     MAIN=$(pick lxqt) || return 1
                  DM=sddm; DMPKGS="sddm" ;;
        none)     return 0 ;;
        *)        return 1 ;;
    esac
    for _p in $DMPKGS; do have_pkg "$_p" || return 1; done
    return 0
}

de_desc() {
    case $1 in
        kde)      echo "KDE Plasma  - moderno e personalizavel" ;;
        gnome)    echo "GNOME       - simples e elegante" ;;
        xfce)     echo "XFCE        - leve e estavel" ;;
        mate)     echo "MATE        - classico, estilo GNOME 2" ;;
        cinnamon) echo "Cinnamon    - familiar, estilo tradicional" ;;
        lxqt)     echo "LXQt        - super leve" ;;
    esac
}

choose_de() {
    if [ -n "$OPT_DE" ]; then
        de_plan "$OPT_DE" || die "o ambiente '$OPT_DE' nao esta disponivel no repositorio de pacotes."
        DE=$OPT_DE; return 0
    fi
    if [ "$AUTO" -eq 1 ]; then
        for _d in gnome xfce kde mate lxqt cinnamon; do
            if de_plan "$_d"; then DE=$_d; return 0; fi
        done
        DE=none; return 0
    fi
    set --
    for _d in kde gnome xfce mate cinnamon lxqt; do
        de_plan "$_d" || continue            # so mostra o que existe de verdade
        set -- "$@" "$_d" "$(de_desc $_d)"
    done
    set -- "$@" none "Nenhum      - so terminal"
    DE=$(ask_menu "Ambiente grafico" "Escolha a interface grafica (setas + Enter):" "$@") \
        || { clear; echo "Cancelado."; exit 0; }
    de_plan "$DE" || die "ambiente grafico invalido ou indisponivel: '$DE'"
}

# --------------------------------------------------- seguranca / extras ----
choose_options() {
    _def="firewall sysctl sendmail ntp clean"
    [ "$NO_HARDEN" -eq 1 ] && _def="sendmail ntp clean"
    _sel=$_def
    if [ "$AUTO" -ne 1 ]; then
        _sel=$($DIALOG --title "Seguranca e extras" \
            --checklist "$(T "Marque o que deseja aplicar (Espaco marca/desmarca, Enter confirma):")" 0 0 5 \
            firewall "Firewall pf: bloqueia conexoes de entrada" on \
            sysctl   "Endurecimento do kernel e da rede" on \
            sendmail "Desativar o sendmail (nao usado em desktop)" on \
            ntp      "Sincronizar o relogio pela internet (ntpd)" on \
            clean    "Limpar cache de pacotes no final (economiza disco)" on \
            3>&1 1>&2 2>&3) || _sel=$_def
        _sel=$(printf '%s' "$_sel" | tr -d '"')
    fi
    OPT_FW=0; OPT_SYSCTL=0; OPT_SENDMAIL=0; OPT_NTP=0; OPT_CLEAN=0
    case " $_sel " in *" firewall "*) OPT_FW=1 ;; esac
    case " $_sel " in *" sysctl "*)   OPT_SYSCTL=1 ;; esac
    case " $_sel " in *" sendmail "*) OPT_SENDMAIL=1 ;; esac
    case " $_sel " in *" ntp "*)      OPT_NTP=1 ;; esac
    case " $_sel " in *" clean "*)    OPT_CLEAN=1 ;; esac
}

# --------------------------------------------- plano de pacotes / recursos --
plan_packages() {
    _want="sudo"; OPTS=""; MISSING=""
    case $GPU_KIND in
        intel)  _want="$_want drm-kmod"; OPTS="$OPTS gpu-firmware-intel-kmod" ;;
        amd)    _want="$_want drm-kmod"; OPTS="$OPTS gpu-firmware-amd-kmod" ;;
        nvidia) _want="$_want $NV_PKG" ;;
        vbox)   _want="$_want virtualbox-ose-additions" ;;
        vmware) _want="$_want open-vm-tools xf86-video-vmware" ;;
    esac
    if [ "$DE" != none ]; then
        _want="$_want xorg dbus $MAIN $DMPKGS"
        OPTS="$OPTS dejavu $EXTRAS"
    fi
    PKGS=""
    for _p in $_want; do
        if have_pkg "$_p"; then PKGS="$PKGS $_p"; else MISSING="$MISSING $_p"; fi
    done
    _o=""
    for _p in $OPTS; do have_pkg "$_p" && _o="$_o $_p"; done
    OPTS=$_o
}

resource_warnings() {
    WARN=""
    case $DE in kde|gnome) _need=8500 ;; none) _need=2500 ;; *) _need=5500 ;; esac
    _free=$(free_mb "$R/usr/local"); [ -n "$_free" ] || _free=$(free_mb "$R/")
    if [ "${_free:-0}" -gt 0 ] && [ "${_free:-0}" -lt "$_need" ]; then
        WARN="$WARN${NL}! Pouco espaco em disco: ${_free} MB livres (recomendado ${_need} MB).${NL}  Considere remover coisas ou usar um ambiente mais leve."
    fi
    _ram=$(( $(sysctl -n hw.physmem 2>/dev/null || echo 0) / 1048576 ))
    case $DE in
        kde|gnome) if [ "$_ram" -gt 0 ] && [ "$_ram" -lt 1800 ]; then
            WARN="$WARN${NL}! Pouca memoria (${_ram} MB): $DE pede ao menos 2 GB. XFCE/LXQt sao mais leves."; fi ;;
    esac
    case $GPU_KIND in
        nvidia) [ "$_dec" -lt 4928 ] 2>/dev/null && \
            WARN="$WARN${NL}! Placa NVIDIA antiga: o driver legado pode ter limitacoes." ;;
    esac
    [ -n "$MISSING" ] && WARN="$WARN${NL}! Pacotes nao encontrados no repositorio (ignorados):$MISSING"
}

# ============================================================== ETAPAS =====
step_install() {
    echo ">> Atualizando os pacotes ja instalados..."
    retry 2 pkg upgrade -y -U || echo ">> (aviso) pkg upgrade nao concluiu; seguindo."
    echo ">> Instalando em uma unica transacao:$PKGS"
    # shellcheck disable=SC2086
    if retry 2 pkg install -y -U $PKGS; then
        :
    else
        echo ">> Falhou em bloco; tentando pacote por pacote..."
        _bad=""
        for _p in $PKGS; do
            retry 2 pkg install -y -U "$_p" || _bad="$_bad $_p"
        done
        if [ -n "$_bad" ]; then echo ">> NAO instalados:$_bad"; return 1; fi
    fi
    for _p in $OPTS; do
        echo ">> Extra: $_p"
        pkg install -y -U "$_p" || echo ">> (aviso) extra $_p nao instalado"
    done
    return 0
}

apply_sudo() {
    pkg_installed sudo || return 0
    mkdir -p "$R/usr/local/etc/sudoers.d"
    _sd="$R/usr/local/etc/sudoers.d/10-wheel"
    printf 'Defaults use_pty\nDefaults passwd_tries=3\n%%wheel ALL=(ALL:ALL) ALL\n' > "$_sd.new"
    if visudo -cf "$_sd.new" >>"$LOG" 2>&1; then
        chmod 440 "$_sd.new"; chown root:wheel "$_sd.new" 2>/dev/null
        mv -f "$_sd.new" "$_sd"
    else
        rm -f "$_sd.new"
        echo ">> regra do sudo invalida; nao aplicada"
        return 1
    fi
    pw groupmod wheel -m "$TARGET_USER" || return 1
    pw groupmod video -m "$TARGET_USER" 2>/dev/null
    return 0
}

apply_pf() {
    _pf="$R/etc/pf.conf"
    if [ -s "$_pf" ] && ! grep -q 'pos-install' "$_pf"; then
        note "[AVISO] /etc/pf.conf ja existe; mantido sem alteracoes"
        return 0
    fi
    cat > "$_pf.new" <<'PFEOF'
# gerado por pos-install: entrada bloqueada, saida liberada
set skip on lo0
set block-policy drop
block in all
pass out all keep state
pass in quick inet proto udp from any port 67 to any port 68
pass inet6 proto icmp6 all
pass in inet proto icmp icmp-type echoreq
PFEOF
    if command -v pfctl >/dev/null 2>&1 && ! pfctl -nf "$_pf.new" >>"$LOG" 2>&1 && [ -e "$R/dev/pf" ]; then
        rm -f "$_pf.new"
        note "[AVISO] regra do firewall invalida; firewall nao ativado"
        return 0
    fi
    mv -f "$_pf.new" "$_pf"
    sysrc pf_enable=YES pf_rules=/etc/pf.conf >/dev/null
    note "[OK] Firewall pf ativo (entrada bloqueada; para liberar SSH adicione: pass in proto tcp to port 22)"
}

apply_sysctl() {
    _sc="$R/etc/sysctl.conf"
    conf_set "$_sc" net.inet.tcp.blackhole 2
    conf_set "$_sc" net.inet.udp.blackhole 1
    conf_set "$_sc" net.inet.ip.redirect 0
    conf_set "$_sc" net.inet6.ip6.redirect 0
    conf_set "$_sc" net.inet.icmp.drop_redirect 1
    conf_set "$_sc" security.bsd.unprivileged_read_msgbuf 0
    note "[OK] Endurecimento de rede/kernel aplicado (/etc/sysctl.conf)"
}

step_configure() {
    backup_file "$R/etc/rc.conf" "$R/boot/loader.conf" "$R/etc/sysctl.conf" \
                "$R/etc/fstab" "$R/etc/pf.conf"

    apply_sudo || return 1

    case $GPU_KIND in
        intel)  pkg_installed drm-kmod && add_kld i915kms ;;
        amd)    pkg_installed drm-kmod && add_kld amdgpu ;;
        nvidia) pkg_installed "$NV_PKG" && add_kld nvidia-modeset ;;
        vbox)   pkg_installed virtualbox-ose-additions && sysrc vboxguest_enable=YES vboxservice_enable=YES ;;
        vmware) pkg_installed open-vm-tools && sysrc vmware_guestd_enable=YES \
                    vmware_guest_vmblock_enable=YES vmware_guest_vmmemctl_enable=YES ;;
    esac
    sysrc -f "$R/boot/loader.conf" snd_hda_load=YES

    if [ "$DE" != none ]; then
        sysrc dbus_enable=YES
        case $DM in
            sddm)    sysrc sddm_enable=YES ;;
            gdm)     sysrc gdm_enable=YES gnome_enable=YES ;;
            lightdm) sysrc lightdm_enable=YES ;;
        esac
        grep -q '^proc' "$R/etc/fstab" 2>/dev/null || echo 'proc /proc procfs rw 0 0' >> "$R/etc/fstab"
    fi

    [ "$OPT_FW" -eq 1 ]       && apply_pf
    [ "$OPT_SYSCTL" -eq 1 ]   && apply_sysctl
    if [ "$OPT_SENDMAIL" -eq 1 ]; then
        sysrc sendmail_enable=NONE sendmail_submit_enable=NO \
              sendmail_outbound_enable=NO sendmail_msp_queue_enable=NO >/dev/null
        note "[OK] sendmail desativado"
    fi
    if [ "$OPT_NTP" -eq 1 ]; then
        sysrc ntpd_enable=YES ntpd_sync_on_start=YES >/dev/null
        note "[OK] Relogio sincronizado na inicializacao (ntpd)"
    fi
    return 0
}

step_verify() {
    _bad=0
    # 1) grupo wheel
    if ! id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx wheel; then
        if pw groupmod wheel -m "$TARGET_USER"; then
            note "[CORRIGIDO] $TARGET_USER adicionado ao grupo wheel"
        else
            note "[ERRO] nao consegui colocar $TARGET_USER no grupo wheel"; _bad=1
        fi
    fi
    # 2) sudo
    if pkg_installed sudo; then
        if visudo -c >/dev/null 2>&1; then
            note "[OK] sudo instalado e validado para $TARGET_USER"
        else
            rm -f "$R/usr/local/etc/sudoers.d/10-wheel"
            note "[CORRIGIDO] regra do sudo invalida removida (sudoers original preservado)"
        fi
    else
        note "[ERRO] sudo nao foi instalado"; _bad=1
    fi
    # 3) rc.conf com sintaxe valida (senao restaura o backup)
    if ! sh -n "$R/etc/rc.conf" 2>/dev/null; then
        if [ -f "$BACKUP/rc.conf.$STAMP" ]; then
            cp -p "$BACKUP/rc.conf.$STAMP" "$R/etc/rc.conf"
            note "[CORRIGIDO] rc.conf estava invalido; backup restaurado"
        else
            note "[ERRO] rc.conf invalido e sem backup"; _bad=1
        fi
    fi
    # 4) modulos de kernel em kld_list precisam existir
    for _m in $(sysrc -n kld_list 2>/dev/null); do
        if [ -e "$R/boot/modules/$_m.ko" ] || [ -e "$R/boot/kernel/$_m.ko" ]; then
            note "[OK] modulo de kernel $_m presente"
        else
            sysrc kld_list-="$_m" >/dev/null
            note "[CORRIGIDO] modulo $_m nao existe para este kernel: removido do kld_list (evita erro no boot)"
        fi
    done
    # 5) ambiente grafico
    if [ "$DE" != none ]; then
        if command -v Xorg >/dev/null 2>&1; then note "[OK] Xorg instalado"; else note "[ERRO] Xorg ausente"; _bad=1; fi
        if command -v "$DM" >/dev/null 2>&1; then
            if [ "$(sysrc -n "${DM}_enable" 2>/dev/null)" != YES ]; then
                sysrc "${DM}_enable=YES" >/dev/null
                note "[CORRIGIDO] ${DM}_enable ativado"
            fi
            note "[OK] $DE instalado; tela de login: $DM"
        else
            note "[ERRO] gerenciador de login $DM ausente"; _bad=1
        fi
    fi
    [ "$_bad" -eq 0 ]
}

step_base() {
    [ -n "$FBU_PID" ] || { echo ">> Sistema base atualizado via pkg (pkgbase) ou versao nao-RELEASE; nada a fazer."; return 0; }
    echo ">> Aguardando o download dos patches do sistema base..."
    while [ ! -f "$WORK/fbu.rc" ] && kill -0 "$FBU_PID" 2>/dev/null; do sleep 2; done
    _rc=$(cat "$WORK/fbu.rc" 2>/dev/null || echo 1)
    if [ "$_rc" -ne 0 ]; then
        echo ">> freebsd-update fetch falhou (codigo $_rc); pulando patches do base."
        return 0
    fi
    echo ">> Instalando patches do sistema base..."
    freebsd-update --not-running-from-cron install 2>&1 | tee "$WORK/fbu-install.txt"
    if grep -qi 'reboot and run' "$WORK/fbu-install.txt" 2>/dev/null; then
        make_oneshot
        note "[OK] Kernel atualizado: o 2o passo do freebsd-update roda sozinho no proximo boot"
    fi
    return 0
}

# Script de uso unico: termina o freebsd-update depois do reboot e se apaga.
make_oneshot() {
    _rcd="$R/usr/local/etc/rc.d/pos_install_finish"
    mkdir -p "$R/usr/local/etc/rc.d"
    cat > "$_rcd" <<'RCEOF'
#!/bin/sh
# PROVIDE: pos_install_finish
# REQUIRE: NETWORKING LOGIN
# KEYWORD: nojail
. /etc/rc.subr
name="pos_install_finish"
rcvar="pos_install_finish_enable"
start_cmd="pos_install_finish_start"
stop_cmd=":"
pos_install_finish_start() {
    /usr/sbin/freebsd-update --not-running-from-cron install > /var/log/pos-install-finish.log 2>&1
    sysrc -x pos_install_finish_enable
    rm -f /usr/local/etc/rc.d/pos_install_finish
}
load_rc_config $name
: ${pos_install_finish_enable:=NO}
run_rc_command "$1"
RCEOF
    chmod 555 "$_rcd"
    sysrc pos_install_finish_enable=YES >/dev/null
}

step_finish() {
    if [ "$OPT_CLEAN" -eq 1 ]; then
        echo ">> Limpando o cache de pacotes..."
        pkg clean -a -y || true
    fi
    sync
    echo ">> Concluido."
}

# ================================================================ FLUXO ====
# ----------------------------------------------------------- boas-vindas ---
detect_gpu
start_background

msg "Bem-vindo ao FreeBSD Pos-Instalacao v$VERSION" \
"Este assistente vai:

  1. Atualizar o sistema
  2. Instalar o sudo e dar acesso ao seu usuario
  3. Detectar sua placa de video e instalar o driver ideal
  4. Instalar o ambiente grafico que voce escolher
  5. Aplicar seguranca basica e verificar tudo
  6. Reiniciar o computador

Use as SETAS para navegar, TAB para trocar de botao e ENTER para confirmar.

Diagnostico inicial:
$(cat "$WORK/report.txt")

Log completo em: $LOG"

# ------------------------------------------------------------ perguntas ----
pick_user || die "nao foi possivel definir o usuario administrador."

wait_catalog || die "nao consegui baixar a lista de pacotes. Veja $LOG."

[ "$GPU_KIND" = nvidia ] && choose_nvidia
choose_de
choose_options
plan_packages
resource_warnings

yesno "Confirmar" \
"Tudo pronto para comecar:

  Usuario sudo : $TARGET_USER
  Placa de video: ${GPU_NAME:-nao identificada}
  Driver        : $GPU_LABEL
  Interface     : $DE
  Firewall: $([ "$OPT_FW" -eq 1 ] && echo sim || echo nao)   Sysctl: $([ "$OPT_SYSCTL" -eq 1 ] && echo sim || echo nao)
${WARN}
O computador sera reiniciado no final.
Iniciar agora?" || { clear; echo "Cancelado."; exit 0; }

# ---------------------------------------------------------- execucao -------
run_or_ask "1/5 Atualizando e instalando pacotes" step_install
run_or_ask "2/5 Configurando o sistema"           step_configure
run_or_ask "3/5 Verificando e corrigindo"         step_verify
run_or_ask "4/5 Atualizando o sistema base"       step_base
run_or_ask "5/5 Finalizando"                      step_finish

# -------------------------------------------------------------- resumo -----
_resumo="Pronto!

  Usuario sudo : $TARGET_USER
  Driver       : $GPU_LABEL
  Interface    : $DE

Verificacao:
$(cat "$WORK/report.txt")"
[ -n "$WARN" ] && _resumo="$_resumo${NL}${WARN}"
[ -n "$FAILED" ] && _resumo="$_resumo${NL}${NL}Atencao, estas etapas falharam:$FAILED${NL}(veja $LOG)"
_resumo="$_resumo${NL}${NL}Backups dos arquivos alterados: $BACKUP"
msg "Concluido" "$_resumo"
cp -f "$WORK/report.txt" "$R/var/log/pos-install-report.txt" 2>/dev/null

# Dentro do shell do instalador (raiz montada em /mnt)? Entao nao reinicia sozinho.
_root_mnt=$(df -P "$R/" 2>/dev/null | awk 'NR==2 {print $NF}')
if [ -z "$R" ] && [ -n "$_root_mnt" ] && [ "$_root_mnt" != "/" ]; then
    msg "Quase la" "Voce esta dentro do shell do instalador.${NL}${NL}Digite  exit  e escolha  Reboot  no menu do bsdinstall para reiniciar com seguranca."
    clear
    exit 0
fi

if [ "$NO_REBOOT" -eq 1 ]; then
    clear; echo "Pronto. Reinicie quando quiser com:  shutdown -r now"; exit 0
fi

if [ "$AUTO" -eq 1 ]; then
    clear; echo "Reiniciando em 10 segundos (Ctrl+C cancela)..."
    sleep 10; sync; shutdown -r now
elif yesno "Reiniciar" "Reiniciar o computador agora?"; then
    clear; echo "Reiniciando..."; sync; shutdown -r now
else
    clear; echo "Ok. Reinicie quando quiser com:  shutdown -r now"
fi
