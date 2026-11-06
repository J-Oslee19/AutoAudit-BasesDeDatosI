# Revisión técnica de entrega

6 de noviembre de 2026. Esta guía registra los cambios y prepara la validación en Ubuntu 26.04 LTS con PostgreSQL 18.6. El PDF del enunciado y las evidencias previas se conservan.

## Registro de cambios

| Archivo | Cambio |
|---|---|
| `instalar.sh` | Conexión local por socket o TCP con solicitud interactiva de contraseña SCRAM. Comprueba las dos versiones, el rol, los propietarios, permisos de creación, las siete tablas base, sus columnas, identidades y claves. Aplica los módulos en una transacción y rechaza estructuras parciales. |
| `sql/03_ajustes_configuracion.sql` | Busca cada restricción en su tabla y comprueba que las existentes tengan la definición esperada y estén validadas y aplicadas. |
| `sql/05_modulo_configuracion.sql` | Fija `pg_catalog, pg_temp` en las siete funciones privilegiadas y califica las consultas de roles y del diccionario. Conserva firmas, permisos y lógica. |
| `sql/11_reportes.sql` | Agrega `fn_reporte_estado_triggers()`. El reporte anterior conserva su contrato. |
| `sql/12_exportar_reportes.sql` | Valida rutas y filtros, reserva un directorio privado nuevo y exporta en UTF-8 con una instantánea de solo lectura. Conserva nombres y encabezados. |
| `docs/Documentacion_Final_AutoAudit.pdf` | Actualiza las páginas de despliegue, reporte y exportación. Conserva el modelo, el diccionario y las evidencias históricas. |
| `README.md` | Procedimiento vigente, uso de la interfaz SQL, roles, exportación y alcance de las evidencias. |
| `README_modulo_triggers.md` | Distingue la instalación histórica de la vigente y documenta las pausas de auditoría. |
| `LEEME_PARA_TRIGGERS.md` y `docs/README_configuracion.md` | Remiten al instalador integrado, separan las pruebas de la instalación y describen el generador ya implementado. |
| `docs/REVISION_FINAL.md` | Registro, revisión contra el enunciado y pruebas de aceptación preparadas. |

El instalador solo aplica `01 → 03 → 04 → 05 → 07 → 08 → 10 → 11`. Valida el modelo antes de reutilizarlo. Una base que solo tiene `01` completo puede continuar con los demás módulos. Una base con parte de `01` necesita diagnóstico y respaldo antes de repararse. `CREATE DATABASE` queda fuera de la transacción por exigencia de PostgreSQL. Usa una base y objetos de confianza, puesto que los scripts se ejecutan como superusuario. En una instalación existente, conserva un respaldo previo y prevé bloqueos de DDL. La definición de restricciones se valida en `03`. El instalador verifica el permiso del nuevo reporte de triggers.

## Cobertura del enunciado

