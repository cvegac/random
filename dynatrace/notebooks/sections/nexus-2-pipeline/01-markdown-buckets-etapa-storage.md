## Buckets (etapa Storage)

| Hecho | Bucket | Condición | Retención sugerida | Para qué |
|---|---|---|---|---|
| [x] | `bck-nexus-error-log` | `matchesValue(nexus.kind, "mapping_error") or matchesValue(nexus.kind, "timeout_504") or matchesValue(nexus.kind, "technical_error") or matchesValue(nexus.kind, "mngr_error") or matchesValue(nexus.kind, "stratus_late_reply") or matchesValue(nexus.kind, "stream_*") or matchesValue(nexus.outcome, "error") or matchesValue(nexus.acceptance, "M")` | larga (ej. 90 días) | detalle de errores: chico, barato de consultar con rangos largos |
| [x] | `logs_integracion` | el resto | la actual (ya existe) | traza por rquid y diagnóstico puntual, siempre con rango corto |

La columna Hecho se marca a mano: `[x]` hecho, `[ ]` pendiente. Los buckets se crean antes en Settings > Storage management. Las queries de errores pasan a filtrar
`dt.system.bucket == "bck-nexus-error-log"` y dejan de escanear el tráfico sano.
