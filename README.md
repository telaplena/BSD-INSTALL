# 😈 FreeBSD Pós-Instalação

Assistente de **pós-instalação para FreeBSD** com interface de terminal (TUI) navegável por setas. Logo depois de instalar o sistema, ele atualiza tudo, configura o `sudo`, instala o driver de vídeo certo, deixa você escolher o ambiente gráfico e reinicia o PC pronto para usar.

Escrito em `sh` puro, sem dependências além do que já vem no FreeBSD.

## ✨ O que ele faz

1. **Boas-vindas** e checagem de internet.
2. **Escolha do usuário**: seleciona um existente ou cria um novo (com senha).
3. **Escolha do ambiente gráfico** (setas + Enter).
4. **Atualiza o sistema**: `pkg upgrade` e `freebsd-update` (apenas em versões RELEASE).
5. **Instala o `sudo`** e coloca seu usuário no grupo `wheel` automaticamente.
6. **Detecta a placa de vídeo** e instala o melhor driver.
7. **Instala o ambiente gráfico** escolhido e o gerenciador de login.
8. **Configura o `rc.conf`/`loader.conf`** e **reinicia**.

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
| NVIDIA | `nvidia-driver` + `nvidia-modeset` |
| VirtualBox | `virtualbox-ose-additions` |
| VMware | `open-vm-tools` + `xf86-video-vmware` |
| Outros | driver genérico (modesetting/scfb) |

> Em notebooks com placa **híbrida** (Intel/AMD + NVIDIA), o script usa a Intel/AMD.
> Placas NVIDIA antigas podem precisar de `nvidia-driver-470` ou `nvidia-driver-390`.

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

Distribuído sob a licença **BSD 2-Clause** 
