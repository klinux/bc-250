# Arquivos de configuração — o que vai onde

Tudo aqui é o que está **rodando de verdade** numa BC-250 com Bazzite Deck 44
(kernel 7.2.x), 8 cores, 40 CU, GTT 12 GiB. A árvore espelha o destino: o que
está em `files/etc/...` vai para `/etc/...`.

Leia os documentos antes de copiar às cegas — vários desses arquivos existem por
causa de uma pegadinha específica, explicada em:
[README](../README.md) · [WIFI-AIC8800](../WIFI-AIC8800.md) ·
[LLM](../LLM.md) · [GPU-TELEMETRIA-GOVERNOR](../GPU-TELEMETRIA-GOVERNOR.md) ·
[CU-UNLOCK-40](../CU-UNLOCK-40.md)

## Ajuste obrigatório antes de instalar

| Arquivo | O que mudar |
|---|---|
| `etc/llama-server.env` | `MODELS_DIR` e `MODEL` |
| `usr/local/bin/aic8800-rebuild` | `SRC` (onde clonou o driver) ou exporte `AIC_SRC` |
| `etc/NetworkManager/conf.d/…` | nada, é global |

## WiFi + Bluetooth (AIC8800D80)

Pré-requisito: clonar e compilar o driver (ver [WIFI-AIC8800](../WIFI-AIC8800.md)),
com os `.ko` em `/var/lib/aic8800/$(uname -r)/` e o firmware em
`/var/lib/firmware/aic8800D80/`.

```bash
sudo install -m755 usr/local/bin/aic8800-load usr/local/bin/aic8800-rebuild /usr/local/bin/
sudo install -m644 etc/systemd/system/aic8800.service /etc/systemd/system/
sudo install -m644 etc/udev/rules.d/99-aic8800.rules etc/udev/rules.d/99-aic8800-power.rules /etc/udev/rules.d/
sudo install -m644 etc/NetworkManager/conf.d/99-wifi-powersave.conf /etc/NetworkManager/conf.d/
# o nome do arquivo PRECISA ter dois-pontos; no git ele vive como 1111_1111
sudo install -m644 etc/usb_modeswitch.d/1111_1111 "/etc/usb_modeswitch.d/1111:1111"

sudo restorecon -R /usr/local/bin /etc/udev/rules.d /etc/NetworkManager/conf.d
sudo udevadm control --reload-rules
sudo systemctl daemon-reload && sudo systemctl enable --now aic8800.service
sudo systemctl reload NetworkManager
```

**SELinux**: os `.ko` em `/var` precisam de contexto `modules_object_t`, senão o
`insmod` disparado pelo systemd falha com *Permission denied* (funciona na mão):
```bash
sudo semanage fcontext -a -t modules_object_t "/var/lib/aic8800(/.*)?"
sudo restorecon -R /var/lib/aic8800
```

## Servidor LLM

```bash
sudo install -m644 etc/llama-server.env /etc/llama-server.env    # EDITE primeiro
sudo install -m644 etc/systemd/system/llama-server.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now llama-server
```

Pré-requisito de memória — **sem isso o GTT fica em metade da RAM (7,4 GiB)** e
nada acima disso carrega. `/etc/modprobe.d` **não** resolve (o `ttm` sobe pelo
initramfs); em ostree o caminho é kernel cmdline:

```bash
sudo rpm-ostree kargs \
  --append-if-missing=ttm.pages_limit=4194304 \
  --append-if-missing=ttm.page_pool_size=4194304 \
  --append-if-missing=amdgpu.gttsize=13824   # 13.5 GiB p/ Coder-30B + CTX 16k (deixa RAM no limite; ver LLM.md)
sudo systemctl reboot
```

## Guard de jogo (libera a RAM quando um jogo sobe)

```bash
sudo install -m755 usr/local/bin/llm-gameguard usr/local/bin/llm-off usr/local/bin/llm-on /usr/local/bin/
sudo install -m644 etc/systemd/system/llm-gameguard.service /etc/systemd/system/
sudo restorecon /usr/local/bin/llm-* /etc/systemd/system/llm-gameguard.service
sudo systemctl daemon-reload && sudo systemctl enable --now llm-gameguard
```

## Swap em disco (rede contra o OOM killer)

```bash
sudo mkdir -p /var/swap && sudo chmod 700 /var/swap
sudo btrfs filesystem mkswapfile --size 12g --uuid clear /var/swap/swapfile
sudo chmod 600 /var/swap/swapfile
sudo swapon --priority 10 /var/swap/swapfile
echo '/var/swap/swapfile none swap sw,pri=10 0 0' | sudo tee -a /etc/fstab
```
Prioridade 10 (abaixo do zram, 100) é deliberada: o NVMe fica fora do caminho
quente e só entra em emergência.

## Não instale

Um arquivo que aparece nos guias antigos e **não funciona**:
`/etc/modprobe.d/ttm-gpu-memory.conf`. O parâmetro é ignorado porque o `ttm` é
carregado pelo initramfs antes de `/etc` ser lido — use os kargs acima.

## Verificação rápida

```bash
nproc                                                   # 16
sudo /caminho/cu.sh status | grep "CUs active"          # 40/40
systemctl is-active cyan-skillfish-governor-smu         # active
journalctl -u cyan-skillfish-governor-smu -b | grep -i WARN   # deve ser VAZIO
cat /sys/class/drm/card*/device/mem_info_gtt_total      # /2^30 = 12.00
iw dev wlan0 get power_save                             # off
cat /sys/bus/usb/devices/*/power/control | sort -u      # on (no dongle)
curl -s localhost:8080/health                           # {"status":"ok"}
swapon --show                                           # zram pri 100 + file pri 10
```


## Continue (painel nativo no VSCode)
A versao 2.0.0 (build linux-x64) le **`~/.continue/config.json`** no formato com
`title` (nao o `config.yaml` com `name`, que e de outra versao). Se o Continue
disser "nenhum modelo configurado", e quase sempre formato errado. Arquivo que
funciona em [continue/config.json](continue/config.json) -- copie para
`~/.continue/config.json` e recarregue a janela (Developer: Reload Window).
Autocomplete fica desligado de proposito: um modelo de chat de 30B faz
fill-in-the-middle mal.