| Requisito | Cobertura y comprobación pendiente |
|---|---|
| Modelo ER, diccionario y manual PDF | El PDF técnico contiene esos entregables y documenta el procedimiento actualizado. Falta ejecutarlo en Ubuntu. |
| Interfaz de configuración, diccionario y activación por operación | `04` y `05` ofrecen vistas y funciones en `psql`, y `08` aplica la configuración. El enunciado deja la tecnología de interfaz a decisión de la clase. Confirma si se acordó una interfaz adicional y demuestra el flujo con una cuenta de configuración. |
| Triggers `AFTER` y bitácora de `INSERT/UPDATE/DELETE` | `07` y `08` registran los cambios en PL/pgSQL y `09`/`13` cubren DML, errores y conservación del historial. La integridad con el origen se conserva mediante el catálogo y la configuración, con una referencia lógica al registro para permitir su borrado. |
| Contexto, roles y privacidad | El usuario procede de `session_user` y la IP de `inet_client_addr()`. El socket Unix puede producir IP nula y un proxy puede ocultar la dirección del cliente final. Falta verificar la IP mediante una conexión TCP real y limitar el acceso y retención de los reportes según la política aplicable. |
| Consulta, línea de tiempo y exportación | `10`/`11` implementan las consultas y reportes. `12` usa salida de cliente de `psql` y `14` deja datos de demostración. Hay muestras históricas. Falta repetir exportaciones con roles y rutas reales y comprobar el caso vacío y los errores. |
| PostgreSQL 18 y Ubuntu 26.04 LTS | Las evidencias históricas reportan PostgreSQL 18.6 sobre Linux. La cabecera del volcado `01` registra su procedencia, pero no valida el instalador nuevo en Ubuntu 26.04 LTS. Repite allí las pruebas de instalación y operación. |
| Impacto de rendimiento | La evidencia muestra un costo sustancial en el caso masivo. Para 50 000 filas y una columna auditada, `INSERT` pasó de 89.9 ms a 7 542.4 ms, `UPDATE` de 196.6 ms a 8 569.5 ms y `DELETE` de 21.3 ms a 6 897.9 ms. No se da por cumplido el criterio de impacto no significativo. Mide tiempos absolutos, sobrecosto y concurrencia con un volumen normal representativo y acuerda el umbral de aceptación. |
| Enlace de GitHub o GitLab | Esta copia no contiene metadatos de un repositorio Git. Adjunta el enlace del repositorio del grupo y verifica que el ingeniero pueda acceder. |

## Resolución de objetos en el módulo de configuración

En `05`, la ruta anterior omitía `pg_temp`, por lo que las relaciones temporales podían buscarse antes que el catálogo. La comprobación administrativa usaba `pg_roles` sin calificar. La nueva ruta pone `pg_catalog` primero y `pg_temp` al final. Las referencias a `pg_roles`, `pg_has_role`, `pg_class`, `pg_namespace` y `pg_attribute` indican su esquema. Las tablas y funciones de AutoAudit conservan sus referencias a `public`, y los tipos, operadores y funciones integrados se resuelven en `pg_catalog` dentro de las funciones privilegiadas. La validación que usa el generador conserva su firma y consulta los auxiliares del diccionario con referencias calificadas.

## Compatibilidad del reporte y el exportador

`fn_reporte_estado_auditoria()` y `estado_auditoria.csv` conservan sus columnas. `trigger_instalado` indica presencia del objeto. `fn_reporte_estado_triggers()` ofrece aparte `trigger_habilitado` para sesiones normales y el modo del catálogo. La habilitación del trigger y la configuración activa son datos distintos.

El exportador crea el destino. Su padre debe existir, carecer de enlaces simbólicos en su ruta y estar bajo control del usuario local. Se admiten rutas absolutas y relativas con componentes simples y espacios. Se rechazan destinos existentes, prefijos de programa y segmentos `..`. Conviene acotar fechas en bitácoras grandes porque el JSON agrega todo el período en un valor. Si la ejecución devuelve error, considera incompleto el directorio generado.

## Pruebas para la entrega

Ejecuta desde la raíz del proyecto en Bash, en un servidor de prácticas aislado. Los nombres siguientes deben estar libres. Si repites la validación, usa nombres nuevos. Los roles de prueba pertenecen al clúster, por lo que el aislamiento por base no evita colisiones de nombres de roles. `06` y `14` dejan cambios persistentes. `09` y `13` revierten sus operaciones al terminar.

### Instalación y módulos

