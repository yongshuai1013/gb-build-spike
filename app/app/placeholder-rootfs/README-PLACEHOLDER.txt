This is the placeholder rootfs skeleton bundled with the host app.
It contains a fake /init shell script that prints and heartbeats so
the host shell chain (extract, launch, log tail, export) can be
validated before the real GB rootfs artifact lands.
