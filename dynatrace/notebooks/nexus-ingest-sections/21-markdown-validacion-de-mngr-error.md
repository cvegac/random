### Validación de `mngr_error`

Un error del mngr es una línea de un log group `*ws-mngr` con el marcador `[ERROR` en mayúsculas: la misma
definición que la alerta `mngr-errors.dql` y el tablero anterior. Correr las cinco consultas con el mismo rango, posterior al último cambio de los procesadores 6 y 7 (la ingesta no reprocesa lo ya guardado).

| Consulta | Resultado esperado | Si no da eso |
|---|---|---|
| 1. logs vs atributo | `missed` = 0, `extra` = 0, `in_errors_bucket` = `truth` | ver 2 o 3 |
| 2. errores no marcados | sin filas | `nexus.kind` = `mngr_trace`: el procesador 6 corrió y el 7 no (condición sin `*` o con `matchesPhrase`). `nexus.kind` vacío con `has_cluster` = true: la línea no tiene `[/` y el 7 tampoco corrió. `has_cluster` = false: la línea no pasó por la ruta del pipeline |
| 3. marcados que no son error | sin filas | `marker_any_case` = true: `[error` en minúsculas, falta el `contains` del script del 7. false: la condición del 7 es otra (`matchesPhrase`) |
| 4. métrica vs logs | `diff_pct` cerca de 0 | condición de la métrica `custom.nexus.log.mngr.errors` o rango anterior a su creación |
| 5. atributos de los errores | `no_rquid` y `no_service` en 0 o casi | `no_rquid` alto en `dt_prefix` = false: falta el script nuevo del procesador 6 |