```bash
set -euo pipefail
umask 077
evidencia=$(mktemp -d evidencias/revision-XXXXXX)
export evidencia
pg=(sudo -u postgres psql -X -v ON_ERROR_STOP=1 -h /var/run/postgresql -p "${PGPORT:-5432}")

cat /etc/os-release | tee "$evidencia/ubuntu.txt"
psql --version | tee "$evidencia/cliente.txt"
"${pg[@]}" -d postgres -c 'SELECT version();' | tee "$evidencia/servidor.txt"
test "$("${pg[@]}" -d postgres -Atc 'SHOW server_version_num')" = 180006
bash -n instalar.sh

bash instalar.sh autoaudit_pruebas_config_final 2>&1 | tee "$evidencia/instalacion-config.txt"
"${pg[@]}" -d autoaudit_pruebas_config_final -f sql/06_pruebas_configuracion.sql \
  2>&1 | tee "$evidencia/06.txt"

bash instalar.sh autoaudit_pruebas_final 2>&1 | tee "$evidencia/instalacion.txt"
"${pg[@]}" -d autoaudit_pruebas_final -f sql/09_pruebas_triggers.sql \
  2>&1 | tee "$evidencia/09.txt"
"${pg[@]}" -d autoaudit_pruebas_final -f sql/13_pruebas_validacion.sql \
  2>&1 | tee "$evidencia/13.txt"

bash instalar.sh autoaudit_demo_final 2>&1 | tee "$evidencia/instalacion-demo.txt"
"${pg[@]}" -d autoaudit_demo_final -f sql/14_ejemplo_uso.sql \
  2>&1 | tee "$evidencia/14.txt"
"${pg[@]}" -d autoaudit_demo_final -Atc 'TABLE public.v_bitacora_detalle ORDER BY id_bitacora' \
  > "$evidencia/bitacora-antes.txt"
bash instalar.sh autoaudit_demo_final 2>&1 | tee "$evidencia/reinstalacion.txt"
"${pg[@]}" -d autoaudit_demo_final -Atc 'TABLE public.v_bitacora_detalle ORDER BY id_bitacora' \
  > "$evidencia/bitacora-despues.txt"
cmp "$evidencia/bitacora-antes.txt" "$evidencia/bitacora-despues.txt"
```

Para `06` revisa cada error esperado y cada resultado positivo. El script sigue tras errores y el código de salida por sí solo no basta. Para `09` y `13` verifica código cero, todas las aserciones y `ROLLBACK`. Documenta también los casos de instalación de la tabla.

| Caso en base desechable | Resultado esperado |
|---|---|
| TCP interactivo con `bash instalar.sh --password 127.0.0.1 autoaudit_pruebas_tcp_final` | Solicitud de contraseña sin eco. Contraseña incorrecta o método distinto de SCRAM produce error. Con la correcta, verifica instalación y repite `09` o `13`. |
| Base con solo `01` completo | Se conserva el modelo y se instalan `03` a `11`. Prepara el caso ejecutando `01` en una base nueva creada por `postgres`. |
| Base con solo `CREATE TABLE public.bitacora (id_bitacora integer)` | Código de error, la tabla queda igual y no aparecen módulos nuevos. |
| Base con `CREATE VIEW public.v_bitacora_detalle AS SELECT 1 AS colision` y sin tablas base | El instalador falla al llegar a `10` por la vista incompatible. Después del error, `to_regclass('public.bitacora')` es nulo y la vista previa sigue presente. |
| Versión de servidor distinta de 18 o nombre `dbname=otra` | Rechazo antes de instalar. |
| Cambio mediante un login TCP real de negocio | Bitácora registra `session_user` y la IP que ve PostgreSQL. La simulación con `SET SESSION AUTHORIZATION` verifica roles, pero no una conexión independiente. |
| Desactivar temporalmente `aa_auditar_fila` en una tabla de prueba | Antes y después de la pausa se registran cambios. Durante la pausa no se generan filas. Registra el cambio de `tgenabled`, la permanencia del historial y la primera operación capturada al reactivar. |

### Regresiones del instalador, las restricciones y el reporte

Ejecuta en el mismo clúster desechable. Usa nombres libres para las cuatro bases nuevas.

