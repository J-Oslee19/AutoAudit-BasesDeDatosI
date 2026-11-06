# Revision previa e integracion de la Parte 3

## Fuentes examinadas antes de programar

PDF original completo (6 paginas), los cinco scripts SQL recibidos,
`LEEME_PARA_TRIGGERS.md` y los tres documentos de docs. Se uso la carpeta ya
disponible, tal como solicito el usuario; no se descomprimio otro proyecto.
No se encontro un tar.gz en la carpeta; no se asumio contenido adicional.

El PDF exige generacion dinamica, AFTER, tabla origen exclusiva por trigger,
valores antiguos/nuevos, usuario, fecha/hora, IP, seguridad e historial persistente.
No obliga a registrar UPDATE sin cambios. No exige crear una FK al registro de
negocio eliminado: la relacion existente es con la configuracion de auditoria.

## Modelo real recibido (todos los objetos en public)

| Tabla | Columnas reales |
|---|---|
| tabla_auditada | id_tabla integer PK identity; nombre_tabla varchar(100); estado boolean |
| columna_auditada | id_columna integer PK identity; nombre_columna varchar(100); id_tabla integer FK |
| evento_auditoria | id_evento integer PK identity; tipo_evento varchar(20) |
| configuracion_auditoria | id_configuracion integer PK identity; id_columna integer FK; id_evento integer FK; activo boolean |
| usuario_auditado | id_usuario integer PK identity; nombre_usuario varchar(100) |
| estacion_trabajo | id_estacion integer PK identity; nombre_estacion varchar(100); direccion_ip varchar(45), nullable |
| bitacora | id_bitacora integer PK identity; id_configuracion/id_usuario/id_estacion integer FK; valor_anterior/valor_nuevo text nullable; fecha_hora timestamp NOT NULL; id_registro text nullable |

Cada PK se llama `<tabla>_pkey`. Las seis FK existentes, sin modificar:

- bitacora_id_configuracion_fkey -> configuracion_auditoria(id_configuracion)
- bitacora_id_usuario_fkey -> usuario_auditado(id_usuario)
- bitacora_id_estacion_fkey -> estacion_trabajo(id_estacion)
- columna_auditada_id_tabla_fkey -> tabla_auditada(id_tabla)
- configuracion_auditoria_id_columna_fkey -> columna_auditada(id_columna)
- configuracion_auditoria_id_evento_fkey -> evento_auditoria(id_evento)

03 agrega UNIQUE uq_tabla_auditada_nombre, uq_columna_auditada_tabla_nombre,
uq_evento_tipo, uq_configuracion_columna_evento y CHECK ck_evento_tipo.
No existen UNIQUE de usuario/estacion en el original. La Parte 3 no los impone
para no fallar ante datos duplicados anteriores ni alterar referencias.

## Contratos de vistas y funciones recibidas

- `v_dic_tablas`: nombre_tabla, num_columnas, auditada, registrada.
- `fn_dic_columnas(p_tabla text)`: orden smallint, nombre_columna text,
  tipo_dato text, permite_nulos boolean, es_pk boolean,
  audita_insert/audita_update/audita_delete boolean.
- `v_configuracion_actual`: nombre_tabla, tabla_habilitada, nombre_columna,
  tipo_evento, activo, id_configuracion.
- `fn_validar_configuracion()` sin argumentos: TABLE(nombre_tabla text,
  nombre_columna text, problema text). Detecta tablas habilitadas ausentes y
  columnas ausentes con configuracion activa.
- `fn_es_tabla_sistema(p_tabla text) -> boolean` excluye las siete tablas internas.
- `fn_es_admin_auditoria() -> boolean`, `fn_exigir_admin() -> void`:
  superusuario o miembro del rol autoaudit_admin segun session_user.
- `fn_existe_tabla(p_tabla text) -> boolean`;
  `fn_existe_columna(p_tabla text,p_columna text) -> boolean`.
- `fn_seleccionar_tabla(p_tabla text) -> integer`: registra o habilita tabla.
- `fn_seleccionar_columna(p_tabla text,p_columna text) -> integer`.
- `fn_configurar_auditoria(p_tabla text,p_columnas text[] DEFAULT NULL,
  p_eventos text[] DEFAULT NULL) -> integer`: activa combinaciones, devuelve
  cantidad procesada; NULL/arreglo vacio significa todas las columnas/eventos.
  No desactiva automaticamente otras combinaciones anteriores.
- `fn_cambiar_estado_evento(p_tabla text,p_columna text,p_evento text,
  p_activo boolean) -> void`: activa o desactiva una combinacion.
- `fn_deshabilitar_tabla(p_tabla text) -> void`: desactiva tabla y eventos,
  conservando registros para referencias historicas.

No se redefinen estas funciones ni las vistas. El generador nuevo llama la
validacion existente y deriva eventos/columnas de la vista real. La verificacion
de permisos nueva usa los mismos criterios con catalogos calificados y un
search_path seguro; no se cambia la funcion de seguridad anterior.

## Hallazgos e impacto

1. Faltaba completamente el registrador y el generador. Se agregan en 07/08.
2. Usuarios/estaciones no tenian altas automaticas. Se resuelven en el trigger
   sin cambios de PK/FK ni eliminacion de duplicados antiguos.
3. Bitacora no tenia proteccion explicita de escritura. 07 agrega REVOKE y guardias;
   protege tambien los dos catalogos para mantener contexto historico.
4. 06 contiene DROP TABLE empleado CASCADE y deja puesto eliminado con configuracion
   activa. Se informa antes de implementar; no se corrige ese archivo. La nueva
   prueba usa otra BD y el generador rechaza configuraciones obsoletas.
5. 01 deja check_function_bodies=off y search_path vacio en su sesion de restauracion.
   Los nuevos scripts establecen localmente comprobacion y rutas seguras y se
   ejecutan en sesiones separadas; no se modifica el dump.
6. El modelo no guarda un campo tipo_evento en bitacora: ya se obtiene via FK.
   No se duplica. Tampoco se agrega una FK al registro de negocio que impediria DELETE.
7. El modelo usa timestamp sin zona: se documenta hora Guatemala para los registros
   nuevos. Los historiales antiguos conservan su valor, sin reinterpretacion.
8. La configuracion admite raices particionadas; el registrador recibe tabla logica
   y OID como argumentos para que los clones nativos lean la configuracion de la
   raiz. Configurar hojas se rechaza para evitar auditoria duplicada.
9. Esquema public y objetos originales deben permanecer bajo propietarios de confianza.
   No se alteraron permisos CREATE del esquema de los companeros. Las funciones
   nuevas no lo incluyen en su search_path.

Los puntos anteriores no requirieron corregir ni solicitar cambios sobre archivos
originales. Aplicar los SQL a una BD real es una accion futura del instalador; en
esta entrega no se conecto ni modifico ninguna base de datos.
