#!/usr/bin/env bash
# Pruebas de guarda.sh y reglas.py (paso F1.4 del plan F1). Los «fixtures» son repos de git
# desechables que se crean aquí: los casos M, D, T y enlace que pide el diseño, más renombrar,
# cambiar el modo, una subcarpeta, un submódulo, migrations/ convertida en enlace, bases que no
# valen, el ancla y la historia desde él, y las reglas de las migraciones nuevas. Cada caso espera
# un resultado exacto: «pasa», «aviso:<regla>» (salida 0 con «AVISO <regla>:»), salida 1 con
# «RECHAZO <regla>:» o, si espera «error», salida 2 con «ERROR:». Solo corre en la CI (job
# validar): no toca el repo real ni la red.
set -euo pipefail

ci=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DIR=modules/0-uonify/0.2-app/migrations
trabajo=$(mktemp -d)
trap 'rm -rf "$trabajo"' EXIT
export GIT_AUTHOR_NAME=prueba GIT_AUTHOR_EMAIL=prueba@example.invalid
export GIT_COMMITTER_NAME=prueba GIT_COMMITTER_EMAIL=prueba@example.invalid
# Los casos no escriben en el resumen del run; al final va solo la tabla de resultados.
resumen=${GITHUB_STEP_SUMMARY:-}
unset GITHUB_STEP_SUMMARY
total=0
malos=()
tabla=()

git -c init.defaultBranch=dev init -q "$trabajo/repo"
cd "$trabajo/repo"
mkdir -p "$DIR"
printf 'CREATE TABLE a (id int);\n' > "$DIR/001_a.sql"
printf 'CREATE TABLE b (id int);\n' > "$DIR/002_b.sql"
git add -A
git commit -q -m base
base=$(git rev-parse HEAD)

# comprobar <caso> <esperado> <código> <salida>: esperado es «pasa», «aviso:<regla>», «error» o la
# regla del RECHAZO.
comprobar() {
  local caso=$1 esperado=$2 codigo=$3 salida=$4 bien=0
  total=$((total + 1))
  if [ "$esperado" = pasa ]; then
    if [ "$codigo" -eq 0 ]; then bien=1; fi
  elif [ "${esperado#aviso:}" != "$esperado" ]; then
    if [ "$codigo" -eq 0 ] && grep -qF "AVISO ${esperado#aviso:}:" <<< "$salida"; then bien=1; fi
  elif [ "$esperado" = error ]; then
    if [ "$codigo" -eq 2 ] && grep -qF 'ERROR:' <<< "$salida"; then bien=1; fi
  elif [ "$codigo" -eq 1 ] && grep -qF "RECHAZO $esperado:" <<< "$salida"; then
    bien=1
  fi
  if [ "$bien" -eq 1 ]; then
    printf 'ok     %-24s %s\n' "$caso" "$esperado"
    tabla+=("| $caso | $esperado | ok |")
  else
    printf 'FALLO  %-24s esperaba %s; salió %s con:\n%s\n' "$caso" "$esperado" "$codigo" "$salida"
    tabla+=("| $caso | $esperado | **FALLO** (salida $codigo) |")
    malos+=("$caso")
  fi
}

# lanzar <caso> <esperado> <guarda|reglas> <argumentos>: pasa el comprobador a HEAD.
lanzar() {
  local nombre=$1 esperado=$2 quien=$3 salida codigo=0
  shift 3
  if [ "$quien" = guarda ]; then
    salida=$(bash "$ci/guarda.sh" "$@" 2>&1) || codigo=$?
  else
    salida=$(python3 -I "$ci/reglas.py" "$@" 2>&1) || codigo=$?
  fi
  comprobar "$nombre" "$esperado" "$codigo" "$salida"
}