```bash
for base in autoaudit_base_final autoaudit_restriccion_final autoaudit_parcial_final autoaudit_rollback_final; do
  "${pg[@]}" -d postgres -c "CREATE DATABASE $base TEMPLATE template0"
done

"${pg[@]}" -d autoaudit_base_final -f sql/01_tablas.sql
"${pg[@]}" -d autoaudit_base_final -c \
  'CREATE TABLE public.otra (i integer CONSTRAINT ck_evento_tipo CHECK (i > 0));'
bash instalar.sh autoaudit_base_final 2>&1 | tee "$evidencia/base-completa.txt"
test "$("${pg[@]}" -d autoaudit_base_final -Atc \
  "SELECT count(*) FROM pg_constraint WHERE conrelid = 'public.evento_auditoria'::regclass AND conname = 'ck_evento_tipo'")" = 1

"${pg[@]}" -d autoaudit_restriccion_final -f sql/01_tablas.sql
"${pg[@]}" -d autoaudit_restriccion_final -c \
  "ALTER TABLE public.evento_auditoria ADD CONSTRAINT ck_evento_tipo CHECK (tipo_evento <> 'PROHIBIDO')"
"${pg[@]}" -d autoaudit_parcial_final -c 'CREATE TABLE public.bitacora (id_bitacora integer)'
"${pg[@]}" -d autoaudit_rollback_final -c 'CREATE VIEW public.v_bitacora_detalle AS SELECT 1 AS colision'
for base in autoaudit_restriccion_final autoaudit_parcial_final autoaudit_rollback_final; do
  if bash instalar.sh "$base" > "$evidencia/$base.txt" 2>&1; then
    printf 'Instalación inesperada en %s\n' "$base" >&2
    exit 1
  fi
done
grep -F 'Restricción incompatible' "$evidencia/autoaudit_restriccion_final.txt"
grep -F 'Estructura base incompleta o incompatible' "$evidencia/autoaudit_parcial_final.txt"
test "$("${pg[@]}" -d autoaudit_rollback_final -Atc \
  "SELECT to_regclass('public.bitacora') IS NULL AND to_regclass('public.v_bitacora_detalle') IS NOT NULL")" = t

"${pg[@]}" -d autoaudit_demo_final 2>&1 <<'SQL' | tee "$evidencia/estado-trigger.txt"
BEGIN;
SET SESSION AUTHORIZATION demo_auditor;
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM public.fn_reporte_estado_triggers()
    WHERE nombre_tabla = 'cliente' AND trigger_instalado AND trigger_habilitado AND modo_trigger = 'O') THEN
    RAISE EXCEPTION 'Se esperaba un trigger habilitado en modo normal';
  END IF;
END $$;
RESET SESSION AUTHORIZATION;
ALTER TABLE public.cliente DISABLE TRIGGER aa_auditar_fila;
SET SESSION AUTHORIZATION demo_auditor;
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM public.fn_reporte_estado_triggers()
    WHERE nombre_tabla = 'cliente' AND trigger_instalado AND NOT trigger_habilitado AND modo_trigger = 'D')
    OR NOT EXISTS (SELECT FROM public.fn_reporte_estado_auditoria()
      WHERE nombre_tabla = 'cliente' AND trigger_instalado) THEN
    RAISE EXCEPTION 'El reporte debe distinguir presencia de habilitación';
  END IF;
END $$;
RESET SESSION AUTHORIZATION;
ROLLBACK;
SQL

# Ejecutar desde una terminal. Introducir la contraseña cuando se solicite.
bash instalar.sh --password 127.0.0.1 autoaudit_pruebas_tcp_final \
  2>&1 | tee "$evidencia/instalacion-tcp.txt"
"${pg[@]}" -d autoaudit_pruebas_tcp_final -f sql/13_pruebas_validacion.sql \
  2>&1 | tee "$evidencia/13-tcp.txt"
```

### Exportación

Continúa en la misma terminal. Estos comandos usan la conexión TCP local de `postgres` y ejecutan el exportador con la autorización de `demo_auditor`. Así `psql` escribe con los permisos del usuario del sistema que creó la carpeta de evidencias.

