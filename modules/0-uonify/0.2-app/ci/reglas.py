#!/usr/bin/env python3
"""Reglas de las migraciones nuevas de la base propia de Uonify (paso F1.4 del plan F1).

Uso, desde cualquier carpeta del repo: python3 -I reglas.py <desde>

Mira lo que HEAD añade a migrations/ respecto a <desde> (cambiar, borrar o cambiar de tipo ya lo
rechaza guarda.sh) y lee los blobs de git, no el árbol de trabajo. En la CI, <desde> es el ancla
del workflow y no la base del PR o del push: lo que entró en dev sin un run que lo parara (en
rojo, cancelado o con [skip ci]) se sigue revisando en cada run. Reglas: README de 0.2-app,
«Cambiar o añadir una migración», puntos 2 y 3 (el número siguiente al mayor, sin huecos ni
repetidos; NNN_<tema>.sql en snake_case; 500 líneas como máximo; sin secretos, UUID ni correos
reales) y la lista prohibida del diseño F1 (COPY … PROGRAM, ALTER SYSTEM y roles), con lo que
también saca a la base de su sitio: ficheros del servidor, lenguajes y extensiones no confiables,
conexiones externas, bases, tablespaces, disparadores de eventos y configuración del servidor.
Además, UTF-8 y sin CR: así el sha256 del fichero es el checksum que guarda migrate(). Un SET
LOCAL ROLE solo pasa con un RESET ROLE detrás, como el relleno de la 116, y con aviso para REA.

Sale con 1 y una línea «RECHAZO <regla>: <fichero>: <detalle>» por incumplimiento. Los «AVISO» no
bloquean: marcan lo que no es aditivo (DROP, TRUNCATE, RENAME…) para la revisión de REA mientras
la línea CONV no se unifique. La lista prohibida y los avisos se aplican al texto sin los
comentarios que se pueden quitar sin esconder código (ver sin_comentarios); los UUID, secretos y
correos, al texto entero. Es una red contra descuidos, no un cortafuegos: el SQL dinámico
(EXECUTE) o un comentario con comillas entre dos palabras esquivan cualquier patrón, y por eso
REA revisa el texto de cada migración nueva. De un secreto, un UUID o un correo solo se imprime
la línea, nunca el valor.
"""
import hashlib
import os
import re
import subprocess
import sys