# caso <caso> <esperado> <guarda|reglas> <orden que prepara el cambio> [argumentos]: parte siempre
# de la base, hace el cambio en un commit y pasa el comprobador contra la base.
caso() {
  local nombre=$1 esperado=$2 quien=$3
  shift 3
  git checkout -q --detach "$base"
  "$@"
  git add -A
  git commit -q -m "$nombre"
  lanzar "$nombre" "$esperado" "$quien" "$base"
}

# pushes <fichero> <contenido> [<fichero> <contenido>…]: desde la base, un commit por par, como
# pushes seguidos a dev. Deja en $intermedio la base del último (el «before» de su push).
pushes() {
  git checkout -q --detach "$base"
  while [ "$#" -gt 0 ]; do
    intermedio=$(git rev-parse HEAD)
    escribir "$1" "$2"
    git add -A
    git commit -q -m "push: $1"
    shift 2
  done
}

escribir() { printf '%s' "$2" > "$DIR/$1"; }
modificar() { escribir 001_a.sql $'CREATE TABLE a (id bigint);\n'; }
cambiar_modo() { chmod +x "$DIR/002_b.sql"; }
borrar() { git rm -q "$DIR/002_b.sql"; }
renombrar() { git mv "$DIR/002_b.sql" "$DIR/002_c.sql"; }
cambiar_tipo() { rm "$DIR/001_a.sql"; ln -s 002_b.sql "$DIR/001_a.sql"; }
enlazar() { ln -s 001_a.sql "$DIR/003_c.sql"; }
subcarpeta() { mkdir "$DIR/sub"; escribir sub/003_c.sql $'SELECT 1;\n'; }
# migrations/ pasa a ser un enlace a otra carpeta con las mismas migraciones.
carpeta_enlace() {
  mkdir modules/0-uonify/0.2-app/otra
  cp "$DIR"/*.sql modules/0-uonify/0.2-app/otra/
  git rm -rq "$DIR"
  rm -rf "$DIR"
  ln -s otra "$DIR"
}
largo() { seq 1 501 | sed 's/.*/SELECT &;/' > "$DIR/003_largo.sql"; }
dos_seguidas() { escribir 003_uno.sql $'SELECT 1;\n'; escribir 004_dos.sql $'SELECT 2;\n'; }
# Valores de prueba montados al vuelo, para que el escaneo de secretos y correos del PR no los vea.
con_uuid() { printf -- '-- %s-%s-%s-%s-%s\nSELECT 1;\n' 00000000 0000 0000 0000 000000000000 > "$DIR/003_con_uuid.sql"; }
con_correo() { printf -- '-- %s@%s\nSELECT 1;\n' persona uonify.com > "$DIR/003_con_correo.sql"; }
con_secreto() { printf -- '-- %s%s\nSELECT 1;\n' AKIA ABCDEFGHIJKLMNOP > "$DIR/003_con_secreto.sql"; }

# Guarda «solo añadir»: los 4 casos del diseño (M, D, T y enlace) y los que dependen de ellos.
caso M solo-añadir guarda modificar
caso M-modo solo-añadir guarda cambiar_modo
caso D solo-añadir guarda borrar
caso D-renombrar solo-añadir guarda renombrar
caso T solo-añadir guarda cambiar_tipo
caso enlace entrada guarda enlazar
caso subcarpeta entrada guarda subcarpeta
caso A-nueva pasa guarda escribir 003_c.sql $'CREATE TABLE c (id int);\n'
# Con cd, git miraría la carpeta de destino y solo vería A: el diff va desde la raíz.
caso carpeta-enlace solo-añadir guarda carpeta_enlace
# Submódulo: un gitlink (modo 160000) en el índice, sin nada en el árbol de trabajo.
git checkout -q --detach "$base"
git update-index --add --cacheinfo "160000,$base,$DIR/003_sub.sql"
git commit -q -m submodulo
lanzar submodulo entrada guarda "$base"
# Bases que no valen: una que no es antecesora de HEAD y otra que no está en el clon.
pushes 003_c.sql $'SELECT 1;\n'
ajena=$(git rev-parse HEAD)
pushes 003_d.sql $'SELECT 2;\n'
lanzar base-ajena historia guarda "$ajena"
lanzar base-inexistente error guarda 0123456789abcdef0123456789abcdef01234567

# Ancla: el cambio de 001 llega en un push (su run falla) y la 003, en el siguiente. Contra la
# base de ese segundo push solo se añade; contra el ancla, el cambio sigue saliendo.
pushes 001_a.sql $'CREATE TABLE a (id bigint);\n' 003_c.sql $'SELECT 1;\n'
lanzar ancla-sin-ancla pasa guarda "$intermedio"
lanzar ancla solo-añadir guarda "$intermedio" "$base"
# Post-ancla: la 003 llega en un push, otro la cambia (su run falla) y un tercero añade la 004. Ni
# contra su base ni contra el ancla sale nada cambiado; commit a commit desde el ancla, sí.
pushes 003_c.sql $'SELECT 1;\n' 003_c.sql $'SELECT 2;\n' 004_d.sql $'SELECT 3;\n'
lanzar post-ancla solo-añadir guarda "$intermedio" "$base"

# Reglas de las nuevas (README de 0.2-app, puntos 2 y 3, y lista prohibida).
caso valida pasa reglas escribir 003_tema_nuevo.sql $'CREATE TABLE c (id int);\nGRANT SELECT ON c TO lector;\n'
caso dos-seguidas pasa reglas dos_seguidas
caso hueco numero reglas escribir 004_hueco.sql $'SELECT 1;\n'
caso repetida numero reglas escribir 002_repetida.sql $'SELECT 1;\n'
caso nombre nombre reglas escribir 003_Mal-Nombre.sql $'SELECT 1;\n'
caso largo lineas reglas largo
caso crlf codificacion reglas escribir 003_crlf.sql $'SELECT 1;\r\n'
caso uuid uuid reglas con_uuid
caso correo correo reglas con_correo
caso secreto secreto reglas con_secreto
caso copy-program 'prohibida[copy-program]' reglas escribir 003_copia.sql $'COPY a FROM PROGRAM \'id\';\n'
caso copy-fichero 'prohibida[ficheros-servidor]' reglas escribir 003_leer.sql $'COPY a FROM \'/tmp/fuera.csv\';\n'
caso alter-system 'prohibida[alter-system]' reglas escribir 003_sistema.sql $'ALTER SYSTEM SET work_mem = \'1MB\';\n'
caso rol-ddl 'prohibida[rol-ddl]' reglas escribir 003_rol.sql $'CREATE ROLE intruso LOGIN;\n'
caso rol-oculto 'prohibida[rol-ddl]' reglas escribir 003_rol_oculto.sql $'CREATE/**/ROLE intruso;\n'
caso rol-pertenencia 'prohibida[rol-pertenencia]' reglas escribir 003_miembro.sql $'GRANT pg_read_server_files TO lector;\n'
# Un comentario en inglés no es un GRANT: la lista prohibida no mira los comentarios.
caso comentario pasa reglas escribir 003_comentario.sql $'-- grant read to the app\nGRANT SELECT ON c TO lector;\n'
# Rol: el par acotado de la 116 (SET LOCAL ROLE por EXECUTE y RESET ROLE detrás) pasa con aviso para
# REA. Sin el RESET, con el RESET delante, de sesión, como «SET role =», SESSION AUTHORIZATION o
# set_config, no.
caso rol-local-acotado aviso:rol-local reglas escribir 003_relleno.sql $'DO $r$ BEGIN\n  EXECUTE format(\'SET LOCAL ROLE %I\', \'escritor\');\n  UPDATE c SET id = 1;\n  RESET ROLE;\nEND $r$;\n'
caso rol-local-sin-reset 'prohibida[rol-local-sin-reset]' reglas escribir 003_relleno.sql $'SET LOCAL ROLE escritor;\nUPDATE c SET id = 1;\n'
caso rol-local-reset-antes 'prohibida[rol-local-sin-reset]' reglas escribir 003_relleno.sql $'RESET ROLE;\nSET LOCAL ROLE escritor;\n'
caso rol-sesion 'prohibida[rol-identidad]' reglas escribir 003_rol_sesion.sql $'SET ROLE escritor;\n'
caso rol-guc 'prohibida[rol-identidad]' reglas escribir 003_rol_guc.sql $'SET role = \'escritor\';\n'
caso rol-autorizacion 'prohibida[rol-identidad]' reglas escribir 003_autorizacion.sql $'SET SESSION AUTHORIZATION escritor;\n'
caso rol-set-config 'prohibida[rol-identidad]' reglas escribir 003_set_config.sql $'SELECT set_config(\'role\', \'escritor\', true);\n'
# Las mismas con el nombre entre comillas o como parámetro, y las que pidió REA el 21-11: también la
# forma local de SESSION AUTHORIZATION; RESET ROLE solo pasa; una columna llamada role sale (rechazo
# esperado, documentado) y se escribe SET (role) = ROW(…).
caso rol-comillas 'prohibida[rol-identidad]' reglas escribir 003_rol_comillas.sql $'SET "role" = \'escritor\';\n'
caso rol-local-comillas 'prohibida[rol-local-sin-reset]' reglas escribir 003_rol_local.sql $'SET LOCAL "role" = \'escritor\';\n'
caso rol-autorizacion-guc 'prohibida[rol-identidad]' reglas escribir 003_autorizacion.sql $'SET session_authorization = \'escritor\';\n'
caso rol-autorizacion-local 'prohibida[rol-identidad]' reglas escribir 003_autorizacion.sql $'SET LOCAL SESSION AUTHORIZATION escritor;\n'
caso rol-config-autorizacion 'prohibida[rol-identidad]' reglas escribir 003_set_config.sql $'SELECT set_config(\'session_authorization\', \'escritor\', false);\n'
caso rol-reset-solo pasa reglas escribir 003_reset.sql $'RESET ROLE;\n'
caso rol-columna 'prohibida[rol-identidad]' reglas escribir 003_columna.sql $'UPDATE c SET role = \'lector\';\n'
caso rol-columna-fila pasa reglas escribir 003_columna.sql $'UPDATE c SET (role) = ROW(\'lector\');\n'
# Reglas desde el ancla: una 003 con CREATE ROLE entra en un push que no la para y el siguiente
# solo añade la 004. Contra su base pasa; desde el ancla, no.
pushes 003_rol.sql $'CREATE ROLE intruso;\n' 004_d.sql $'SELECT 1;\n'
lanzar reglas-sin-ancla pasa reglas "$intermedio"
lanzar reglas-ancla 'prohibida[rol-ddl]' reglas "$base"
# Dos PR añaden cada uno una 003 y después llega la 004: desde el ancla sale la 003 repetida.
pushes 003_uno.sql $'SELECT 1;\n' 003_otro.sql $'SELECT 2;\n' 004_d.sql $'SELECT 3;\n'
lanzar repetida-absorbida numero reglas "$base"

printf 'Pruebas de la guarda y de las reglas: %s de %s bien\n' "$((total - ${#malos[@]}))" "$total"
if [ -n "$resumen" ]; then
  {
    printf '### Pruebas de la guarda y de las reglas: %s de %s bien\n\n' "$((total - ${#malos[@]}))" "$total"
    printf '| Caso | Se espera | Resultado |\n| --- | --- | --- |\n'
    printf '%s\n' "${tabla[@]}"
    printf '\n'
  } >> "$resumen"
fi
if [ "${#malos[@]}" -gt 0 ]; then
  echo "Fallan: ${malos[*]}"
  exit 1
fi