```bash
export PGCLIENTENCODING=UTF8
tcp=(psql -X -W -h 127.0.0.1 -p "${PGPORT:-5432}" -U postgres -d autoaudit_demo_final)
"${tcp[@]}" -v dir="$evidencia/reportes" \
  -v usuario=demo_supervisor -v tabla=cliente -v columna=limite_credito \
  -c 'SET SESSION AUTHORIZATION demo_auditor' -f sql/12_exportar_reportes.sql \
  2>&1 | tee "$evidencia/12.txt"
"${tcp[@]}" -v dir="$evidencia/vacio" -v desde=1900-01-01 -v hasta=1900-01-02 \
  -c 'SET SESSION AUTHORIZATION demo_auditor' -f sql/12_exportar_reportes.sql \
  2>&1 | tee "$evidencia/12-vacio.txt"

python3 - "$evidencia" <<'PY'
import csv
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])

def leer_csv(nombre):
    with nombre.open(encoding="utf-8", newline="") as archivo:
        lector = csv.DictReader(archivo)
        assert lector.fieldnames, nombre
        return list(lector)

reportes = root / "reportes"
assert {p.name for p in reportes.iterdir()} == {
    "linea_tiempo.csv", "linea_tiempo.json", "resumen_usuarios.csv",
    "resumen_columnas.csv", "actividad_diaria.csv", "estado_auditoria.csv",
    "historial_usuario.csv", "historial_columna.csv",
}
for ruta in reportes.glob("*.csv"):
    assert leer_csv(ruta), ruta
filas = leer_csv(reportes / "linea_tiempo.csv")
datos = json.loads((reportes / "linea_tiempo.json").read_text(encoding="utf-8"))
assert len(filas) == len(datos) == 15
assert [int(f["id_bitacora"]) for f in filas] == [d["id_bitacora"] for d in datos]
assert any(f["tipo_evento"] == "DELETE" and f["valor_anterior"] for f in filas)
assert {f["nombre_usuario"] for f in leer_csv(reportes / "historial_usuario.csv")} == {"demo_supervisor"}
assert {f["nombre_columna"] for f in leer_csv(reportes / "historial_columna.csv")} == {"limite_credito"}
historico = Path("evidencias/reportes_ejemplo/estado_auditoria.csv")
assert (reportes / "estado_auditoria.csv").read_text(encoding="utf-8").splitlines()[0] == (
    historico.read_text(encoding="utf-8").splitlines()[0]
)
assert leer_csv(root / "vacio" / "linea_tiempo.csv") == []
assert json.loads((root / "vacio" / "linea_tiempo.json").read_text(encoding="utf-8")) == []
assert not list((root / "vacio").glob("historial_*.csv"))
print("OK: CSV y JSON coherentes; filtros opcionales y período vacío comprobados")
PY
```

Los casos siguientes deben devolver error. Introduce la contraseña cuando `psql` la solicite.

```bash
esperar_error() {
  local caso=$1 rc
  shift
  if "$@" > "$evidencia/$caso.txt" 2>&1; then
    printf 'Resultado inesperado: %s\n' "$caso" >&2
    return 1
  else
    rc=$?
    printf 'codigo=%s\n' "$rc" >> "$evidencia/$caso.txt"
  fi
}
auditor=("${tcp[@]}" -c 'SET SESSION AUTHORIZATION demo_auditor')
exportar() { "${auditor[@]}" "$@" -f sql/12_exportar_reportes.sql; }
sha256sum "$evidencia/reportes/"* > "$evidencia/reportes.sha256"
esperar_error sobrescritura exportar -v dir="$evidencia/reportes"
sha256sum -c "$evidencia/reportes.sha256"
esperar_error fecha exportar -v dir="$evidencia/fecha" -v desde=no-es-fecha
esperar_error rango exportar -v dir="$evidencia/rango" -v desde=2026-12-01 -v hasta=2026-11-01
esperar_error filtro exportar -v dir="$evidencia/filtro" -v tabla=cliente
esperar_error destino-pipe exportar -v 'dir=|false'
esperar_error destino-relativo exportar -v dir="$evidencia/../escape"
esperar_error padre-inexistente exportar -v dir="$evidencia/ausente/lote"
ln -s reportes "$evidencia/enlace"
esperar_error destino-symlink exportar -v dir="$evidencia/enlace/lote"
esperar_error sin-permiso "${tcp[@]}" -v dir="$evidencia/sin-permiso" \
  -c 'SET SESSION AUTHORIZATION demo_cajero' -f sql/12_exportar_reportes.sql
for caso in fecha rango filtro ausente sin-permiso; do
  test ! -e "$evidencia/$caso"
done
exportar -v dir="$evidencia/ruta con espacios"
test -s "$evidencia/ruta con espacios/linea_tiempo.json"
```

