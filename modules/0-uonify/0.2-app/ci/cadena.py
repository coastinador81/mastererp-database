#!/usr/bin/env python3
"""Cadena 001→N dos veces con la réplica literal de migrate() (paso F1.4 del plan F1).

Uso: python -I cadena.py <carpeta del paquete> <réplica> <sha256 fijado de la réplica> <socket>

Es la prueba del punto 4 de «Cambiar o añadir una migración» del README de 0.2-app, con las
migraciones del tarball que se va a publicar (salida de empaquetar.py), no las del árbol de trabajo:
1. La réplica (ci/database.py) tiene que tener el sha256 fijado: el de app/database.py de platform.
2. Monta una carpeta con app/database.py (la réplica, tal cual) y migrations/ (el tarball,
   comprobado fichero a fichero contra el manifiesto).
3. Dos pasadas, cada una en un proceso nuevo, como cada arranque de la API, desde esa carpeta:
   from app.database import Database; Database(config).migrate(). migrate() las aplica todas en
   una sola transacción; por eso no vale psql, que va fichero a fichero.
4. Tras la 1.ª, schema_migrations tiene que ser exactamente el manifiesto (nombres y sha256); tras
   la 2.ª, no puede haber cambiado nada.
La base tiene que estar vacía al empezar: el PostgreSQL 17 desechable del job, por su socket.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path

import psycopg

NOMBRE = r'[0-9]{3}_[a-z0-9]+(?:_[a-z0-9]+)*\.sql'
MIEMBRO = re.compile(rf'migrations/({NOMBRE})')
LINEA = re.compile(rf'([0-9a-f]{{64}})  ({NOMBRE})')
PASADA = ('import json, sys\n'
          'from app.database import Database\n'
          'Database(json.loads(sys.argv[1])).migrate()\n')


def fallo(mensaje):
    sys.exit(f'FALLO: {mensaje}')


def sha256(datos):
    return hashlib.sha256(datos).hexdigest()


def leer_manifiesto(ruta):
    filas = []
    for texto in ruta.read_text(encoding='ascii').splitlines():
        coincide = LINEA.fullmatch(texto)
        if not coincide:
            fallo(f'línea de manifiesto no válida: {texto!r}')
        filas.append((coincide.group(2), coincide.group(1)))
    nombres = [nombre for nombre, _ in filas]
    if not filas or nombres != sorted(set(nombres)):
        fallo('el manifiesto está vacío, desordenado o repite nombres')
    return filas


def montar(paquete, replica, manifiesto):
    trabajo = Path(tempfile.mkdtemp(prefix='cadena-'))
    (trabajo / 'app').mkdir()
    (trabajo / 'app' / '__init__.py').write_bytes(b'')
    (trabajo / 'app' / 'database.py').write_bytes(replica)
    destino = trabajo / 'migrations'
    destino.mkdir()
    esperado = dict(manifiesto)
    vistos = []
    with tarfile.open(paquete / 'migraciones.tar.gz', mode='r:gz') as tar:
        for miembro in tar:
            coincide = MIEMBRO.fullmatch(miembro.name)
            if not miembro.isreg() or not coincide:
                fallo(f'miembro no admitido en el tarball: {miembro.name!r}')
            nombre = coincide.group(1)
            datos = tar.extractfile(miembro).read()
            if esperado.get(nombre) != sha256(datos):
                fallo(f'{nombre}: el tarball no coincide con el manifiesto')
            (destino / nombre).write_bytes(datos)
            vistos.append(nombre)
    if vistos != [nombre for nombre, _ in manifiesto]:
        fallo('el tarball y el manifiesto no tienen los mismos ficheros en el mismo orden')
    return trabajo


def tabla(config):
    """Filas (nombre, checksum) de schema_migrations, por nombre; None si la tabla no existe."""
    with psycopg.connect(**config, connect_timeout=5) as conexion:
        if conexion.execute("SELECT to_regclass('public.schema_migrations')").fetchone()[0] is None:
            return None
        return sorted(tuple(fila) for fila in conexion.execute('SELECT name, checksum FROM schema_migrations'))


def pasada(trabajo, config):
    entorno = {clave: valor for clave, valor in os.environ.items() if not clave.startswith('PYTHON')}
    entorno.update(PYTHONUTF8='1', PYTHONDONTWRITEBYTECODE='1')
    inicio = time.monotonic()
    subprocess.run((sys.executable, '-c', PASADA, json.dumps(config)), cwd=trabajo, env=entorno, check=True)
    return time.monotonic() - inicio


def diferencias(filas, esperado):
    real, debido = dict(filas or []), dict(esperado)
    faltan = sorted(set(debido) - set(real))
    sobran = sorted(set(real) - set(debido))
    distintas = sorted(nombre for nombre in set(real) & set(debido) if real[nombre] != debido[nombre])
    return f'faltan {faltan[:5]}, sobran {sobran[:5]}, checksum distinto {distintas[:5]}'


def main():
    if len(sys.argv) != 5:
        print('uso: cadena.py <paquete> <réplica> <sha256 fijado de la réplica> <socket>', file=sys.stderr)
        return 2
    paquete, ruta_replica, fijado, socket = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4]
    replica = ruta_replica.read_bytes()
    if sha256(replica) != fijado:
        fallo(f'{ruta_replica} no es la réplica fijada: sha256 {sha256(replica)}, se esperaba {fijado}')
    manifiesto = leer_manifiesto(paquete / 'manifiesto.sha256')
    trabajo = montar(paquete, replica, manifiesto)
    config = {'host': socket, 'dbname': 'uonify', 'user': 'uonify'}
    if tabla(config) is not None:
        fallo('la base no está vacía: schema_migrations ya existe')
    esperado = sorted(manifiesto)
    tiempos, primera = [], None
    for numero in (1, 2):
        try:
            tiempos.append(pasada(trabajo, config))
        except subprocess.CalledProcessError:
            fallo(f'migrate() falló en la pasada {numero}; el error de PostgreSQL está justo encima')
        filas = tabla(config)
        if numero == 1 and filas != esperado:
            fallo(f'tras la 1.ª pasada, schema_migrations no es el manifiesto: {diferencias(filas, esperado)}')
        if numero == 2 and filas != primera:
            fallo(f'la 2.ª pasada cambió schema_migrations: {diferencias(filas, primera)}')
        primera = filas
    linea = (f'Cadena 001→N dos veces con la réplica de migrate() (sha256 {fijado[:12]}…): '
             f'1.ª pasada, {len(esperado)} aplicadas en una transacción ({tiempos[0]:.1f} s); '
             f'2.ª, ninguna ({tiempos[1]:.1f} s). schema_migrations = manifiesto.')
    print(linea)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a', encoding='utf-8') as resumen:
            resumen.write(linea + '\n\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
