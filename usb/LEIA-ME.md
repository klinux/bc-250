# BC-250 — pendrive de flash da BIOS (MeiMeiDXE v3 / 8 cores)

Origem: Forbidden-Darkness/AMD-BC-250-UEFI-v2.2-Firmware-Menu-Script release v0.5.0
+ Fallback/ com stock P3.00 de TuxThePenguin0/bc250-bios + entradas f1/f2 no menu.nsh.

## Layout
```
EFI/BOOT/BOOTX64.EFI      shell UEFI (boota direto no menu)
EFI/BOOT/AfuEfix64.efi    AMI AFU (flasher)
startup.nsh -> menu.nsh   menu interativo
Firmware/                 17 ROMs P3.00 + MeiMeiDXE v3 (8 cores persistente + ACPI toggles), só muda o logo
Fallback/                 BC250_3.00.ROM (stock) e BC250_3.00_CHIPSETMENU.ROM (Segfault: cache unlock, ReBAR)
Firmware_Backup/          criado pelo menu 0f com bc250-backup.rom
```

## Ordem de execução
1. **Teste os cores ANTES** (de dentro do Linux, runtime):
   `sudo ./bc250-8core-unlock.sh apply && sudo reboot` → `./test-cores.sh 60`.
   Se um core falhar, NÃO flashe MeiMeiDXE — se a BIOS habilitar core ruim, só volta com programador CH347.
2. Só o pendrive conectado (tire NVMe/SSD). Boot por ele.
3. `menu 0f` → backup da ROM atual em `Firmware_Backup/bc250-backup.rom`. **Copie esse arquivo pra outro lugar.**
4. `menu 03` → Steam logo (escolhido). `menu 01` sem logo, `menu 02` Bazzite. Todas são a mesma BIOS (verificado: só o logo difere).
   O AFU roda com `/P /B /N /K /RLC:E /CLRCFG` — ~10-15 min, tela pode parecer travada. **NÃO desligue.**
5. Enter → `reset -c`. Desligue, **CLEAR CMOS**: bateria fora 60 s + 5x botão power (ou jumper CLRCMOS1 pinos 2-3 por 20 s).
6. Setup (Del): Chipset→GFX: IGC=Forces, UMA=UMA_SPECIFIED, Frame Buffer=512M · Advanced→CPU: IOMMU=Disabled · Boot=UEFI · F10.
7. Confira no Linux: `nproc` → 16, `lscpu | grep -i core`.

## Se der ruim
- `menu fr` restaura `Firmware_Backup/bc250-backup.rom` (só funciona se a placa ainda posta).
- `menu f1` stock P3.00 / `menu f2` P3.00 ChipsetMenu (ambas 6 cores).
- Sem POST → CH347T no header J4004 (chip BIOS_A1, W25Q128JVSQ): `flashrom -p ch347_spi -w bc250-backup.rom`. NÃO toque no SIO1_R.

## Notas
- `menu R3` (PUNSH) está quebrado no release: a ROM não existe no Firmware/. Ignore.
- Placa com P4.00 stock é instável; MeiMeiDXE é base P3.00 — flashar por cima é o esperado.
- Se a placa está em P5.00, isso é downgrade; comunidade considera OK e mais estável.
- `SHA256SUMS.txt` valida tudo: `sha256sum -c SHA256SUMS.txt`.

---
## Nota sobre este repo
As ROMs e os binários EFI **não estão versionados** (binários de terceiros, ~1 GB).
Para montar o pendrive, baixe e extraia na raiz dele:

1. `release-0.5.0.7z` de
   https://github.com/Forbidden-Darkness/AMD-BC-250-UEFI-v2.2-Firmware-Menu-Script/releases
   → fornece `EFI/BOOT/{BOOTX64.EFI,AfuEfix64.efi}`, `Firmware/` e `startup.nsh`.
2. Fallbacks stock de https://gitlab.com/TuxThePenguin0/bc250-bios/ →
   `BC250_3.00.ROM` e `BC250_3.00_CHIPSETMENU.ROM` em `Fallback/`.
3. Substitua o `menu.nsh` do release pelo deste repo (adiciona `menu f1`/`menu f2`
   para flashar os fallbacks stock, que o original não tem).
4. Valide com `sha256sum -c SHA256SUMS.txt`.