Revisa el diagnóstico de cada caso, pues una contraseña incorrecta también produce un código distinto de cero.

Para probar la instantánea de manera reproducible, el siguiente bloque pausa una copia del flujo de `12` entre el CSV y el JSON. Una segunda sesión confirma un cambio en la base de demostración antes de que se escriba el JSON. Corre este bloque una sola vez en esa base, después de las pruebas anteriores.

```bash
sudo -v
export evidencia
(
  timeout 60 sh -c 'until test -f "$evidencia/csv-listo"; do sleep 0.1; done'
  "${pg[@]}" -d autoaudit_demo_final -c \
    'UPDATE public.cliente SET limite_credito = limite_credito + 1 WHERE id_cliente = 1'
  touch "$evidencia/cambio-confirmado"
) > "$evidencia/concurrente-escritura.txt" 2>&1 &
escritor=$!

{
  while IFS= read -r linea || [[ -n $linea ]]; do
    linea=${linea%$'\r'}
    if [[ $linea == '\o :dir/linea_tiempo.json' ]]; then
      cat <<'PAUSA'
\! touch "$evidencia/csv-listo" && timeout 60 sh -c 'until test -f "$evidencia/cambio-confirmado"; do sleep 0.1; done'
\if :SHELL_ERROR
  DO $$ BEGIN RAISE EXCEPTION 'La segunda sesión no confirmó el cambio a tiempo'; END $$;
\endif
PAUSA
    fi
    printf '%s\n' "$linea"
  done < sql/12_exportar_reportes.sql
} | "${auditor[@]}" -v dir="$evidencia/concurrente" -f - \
  2>&1 | tee "$evidencia/concurrente-exportacion.txt"
wait "$escritor"
test "$("${pg[@]}" -d autoaudit_demo_final -Atc 'SELECT count(*) FROM public.bitacora')" = 16
python3 - "$evidencia/concurrente" <<'PY'
import csv
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
with (root / "linea_tiempo.csv").open(encoding="utf-8", newline="") as handle:
    ids = [int(row["id_bitacora"]) for row in csv.DictReader(handle)]
events = json.loads((root / "linea_tiempo.json").read_text(encoding="utf-8"))
assert len(ids) == 15 and ids == [event["id_bitacora"] for event in events]
print("OK: la escritura concurrente quedó fuera de ambas salidas")
PY
```

## Regresión de la ruta de búsqueda en 05

Ejecuta desde la raíz del proyecto en un clúster de prácticas de PostgreSQL 18.6. Usa nombres de bases libres. El caso específico se revierte por completo, incluidos los roles y el permiso temporal. La prueba `06` se ejecuta aparte porque deja cambios persistentes y contiene errores esperados.

