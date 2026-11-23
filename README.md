# 😈 FreeBSD Pós-Instalação

Assistente de **pós-instalação para FreeBSD** com interface de terminal (TUI) navegável por setas. Logo depois de instalar o sistema, ele atualiza tudo, configura o `sudo`, instala o driver de vídeo certo, deixa você escolher o ambiente gráfico e reinicia o PC pronto para usar.

Escrito em `sh` puro, sem dependências além do que já vem no FreeBSD.

## ✨ O que ele faz

1. **Diagnostica e corrige sozinho** o que der: sem rede (roda DHCP), DNS quebrado, relógio errado (quebra o HTTPS), catálogo do `pkg` corrompido, ferramentas e pacotes ausentes.
2. **Rápido**: baixa a lista de pacotes e os patches do sistema **em paralelo** enquanto você responde às perguntas, e instala tudo em **uma única transação** do `pkg`.
3. **Escolha do usuário** (existente ou novo, senha de no mínimo 8 caracteres) e do **ambiente gráfico**. Só aparecem opções que existem no repositório.
4. **Atualiza o sistema**: `pkg upgrade` e `freebsd-update` (pulado em pkgbase). Se o kernel for atualizado, o 2º passo roda sozinho no próximo boot.
5. **Instala o `sudo`**, valida a regra com `visudo` e coloca seu usuário no grupo `wheel`.
6. **Detecta a placa de vídeo** e instala o driver certo para a geração dela (NVIDIA antiga inclusa).
7. **Segurança**: firewall `pf` (bloqueia entrada), endurecimento de rede/kernel via `sysctl`, `sendmail` desativado, `ntpd`.
8. **Verifica tudo no final** e corrige o que achar errado (grupo `wheel`, `rc.conf` inválido, módulo de kernel inexistente) e mostra um relatório.
9. **Backup** dos arquivos alterados e **reinício**.

## 🖥️ Ambientes gráficos disponíveis

| Opção | Gerenciador de login |
|-------|----------------------|
| KDE Plasma | sddm |
| GNOME | gdm |
| XFCE | lightdm |
| MATE | lightdm |
| Cinnamon | lightdm |
| LXQt | sddm |
| Nenhum (só terminal) | — |

## 🎮 Drivers de vídeo detectados

| Hardware | O que é instalado |
|----------|-------------------|
| Intel | `drm-kmod` + `i915kms` |
| AMD / Radeon | `drm-kmod` + `amdgpu` |
| NVIDIA RTX 2000 / GTX 1600 ou mais nova | `nvidia-driver` |
| NVIDIA GTX 750 / 900 / 1000 (Maxwell, Pascal) | `nvidia-driver-580` |
| NVIDIA GT 600 / 700 (Kepler) | `nvidia-driver-470` |
| NVIDIA GT 400 / 500 (Fermi) | `nvidia-driver-390` (escolha manual) |
| VirtualBox | `virtualbox-ose-additions` |
| VMware | `open-vm-tools` + `xf86-video-vmware` |
| Outros | driver genérico (modesetting/scfb) |

> Em notebooks com placa **híbrida** (Intel/AMD + NVIDIA), o script usa a Intel/AMD.
> A NVIDIA parou de suportar Maxwell e Pascal nos drivers novos, por isso o script escolhe o driver pela geração da placa e deixa você trocar no menu.

## 📋 Requisitos

- FreeBSD 14 ou mais novo (usa o `bsddialog`, que já vem no sistema base; se não existir, instala o `dialog`)
- Acesso **root**
- **Internet** funcionando (cabo/DHCP; o script não configura Wi-Fi)

## 🚀 Como usar

### Opção 1: logo após o `bsdinstall` (modo live, antes de reiniciar)

Quando a instalação terminar, antes de reiniciar:

```sh
# Copie o script para o sistema recém-instalado
cp pos-install.sh /mnt/root/
```

No menu final do instalador, escolha **"Open a shell in the newly installed system"** e rode:

```sh
sh /root/pos-install.sh
```

Ao terminar, digite `exit` e escolha **Reboot** no menu do instalador (o script detecta que está no shell do instalador e **não** reinicia sozinho, para o disco ser desmontado com segurança).

### Opção 2: com o sistema já instalado

Entre como root e rode:

```sh
fetch https://raw.githubusercontent.com/telaplena/BSD-INSTALL/main/pos-install.sh
sh pos-install.sh
```

Nesse caso, ao final ele pergunta se você quer reiniciar agora.

## 🤖 Modo automático

Sem nenhuma pergunta (útil para instalar várias máquinas):

```sh
sh pos-install.sh --auto --user meuusuario --de xfce
```

| Opção | O que faz |
|-------|-----------|
| `-y`, `--auto` | modo automático, sem perguntas |
| `--user NOME` | usuário administrador (criado se não existir) |
| `--de NOME` | `kde`, `gnome`, `xfce`, `mate`, `cinnamon`, `lxqt` ou `none` |
| `--nvidia PKG` | força um driver NVIDIA específico |
| `--no-harden` | não aplica firewall nem endurecimento do sysctl |
| `--no-reboot` | não reinicia no final |

## 🔒 Segurança

- O firewall `pf` bloqueia toda conexão de entrada. **Para usar SSH**, adicione `pass in proto tcp to port 22` em `/etc/pf.conf`.
- Uma regra do `pf.conf` que já exista **não é sobrescrita**.
- Antes de mexer, o script guarda backup de `rc.conf`, `loader.conf`, `sysctl.conf`, `fstab` e `pf.conf` em `/var/backups/pos-install/`.
- Trava contra duas execuções ao mesmo tempo, arquivos temporários privados e log com permissão restrita.

## 📝 Logs

Tudo o que o script faz é registrado em:

```
/var/log/pos-install.log
```

Se alguma etapa falhar, ele avisa e pergunta se você quer continuar.

## ⚠️ Observações

- Se o kernel for atualizado pelo `freebsd-update`, depois do reboot rode `freebsd-update install` novamente.
- Pacotes de interface gráfica são grandes; a instalação pode demorar dependendo da internet.
- Teste primeiro em uma **máquina virtual** antes de usar no seu PC.
- Wi-Fi, microcódigo da CPU e aplicativos extras (ex.: Firefox) não são configurados pelo script.

## 🤝 Contribuindo

Sugestões e pull requests são bem-vindos! Ideias de melhoria:

- Configuração de Wi-Fi
- Microcódigo da CPU (Intel/AMD)
- Lista de aplicativos extras para instalar
- Suporte a pkgbase (FreeBSD 15+)

## 📄 Licença

Distribuído sob a licença **BSD 2-Clause** (ou escolha a de sua preferência).
