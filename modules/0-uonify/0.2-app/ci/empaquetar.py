#!/usr/bin/env python3
"""Tarball reproducible y manifiesto de las migraciones de la base propia (paso F1.4 del plan F1).

Uso, desde cualquier carpeta del repo: python3 -I empaquetar.py <commit> <carpeta de salida>

Lee los blobs de git del commit, no el árbol de trabajo, y escribe en la carpeta de salida:
- manifiesto.sha256: «<sha256>  <fichero>», una línea por migración y en el orden de migrate()
  (por nombre). Su sha256 es la huella del conjunto, el mismo cálculo que el bloque de «Qué hay»
  del README de 0.2-app (shasum -a 256 *.sql | shasum -a 256).
- migraciones.tar.gz: migrations/<fichero>, en ese orden, en formato ustar, con modo 0644, uid y
  gid 0, sin nombres de usuario ni grupo y mtime 0; gzip de nivel 9, con mtime 0 y sin nombre de
  fichero. Mismo commit y mismo runner dan los mismos bytes: publicar lo rehace y exige el mismo
  sha256 que validar.
Imprime clave=valor, para GITHUB_OUTPUT: ficheros, ultima, huella, tar_sha256 y tarball_sha256.

Solo admite en migrations/ ficheros normales con nombre NNN_<tema>.sql, en UTF-8 y sin CR. Así el
sha256 de cada fichero es el checksum que migrate() guarda en schema_migrations: el sha256 de
read_text().encode(), y read_text() convertiría los CR.
"""
import gzip
import hashlib
import io
import os
import re
import subprocess
import sys
import tarfile
from pathlib import Path

DIR = 'modules/0-uonify/0.2-app/migrations'
NOMBRE = re.compile(r'[0-9]{3}_[a-z0-9]+(?:_[a-z0-9]+)*\.sql')


def fallo(mensaje):
    sys.exit(f'ERROR: {mensaje}')


def git(*args):
    return subprocess.run(('git', *args), check=True, stdout=subprocess.PIPE).stdout


def migraciones(commit):
    """[(nombre, bytes)] por nombre: el orden de sorted() en migrate()."""
    entradas = []
    for registro in git('ls-tree', '-r', '-z', commit, '--', DIR).split(b'\0'):
        if not registro:
            continue
        cabecera, ruta = registro.split(b'\t', 1)
        modo, tipo, objeto = cabecera.decode('ascii').split(' ')
        ruta = ruta.decode('utf-8', 'replace')
        nombre = ruta[len(DIR) + 1:] if ruta.startswith(DIR + '/') else ''
        if (modo, tipo) != ('100644', 'blob') or not NOMBRE.fullmatch(nombre):
            fallo(f'entrada no admitida en migrations/: {modo} {tipo} {ruta}')
        datos = git('cat-file', 'blob', objeto)
        try:
            texto = datos.decode('utf-8')
        except UnicodeDecodeError:
            fallo(f'{nombre}: no es UTF-8')
        if '\r' in texto:
            fallo(f'{nombre}: lleva CR')
        entradas.append((nombre, datos))
    if not entradas:
        fallo(f'{DIR} está vacía en {commit}')
    entradas.sort(key=lambda entrada: entrada[0])
    return entradas


def tarball(entradas):
    crudo = io.BytesIO()
    with tarfile.open(fileobj=crudo, mode='w', format=tarfile.USTAR_FORMAT) as tar:
        for nombre, datos in entradas:
            info = tarfile.TarInfo('migrations/' + nombre)
            info.size = len(datos)
            info.mode = 0o644
            info.mtime = 0
            info.uid = info.gid = 0
            info.uname = info.gname = ''
            info.type = tarfile.REGTYPE
            tar.addfile(info, io.BytesIO(datos))
    comprimido = io.BytesIO()
    # filename='' para que la cabecera gzip no lleve nombre; mtime=0 para que no lleve la hora.
    with gzip.GzipFile(filename='', mode='wb', fileobj=comprimido, compresslevel=9, mtime=0) as gz:
        gz.write(crudo.getvalue())
    return crudo.getvalue(), comprimido.getvalue()


def main():
    if len(sys.argv) != 3:
        print('uso: empaquetar.py <commit> <carpeta de salida>', file=sys.stderr)
        return 2
    commit, salida = sys.argv[1], Path(sys.argv[2]).resolve()
    os.chdir(git('rev-parse', '--show-toplevel').decode('utf-8').strip())
    entradas = migraciones(commit)
    manifiesto = ''.join(f'{hashlib.sha256(datos).hexdigest()}  {nombre}\n' for nombre, datos in entradas)
    manifiesto = manifiesto.encode('ascii')
    crudo, comprimido = tarball(entradas)
    salida.mkdir(parents=True, exist_ok=True)
    (salida / 'manifiesto.sha256').write_bytes(manifiesto)
    (salida / 'migraciones.tar.gz').write_bytes(comprimido)
    print(f'ficheros={len(entradas)}')
    print(f'ultima={entradas[-1][0]}')
    print(f'huella={hashlib.sha256(manifiesto).hexdigest()}')
    print(f'tar_sha256={hashlib.sha256(crudo).hexdigest()}')
    print(f'tarball_sha256={hashlib.sha256(comprimido).hexdigest()}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