```bash
set -euo pipefail
umask 077
evidencia=$(mktemp -d evidencias/ruta-segura-XXXXXX)
pg=(sudo -u postgres psql -X -v ON_ERROR_STOP=1 -h /var/run/postgresql -p "${PGPORT:-5432}")
test "$("${pg[@]}" -d postgres -Atc 'SHOW server_version_num')" = 180006
bash instalar.sh autoaudit_pruebas_ruta_segura
"${pg[@]}" -d autoaudit_pruebas_ruta_segura <<'SQL' 2>&1 | tee "$evidencia/ruta-segura.txt"
BEGIN;
DO $$
BEGIN
  IF current_database() <> 'autoaudit_pruebas_ruta_segura'
     OR current_setting('server_version_num')::integer <> 180006 THEN
    RAISE EXCEPTION 'Use la base desechable indicada en PostgreSQL 18.6';
  END IF;
END $$;

CREATE ROLE aa_ruta_admin NOLOGIN;
CREATE ROLE aa_ruta_intruso NOLOGIN;
GRANT autoaudit_admin TO aa_ruta_admin;
CREATE TABLE public.aa_ruta_segura (id integer PRIMARY KEY, valor integer NOT NULL);
INSERT INTO public.aa_ruta_segura VALUES (1, 0);

SET SESSION AUTHORIZATION aa_ruta_admin;
DO $$
BEGIN
  IF public.fn_es_admin_auditoria() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'No se reconoció al administrador';
  END IF;
  IF public.fn_configurar_auditoria('aa_ruta_segura', NULL, ARRAY['UPDATE']) <> 2 THEN
    RAISE EXCEPTION 'La selección por diccionario debe incluir id y valor';
  END IF;
  IF public.fn_configurar_auditoria('aa_ruta_segura', ARRAY['valor'], ARRAY['UPDATE']) <> 1 THEN
    RAISE EXCEPTION 'El conteo devuelto al repetir la configuración cambió';
  END IF;
  IF (SELECT count(*) FROM public.v_configuracion_actual WHERE nombre_tabla = 'aa_ruta_segura') <> 2 THEN
    RAISE EXCEPTION 'La configuración repetida duplicó filas o cambió el conteo';
  END IF;
  IF EXISTS (SELECT FROM public.fn_validar_configuracion() WHERE nombre_tabla = 'aa_ruta_segura') THEN
    RAISE EXCEPTION 'La configuración válida se marcó como obsoleta';
  END IF;
  PERFORM * FROM public.fn_autoaudit_regenerar('aa_ruta_segura');
END $$;
RESET SESSION AUTHORIZATION;
UPDATE public.aa_ruta_segura SET valor = 1 WHERE id = 1;

SET SESSION AUTHORIZATION aa_ruta_admin;
SELECT public.fn_cambiar_estado_evento('aa_ruta_segura', 'valor', 'UPDATE', false);
RESET SESSION AUTHORIZATION;
UPDATE public.aa_ruta_segura SET valor = 2 WHERE id = 1;

SET SESSION AUTHORIZATION aa_ruta_admin;
SELECT public.fn_cambiar_estado_evento('aa_ruta_segura', 'valor', 'UPDATE', true);
SELECT * FROM public.fn_autoaudit_regenerar('aa_ruta_segura');
RESET SESSION AUTHORIZATION;
UPDATE public.aa_ruta_segura SET valor = 3 WHERE id = 1;

SET SESSION AUTHORIZATION aa_ruta_admin;
SELECT public.fn_deshabilitar_tabla('aa_ruta_segura');
SELECT * FROM public.fn_autoaudit_regenerar('aa_ruta_segura');
RESET SESSION AUTHORIZATION;
UPDATE public.aa_ruta_segura SET valor = 4 WHERE id = 1;

SET SESSION AUTHORIZATION aa_ruta_intruso;
DO $$
DECLARE
  sentencia text;
BEGIN
  FOREACH sentencia IN ARRAY ARRAY[
    $q$SELECT public.fn_configurar_auditoria('aa_ruta_segura')$q$,
    $q$SELECT public.fn_cambiar_estado_evento('aa_ruta_segura', 'valor', 'UPDATE', true)$q$,
    $q$SELECT public.fn_deshabilitar_tabla('aa_ruta_segura')$q$
  ] LOOP
    BEGIN
      EXECUTE sentencia;
      RAISE EXCEPTION 'Una llamada sin permiso fue aceptada: %', sentencia;
    EXCEPTION WHEN insufficient_privilege THEN
      NULL;
    END;
  END LOOP;
END $$;
RESET SESSION AUTHORIZATION;

-- Exponer únicamente el predicado para probarlo con la ACL de escritura intacta.
GRANT EXECUTE ON FUNCTION public.fn_es_admin_auditoria() TO aa_ruta_intruso;
SET SESSION AUTHORIZATION aa_ruta_intruso;
CREATE TEMP TABLE pg_roles (rolname name, rolsuper boolean);
INSERT INTO pg_temp.pg_roles VALUES (session_user, true);
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_temp.pg_roles WHERE rolname = session_user AND rolsuper)
     OR public.fn_es_admin_auditoria() IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'La relación temporal alteró la comprobación administrativa';
  END IF;
END $$;
RESET SESSION AUTHORIZATION;

DO $$
BEGIN
  IF (SELECT array_agg(valor_nuevo ORDER BY id_bitacora)
        FROM public.v_bitacora_detalle
       WHERE nombre_tabla = 'aa_ruta_segura') IS DISTINCT FROM ARRAY['1','3']::text[]
     OR (SELECT count(*) FROM public.v_configuracion_actual WHERE nombre_tabla = 'aa_ruta_segura') <> 2
     OR EXISTS (SELECT FROM public.v_configuracion_actual WHERE nombre_tabla = 'aa_ruta_segura'
                 AND (activo OR tabla_habilitada)) THEN
    RAISE EXCEPTION 'La pausa, reactivación o deshabilitación alteró la captura esperada';
  END IF;
  RAISE NOTICE 'OK: configuración, activación, desactivación, permisos y tabla temporal';
END $$;
ROLLBACK;
SQL

bash instalar.sh autoaudit_pruebas_config_ruta
"${pg[@]}" -d autoaudit_pruebas_config_ruta -f sql/06_pruebas_configuracion.sql \
  2>&1 | tee "$evidencia/06.txt"
"${pg[@]}" -d autoaudit_pruebas_ruta_segura -f sql/13_pruebas_validacion.sql \
  2>&1 | tee "$evidencia/13.txt"
```

