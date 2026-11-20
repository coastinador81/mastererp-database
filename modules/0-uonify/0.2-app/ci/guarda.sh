#!/usr/bin/env bash
# Guarda «solo añadir» de las migraciones de la base propia de Uonify (paso F1.4 del plan F1).
# Regla: README de 0.2-app, «Cambiar o añadir una migración», punto 1. Una migración aplicada no
# se edita, renombra, borra ni cambia de tipo: su nombre es la clave de schema_migrations y su
# sha256 se comprueba en cada arranque de la API.
#
# Uso, desde cualquier carpeta del repo: bash guarda.sh <base> [<ancla>]
#   <base>   commit con el que se compara: el primer padre del merge de prueba del PR o el
#            «before» del push a dev.
#   <ancla>  commit fijo de dev con un conjunto ya revisado. Con dev sin proteger, un commit se
#            puede quedar en dev sin un run que lo pare (en rojo, cancelado o con [skip ci]) y el
#            push siguiente, cuya base ya lo trae, no lo ve. Por eso se mira además contra el ancla
#            y commit a commit en la línea principal de dev (primer padre) desde el ancla. No ve un
#            cambio que solo esté en el segundo padre de una fusión (dev fusionado en una rama que
#            después se empuja a dev) ni una historia reescrita que conserve el ancla: eso lo ven
#            REA y la comprobación previa del despliegue. Mover el ancla es cambiar el workflow.
# Salida: 0 si todo es añadir; 1 y «RECHAZO <regla>: …» si no; 2 si no se puede comprobar.
# Sus pruebas (casos M, D, T y enlace, entre otros) están en probar.sh.
set -euo pipefail

DIR=modules/0-uonify/0.2-app/migrations
base=${1:?uso: guarda.sh <base> [<ancla>]}
ancla=${2:-}

rechazo() { printf 'RECHAZO %s: %s\n' "$1" "$2" >&2; exit 1; }
error() { printf 'ERROR: %s\n' "$1" >&2; exit 2; }

raiz=$(git rev-parse --show-toplevel 2> /dev/null) || error "no estoy dentro de un repo de git"
cd "$raiz"
[ -d "$DIR" ] || error "no existe $DIR"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Cambios de migrations/ entre <commit> y HEAD, con la orden del diseño F1, lanzada desde la raíz
# y con la ruta fija: con cd, si migrations/ pasara a ser un enlace, git miraría la carpeta de
# destino y no vería las D. La salida va a un fichero y no a una tubería: con pipefail, un git
# diff fallido o un SIGPIPE de git dentro del «if» harían falsa la condición y dejarían pasar el
# cambio. Con --no-renames, renombrar sale como D + A.
contra() {
  local commit=$1 cual=$2
  git rev-parse --verify --quiet "$commit^{commit}" > /dev/null || error "$cual $commit: no está en el clon"
  git merge-base --is-ancestor "$commit" HEAD ||
    rechazo historia "$cual ${commit:0:12} no es antecesor de HEAD (historia reescrita)"
  git diff --no-renames --name-status "$commit" HEAD -- ":(literal)$DIR" > "$tmp/cambios"
  if grep -qE '^[MDT]' "$tmp/cambios"; then
    grep -E '^[MDT]' "$tmp/cambios" >&2
    rechazo solo-añadir "contra $cual ${commit:0:12} hay migraciones cambiadas (M), borradas (D) o de otro tipo (T)"
  fi
}

contra "$base" base
nuevas=$(grep -c '^A' "$tmp/cambios" || true)
if [ -n "$ancla" ]; then
  contra "$ancla" ancla
  # Commit a commit en la línea principal desde el ancla, cada uno contra su primer padre (una
  # fusión, contra el dev en el que entra): así sale también lo que cambió una migración añadida
  # después del ancla, aunque los extremos solo muestren A.
  git log --first-parent --diff-merges=first-parent --no-renames --name-status --format= \
    "$ancla..HEAD" -- ":(literal)$DIR" > "$tmp/historia"
  if grep -qE '^[MDT]' "$tmp/historia"; then
    grep -E '^[MDT]' "$tmp/historia" >&2
    rechazo solo-añadir "en la línea principal desde el ancla ${ancla:0:12}, un commit cambia (M), borra (D) o cambia de tipo (T) una migración"
  fi
fi

# Enlaces y demás: en migrations/ solo caben ficheros .sql normales (modo 100644) en su raíz; ni
# enlaces simbólicos (120000), ni ejecutables, ni submódulos, ni subcarpetas. Se mira el árbol de
# git de HEAD, que es de donde sale el tarball, y no el árbol de trabajo.
git ls-tree -r -z HEAD -- "$DIR" > "$tmp/arbol"
total=0
malas=0
while IFS= read -r -d '' registro; do
  total=$((total + 1))
  read -r modo tipo _ <<< "${registro%%$'\t'*}"
  ruta=${registro#*$'\t'}
  nombre=${ruta#"$DIR"/}
  if [ "$modo" != 100644 ] || [ "$tipo" != blob ] || [ "$nombre" = "$ruta" ] ||
     [[ "$nombre" == */* || "$nombre" != *.sql ]]; then
    printf '%s %s %s\n' "$modo" "$tipo" "$ruta" >&2
    malas=$((malas + 1))
  fi
done < "$tmp/arbol"
[ "$malas" -eq 0 ] ||
  rechazo entrada "en migrations/ solo caben ficheros .sql normales en su raíz: sin enlaces, ejecutables, submódulos ni subcarpetas"
[ "$total" -gt 0 ] || error "$DIR está vacía en HEAD"

linea="Guarda «solo añadir»: OK. $total ficheros en HEAD, $nuevas nuevos contra la base ${base:0:12}"
if [ -n "$ancla" ]; then linea="$linea; nada cambiado contra el ancla ${ancla:0:12} ni en la línea principal desde él"; fi
echo "$linea"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n\n' "$linea" >> "$GITHUB_STEP_SUMMARY"; fi
