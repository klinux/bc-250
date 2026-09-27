# WiFi + BT no BC-250 — AIC8800D80 (resolvido 26/set/2026)

Host: <IP-DA-PLACA> (Bazzite Deck 44.20260921, kernel 7.2.4-ogc3.1.fc44).

## Diagnóstico
O dongle é um clone "Pandora" de chip **AICSemi AIC8800D80** (WiFi 6 + BT) que
nasce em **ZeroCD / fake mass-storage**: enumera como `1111:1111` classe 08 com
driver `usb-storage`, montando uma partição de 1,9 MB `WIFI driver` com
`Wifi6_install_bt.exe`. Esse VID:PID é placeholder — nenhum driver do kernel casa.
Era exatamente o "ponto de montagem com driver pra Windows".

Dois problemas somados:
1. Precisa **mode-switch** (CDBs SCSI F3 + F2) → vira `a69c:8d80` / `a69c:8d81`.
2. Driver é **out-of-tree** (não está no mainline); nem Bazzite nem os COPR
   ublue têm akmod pronto.

## Solução aplicada (nada de rpm-ostree, nada em /usr, sem layering)
Fonte: https://github.com/shenmintao/aic8800d80 — o autor comprou uma BC-250 pelo
mesmo motivo e mantém até um `bazzite/aic8800d80.spec`. Compila limpo no 7.2.4.

| Arquivo | Papel |
|---|---|
| `/etc/usb_modeswitch.d/1111:1111` | CDBs F3/F2, alvo `a69c:8d80` |
| `/etc/udev/rules.d/99-aic8800.rules` | dispara o mode-switch no plug/boot |
| `/var/lib/aic8800/<kver>/*.ko` | os 3 módulos, versionados por kernel |
| `/var/lib/firmware/aic8800D80/` | firmware |
| `/usr/local/bin/aic8800-load` | insmod com `aic_fw_path=` |
| `/usr/local/bin/aic8800-rebuild` | recompila após update de kernel |
| `/etc/systemd/system/aic8800.service` | carga no boot (enabled) |
| `/etc/NetworkManager/conf.d/99-wifi-powersave.conf` | `wifi.powersave = 2` (global, todas as redes) |
| `/etc/udev/rules.d/99-aic8800-power.rules` | USB autosuspend off (`add|bind`) |

### Duas pegadinhas que custaram tempo
- O driver abre o firmware com `filp_open` em caminho **hardcoded**
  `/lib/firmware/aic8800D80/…`, não usa `request_firmware` — então
  `firmware_class.path` **não** resolve, e em ostree `/usr/lib/firmware` é RO.
  O módulo aceita `aic_fw_path=`, mas esse parâmetro substitui o caminho
  **inteiro**, sem acrescentar o subdiretório do chip. Valor correto:
  `aic_fw_path=/var/lib/firmware/aic8800D80`.
- `insmod` de `.ko` em `/var/lib` falha com **Permission denied** quando
  disparado pelo systemd (funciona na mão): é SELinux. Os `.ko` nascem
  `var_lib_t` e precisam de `modules_object_t`:
  ```bash
  sudo semanage fcontext -a -t modules_object_t "/var/lib/aic8800(/.*)?"
  sudo restorecon -R /var/lib/aic8800
  ```

## 5 GHz: o AP em transição WPA2/WPA3
O driver não fecha handshake **SAE**, então o NetworkManager negociava WPA3 e
falhava — só o SSID 2.4 GHz (WPA2 puro) conectava. Perfil que funciona:
```bash
nmcli connection add type wifi con-name MINHA_REDE_5G ifname wlan0 ssid MINHA_REDE_5G \
  wifi.band a wifi-sec.key-mgmt wpa-psk wifi-sec.psk "<psk>" \
  connection.autoconnect yes connection.autoconnect-priority 20
nmcli connection modify MINHA_REDE connection.autoconnect-priority 10   # fallback 2.4
```
`key-mgmt wpa-psk` é o que força WPA2 e evita o SAE.

## Power save / autosuspend
Os dois precisam de mecanismos diferentes, e o autosuspend precisa de redundância:
a regra udev perde a corrida porque o driver reescreve `power/control` no bind e o
dongle re-enumera de `8d80` para `8d81` quando o `aic_load_fw` inicializa o chip.
Por isso `ACTION=="add|bind"` **e** um laço no fim do `aic8800-load`.
Confirmar: `cat /sys/bus/usb/devices/6-1/power/control` = `on`, `iw dev wlan0 get power_save` = `off`.

> Nota: isso estabiliza latência de idle, mas **não** era a causa da lentidão
> reportada — aquilo era download da Steam saturando o link (bufferbloat).
> Medido: 135-201 Mbit/s de RX reais, `ping` com `min 7 ms` / `avg 124 ms`.
> Teto do hardware: USB 2.0 + 1x1 (`HE-NSS 1`) = ~250 Mbit efetivos.

## Estado validado após reboot
- dongle sobe já como `a69c:8d81` (udev faz o switch sozinho)
- `wlan0` + `p2p-dev-wlan0`; `nmcli radio wifi` = enabled
- scan em 2.4 e 5 GHz, HE/WiFi 6, 1170 Mbit/s, txpwr 20 dBm
- **Bluetooth funciona também**: `hci0`, controller `<MAC-BT>`, via
  `btusb` padrão do kernel depois que o `aic_load_fw` inicializa o chip
- a mídia falsa não monta mais
- power save `off` e autosuspend `on` persistem (revalidado em 2 reboots)

## Após cada `rpm-ostree upgrade` (kernel novo)
```bash
aic8800-rebuild     # compila e reinicia o serviço
```
Se o kernel novo não tiver headers em `/usr/src/kernels/$(uname -r)`, o script
avisa. O `.ko` do kernel antigo continua guardado (diretório por versão), então
um `rpm-ostree rollback` volta a funcionar sozinho.

## Reverter tudo
```bash
sudo systemctl disable --now aic8800.service
sudo rm -rf /var/lib/aic8800 /var/lib/firmware/aic8800D80 /var/lib/firmware/aic8800 \
  /etc/systemd/system/aic8800.service /usr/local/bin/aic8800-{load,rebuild} \
  /etc/udev/rules.d/99-aic8800.rules /etc/usb_modeswitch.d/1111:1111
sudo semanage fcontext -d "/var/lib/aic8800(/.*)?"
```