Comprueba el aviso `OK` y `ROLLBACK` en el caso específico. Contrasta cada error deliberado de `06` con el caso que lo anuncia. En `13` verifica el código de salida, las aserciones y `ROLLBACK`.

## Alcance de la verificación de esta revisión

Para `05`, pglast 8.7, con analizador de PostgreSQL 18.6, aceptó las 12 sentencias del archivo y los diez cuerpos por separado (cuatro SQL y seis PL/pgSQL). También aceptó las 36 sentencias y los cinco bloques PL/pgSQL del caso de regresión. Al revertir en memoria solo las sustituciones de ruta y calificación se recuperaron exactamente los bytes originales. El análisis de sintaxis no ejecuta funciones ni verifica la resolución efectiva de objetos, permisos o resultados en un servidor.

Se revisaron los 13 scripts, el enunciado de seis páginas, el PDF técnico, las guías y las evidencias guardadas. Se comprobaron en modo estático el orden y los límites de transacción de los módulos. Se analizaron los siete CSV de ejemplo y se cotejaron los 15 registros de la línea de tiempo campo por campo con su JSON. También se confirmaron los 40 y 49 avisos `OK` en las salidas históricas de `09` y `13`.

Con GNU Bash 5.3 en Windows se comprobaron la sintaxis del instalador y los comandos de la guía, la ayuda del instalador y el rechazo de `dbname=otra`. La revisión estática también comprobó los nombres de archivos, el encabezado de estado y el orden de la transacción de exportación. Se renderizaron las páginas actualizadas del PDF técnico. Queda pendiente ejecutar las pruebas de servidor y cliente en Ubuntu 26.04 LTS con PostgreSQL 18.6. Los resultados históricos corresponden a otra ejecución.