DIR = 'modules/0-uonify/0.2-app/migrations'
NOMBRE = re.compile(r'([0-9]{3})_[a-z0-9]+(?:_[a-z0-9]+)*\.sql')
MAX_LINEAS = 500
UUID = re.compile(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', re.I)
# Los patrones del escaneo de secretos de la sección 8 de las Reglas comunes de 0-uonify.
SECRETO = re.compile(
    r'(AKIA|ASIA)[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|GOCSPX-|ya29\.|1//0[0-9A-Za-z_-]{20}'
    r'|(sk|rk)_(live|test)_|whsec_|gh[pousr]_[0-9A-Za-z]{36}|github_pat_'
    r'|eyJ[0-9A-Za-z_-]{20,}\.eyJ|PRIVATE KEY|HeaderValue')
# Correos: el patrón de la sección 8, con al menos una letra o cifra antes de la @ (un LIKE '%@…'
# no cuenta), salvo los dominios reservados que esa sección admite.
CORREO = re.compile(r'([A-Za-z0-9._%+-]+)@([A-Za-z0-9.-]+\.[A-Za-z]{2,})')
ALFANUMERICO = re.compile(r'[A-Za-z0-9]')
RESERVADO = re.compile(r'(?:[a-z0-9-]+\.)*(?:example|test|invalid|localhost)|example\.(?:com|net|org)', re.I)

PROHIBIDAS = [(regla, re.compile(patron, re.I)) for regla, patron in (
    ('copy-program', r'\bCOPY\b[^;]*\bPROGRAM\b'),
    ('alter-system', r'\bALTER\s+SYSTEM\b'),
    ('rol-ddl', r'\b(?:CREATE|ALTER|DROP)\s+(?:ROLE|USER|GROUP)\b'),
    # GRANT o REVOKE de un rol a otro: los que no llevan ON antes del TO o del FROM. Dar permisos
    # sobre un objeto a un rol que ya existe (GRANT SELECT ON t TO r) sí se puede.
    ('rol-pertenencia', r'\bGRANT\b(?:(?!\bON\b)[^;])*?\bTO\b|\bREVOKE\b(?:(?!\bON\b)[^;])*?\bFROM\b'),
    # migrate() aplica todas en una transacción y una conexión: un SET ROLE de sesión (también en su
    # forma «SET role = …» y con el nombre entre comillas) seguiría tras el commit, igual que SESSION
    # AUTHORIZATION, su forma de parámetro (SET session_authorization = …) y set_config. Sale además
    # un UPDATE … SET role = … de una columna llamada role: se escribe SET (role) = ROW(…).
    # SET LOCAL ROLE: ver ROL_LOCAL.
    ('rol-identidad', r'\bSET\s+(?:SESSION\s+)?"?ROLE\b|\bSESSION\s+AUTHORIZATION\b'
                      r'|\bSET\s+(?:SESSION\s+|LOCAL\s+)?"?session_authorization\b'
                      r"|\bset_config\s*\(\s*'(?:role|session_authorization)'"),
    ('ficheros-servidor',
     r'\b(?:pg_read_file|pg_read_binary_file|pg_ls_dir|pg_stat_file|pg_file_write|lo_import|lo_export)\b'),
    # COPY con un fichero del servidor (no el \copy de psql): lee o escribe en el disco de la base.
    ('ficheros-servidor', r'\bCOPY\b[^;]*\b(?:FROM|TO)\s+(?:E\'|U&\'|\'|\$)'),
    ('load', r'\bLOAD\s+[\'"]'),
    ('lenguaje', r'\bCREATE\s+(?:OR\s+REPLACE\s+)?(?:TRUSTED\s+)?(?:PROCEDURAL\s+)?LANGUAGE\b'
                 r'|\bLANGUAGE\s+[\'"]?(?:c|internal|plpython3?u|plperlu|pltclu)\b'),
    ('extension', r'\bCREATE\s+EXTENSION\b[^;]*\b(?:adminpack|file_fdw|dblink|postgres_fdw|plpython3?u|plperlu|pltclu)\b'),
    ('conexion-externa', r'\bdblink\w*\s*\(|\bCREATE\s+(?:SERVER|FOREIGN\s+DATA\s+WRAPPER|SUBSCRIPTION|PUBLICATION)\b'),
    ('base-o-tablespace', r'\b(?:CREATE|ALTER|DROP)\s+(?:DATABASE|TABLESPACE)\b'),
    ('event-trigger', r'\bCREATE\s+(?:OR\s+REPLACE\s+)?EVENT\s+TRIGGER\b'),
    ('configuracion', r'\bpg_reload_conf\b|\bsession_replication_role\b'),
)]

# SET LOCAL ROLE dura hasta el final de la transacción de migrate(), que es la de todas: solo pasa
# con un RESET ROLE detrás del último, como el relleno de la 116. Aun así queda un aviso: el orden
# del texto no prueba el de la ejecución (un IF o un RETURN pueden saltarse el RESET), y eso lo
# comprueba REA. Los dos patrones admiten el nombre entre comillas («SET LOCAL "role" = …»).
ROL_LOCAL = re.compile(r'\bSET\s+LOCAL\s+"?ROLE\b', re.I)
RESET_ROL = re.compile(r'\bRESET\s+"?ROLE\b', re.I)

AVISOS = [(regla, re.compile(patron, re.I)) for regla, patron in (
    ('no-aditiva', r'\bDROP\s+(?:TABLE|COLUMN|SCHEMA|VIEW|MATERIALIZED\s+VIEW|TYPE|SEQUENCE|INDEX'
                   r'|CONSTRAINT|FUNCTION|PROCEDURE|TRIGGER|POLICY)\b'),
    ('no-aditiva', r'\bTRUNCATE\b|\bDELETE\s+FROM\b|\bRENAME\b'),
    ('no-aditiva', r'\bALTER\s+COLUMN\b[^;]*?\b(?:TYPE|SET\s+NOT\s+NULL)\b'),
)]

# Comentarios que se quitan: «--» hasta el final de la línea y «/* … */» dentro de una línea, si
# lo que se quita no lleva comillas, $ ni «*/». Una cadena, un identificador entre comillas o un
# comentario de bloque solo terminan en uno de esos caracteres, así que, esté PostgreSQL donde
# esté al llegar ahí, lo quitado es un comentario o el interior de una cadena, nunca código.
COMENTARIO_LINEA = re.compile(r'--(?:(?!\*/)[^\n\'"$])*$', re.M)
COMENTARIO_BLOQUE = re.compile(r'/\*(?:(?!\*/|/\*)[^\n\'"$])*\*/')


def git(*args):
    return subprocess.run(('git', *args), check=True, stdout=subprocess.PIPE).stdout


def linea(texto, posicion):
    return texto.count('\n', 0, posicion) + 1


def numero_de_lineas(datos):
    """Como awk 'END{print NR}', el recuento de la sección 10 de las Reglas comunes."""
    return datos.count(b'\n') + (1 if datos and not datos.endswith(b'\n') else 0)


def sin_comentarios(texto):
    """El texto sin esos comentarios: un comentario en inglés («grant … to») no rechaza nada y
    CREATE/**/ROLE no esquiva la regla. Conserva los saltos de línea y, con ellos, su número."""
    return COMENTARIO_LINEA.sub('', COMENTARIO_BLOQUE.sub(' ', texto))


def previas(desde):
    salida = git('ls-tree', '-r', '-z', '--name-only', desde, '--', DIR).decode('utf-8')
    return [ruta[len(DIR) + 1:] for ruta in salida.split('\0') if ruta.startswith(DIR + '/')]


def nuevas_de(desde):
    salida = git('diff', '--no-renames', '--name-status', '-z', '--diff-filter=A', desde, 'HEAD', '--', DIR)
    campos = salida.decode('utf-8').split('\0')
    return sorted(campos[i + 1][len(DIR) + 1:] for i in range(0, len(campos) - 1, 2) if campos[i] == 'A')


def revisar(nombre, datos, avisos):
    try:
        texto = datos.decode('utf-8')
    except UnicodeDecodeError:
        return [('codificacion', nombre, 'no es UTF-8')]
    rechazos = []
    if '\r' in texto or '\0' in texto:
        rechazos.append(('codificacion', nombre, 'lleva CR o NUL: su sha256 dejaría de ser el checksum de migrate()'))
    lineas = numero_de_lineas(datos)
    if lineas > MAX_LINEAS:
        rechazos.append(('lineas', nombre, f'{lineas} líneas; el máximo es {MAX_LINEAS}'))
    for regla, patron in (('uuid', UUID), ('secreto', SECRETO)):
        rechazos += [(regla, nombre, f'línea {linea(texto, m.start())}') for m in patron.finditer(texto)]
    rechazos += [('correo', nombre, f'línea {linea(texto, m.start())}: dominio no reservado')
                 for m in CORREO.finditer(texto)
                 if ALFANUMERICO.search(m.group(1)) and not RESERVADO.fullmatch(m.group(2))]
    codigo = sin_comentarios(texto)
    for regla, patron in PROHIBIDAS:
        rechazos += [(f'prohibida[{regla}]', nombre, f'línea {linea(codigo, m.start())}')
                     for m in patron.finditer(codigo)]
    locales = list(ROL_LOCAL.finditer(codigo))
    if locales and RESET_ROL.search(codigo, locales[-1].end()):
        avisos += [('rol-local', nombre, f'línea {linea(codigo, m.start())}: SET LOCAL ROLE con RESET ROLE detrás')
                   for m in locales]
    elif locales:
        rechazos.append(('prohibida[rol-local-sin-reset]', nombre,
                         f'línea {linea(codigo, locales[-1].start())}: SET LOCAL ROLE sin RESET ROLE detrás; '
                         'el rol seguiría en las migraciones siguientes'))
    for regla, patron in AVISOS:
        avisos += [(regla, nombre, f'línea {linea(codigo, m.start())}') for m in patron.finditer(codigo)]
    return rechazos


def resumen(nuevas, maximo, filas, avisos, rechazos):
    ruta = os.environ.get('GITHUB_STEP_SUMMARY')
    if not ruta:
        return
    partes = [f'### Migraciones añadidas desde el ancla: {len(nuevas)} (la mayor del ancla es la {maximo:03d})', '']
    if filas:
        partes += ['| Migración | Líneas | sha256 (= checksum de migrate()) |', '| --- | ---: | --- |']
        partes += [f'| `{n}` | {l} | `{s}` |' for n, l, s in filas]
    partes += [f'- AVISO {r}: `{n}`, {d} (no bloquea; para REA)' for r, n, d in avisos]
    partes += [f'- **RECHAZO {r}**: `{n}`, {d}' for r, n, d in rechazos]
    with open(ruta, 'a', encoding='utf-8') as salida:
        salida.write('\n'.join(partes) + '\n\n')


def main():
    if len(sys.argv) != 2:
        print('uso: reglas.py <desde>', file=sys.stderr)
        return 2
    desde = sys.argv[1]
    os.chdir(git('rev-parse', '--show-toplevel').decode('utf-8').strip())
    maximo = max((int(n[:3]) for n in previas(desde) if n[:3].isdigit()), default=0)
    nuevas = nuevas_de(desde)
    rechazos, avisos, numeros, filas = [], [], [], []
    for nombre in nuevas:
        coincide = NOMBRE.fullmatch(nombre)
        if not coincide:
            rechazos.append(('nombre', nombre, 'tiene que ser NNN_<tema>.sql en snake_case (minúsculas, cifras y _)'))
            continue
        numeros.append(int(coincide.group(1)))
        datos = git('cat-file', 'blob', f'HEAD:{DIR}/{nombre}')
        rechazos += revisar(nombre, datos, avisos)
        filas.append((nombre, numero_de_lineas(datos), hashlib.sha256(datos).hexdigest()))
    esperados = list(range(maximo + 1, maximo + 1 + len(numeros)))
    if sorted(numeros) != esperados:
        rechazos.append(('numero', ', '.join(nuevas),
                         f'tienen que ser de la {esperados[0]:03d} a la {esperados[-1]:03d}, seguidas: '
                         f'por encima de la {maximo:03d}, sin huecos ni números repetidos'))
    for regla, nombre, detalle in rechazos:
        print(f'RECHAZO {regla}: {nombre}: {detalle}', file=sys.stderr)
    for regla, nombre, detalle in avisos:
        print(f'AVISO {regla}: {nombre}: {detalle} (no bloquea; para REA)')
    print(f'Reglas de las añadidas desde {desde[:12]}: {len(nuevas)} '
          f'(la mayor allí era la {maximo:03d}): {", ".join(nuevas) or "ninguna"}')
    resumen(nuevas, maximo, filas, avisos, rechazos)
    return 1 if rechazos else 0


if __name__ == '__main__':
    sys.exit(main())
