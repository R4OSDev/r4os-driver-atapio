# ATAPIO.R4D

`ATAPIO.R4D` is an independent R4OS driver implemented in Zig.

## Package

- Version: `0.1.4`
- Image target: `/R4OS/DRIVERS/ATAPIO.R4D`
- Image scope: `slim`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

## Build

On Windows:

    Build.bat

On Linux or macOS:

    ./Build.sh

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.

Busy status is checked before ERR/DF/DRQ; reads and IDENTIFY also validate
the final completion. Initial status 00h or FFh rejects an absent device
without entering the bounded command wait or attempting a fallback sector read.


0.81.28 - Gebuendelte PIO-Requests
--------------------------------
A2-0016 umgesetzt: ATAPIO 0.1.4, RELEASE_VERSION 0.81.28. LBA28-Backendrequest 1..128 Sektoren, ein READ/WRITE SECTORS-Kommando je zusammenhängendem Request mit einem DRQ-Payloadschritt je Sektor. Prüfung freier Taskfile vor neuem Kommando, 400-ns-Abstände nach Kommando/Daten, BSY zuerst und abschließendes DRQ=0. Nicht vorhandener Bus und ERR/DF/Timeout ergeben Fehler. Ein Flush je erfolgreichem Schreibrequest plus expliziter Flush unverändert; keine LBA48-/AHCI-/NVMe-Änderung. Die vorherige Implementierung hatte bereits einen Flush pro maximal 8-Sektorrequest (keinen Flush in writeOne); bei 64 KB sinken dadurch 128 Einzelkommandos und 16 Requestflushes auf 1 Kommando und 1 Requestflush.

Nachweis: aktueller Transfer-/Statuscode als Hostfixture, 2 gruppierte Fälle PASS (1/8/128 Sektoren, Datenvergleich, LBA28-Ende/Grenzüberschreitung, Geräteende, Buffer, Null/Übergröße, BSY/DRQ-Timeout, stale ERR/DF während Busy, Teilfehler nach einem Sektor, DF, nicht endender DRQ, Flushfehler, explizites Flush). Tatsächliche Zig-Funktionskörper zusätzlich über C-Portcallbacks gegen QEMU pc/IDE qtest mit 4 konfigurierten vCPUs geprüft; CPUs angehalten, kein Gastbetriebssystemtest. 512/4096/65536 Byte schreiben, Rohdatei nach Flush vergleichen, lesen und vergleichen: je 1 WRITE + 1 FLUSH, 1 READ, anschließend 1 expliziter FLUSH, alle Bytes gleich. Letzter Gerätesektor und abgewiesener Überlauf geprüft. Produktbuild/R4M0-Inspektion PASS. Kein Hardwaretest, keine Aussage zur Laptop-Anbindung/FPS. Evidenz Temp/Astra2/Implementation/atapio-28-qtest.json, *-28*.log und validation-28.json. Astra2.json unverändert.

Protokollabgleich: https://raw.githubusercontent.com/qemu/qemu/master/hw/ide/core.c
(READ/WRITE SECTORS, Count und FLUSH CACHE).
