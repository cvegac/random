# Nexus · 4. Alertas

Los notebooks de Nexus:
1. Contexto y línea base: cuánto pesa hoy y qué atributos agrega la ingesta.
2. Pipeline: ruta, procesadores, métricas y buckets, cada uno con su prueba.
3. Tablero: las consultas del tablero general sobre métricas y la búsqueda de logs.
4. Alertas: cada alerta con su query, su prueba y la alerta actual para comparar.

## Alertas sobre las métricas de ingesta

Dónde: app Anomaly Detection > Custom alerts > New. Cada alerta es una query `timeseries` sobre las métricas
`custom.nexus.log.*`, un analizador y una plantilla de evento.

Por qué cambiarlas: las alertas de hoy (`dynatrace/alerts/*.dql`) corren `fetch logs` cada minuto; con 30M tx/día
escanean el bucket completo todo el día. Sobre métricas, cada evaluación cuesta lo mismo con cualquier volumen.
Como las queries devuelven una serie por `cluster`, Dynatrace evalúa y alerta cada cluster por separado.

Transición: dejar las alertas actuales activas hasta que la métrica de cada una esté validada (notebook Pipeline, validación); después crear la nueva y apagar la vieja.

| Hecho | Alerta | Métrica | Analizador | Umbral inicial | Reemplaza |
|---|---|---|---|---|---|
| [ ] | % error real del adaptador | `custom.nexus.log.adapter.responses` | estático, ABOVE | 5 % | `adapters-real-error-pct.dql` |
| [ ] | Timeouts 504 | `custom.nexus.log.adapter.timeouts` | estático, ABOVE | 2 por minuto | `adapters-timeouts.dql` |
| [ ] | Errores de mapeo | `custom.nexus.log.adapter.mapping_errors` | estático, ABOVE | 2 por minuto | `adapters-mapping-errors.dql` |
| [ ] | 5xx del backend | `custom.nexus.log.adapter.responses` | estático, ABOVE | 1 por minuto | `adapters-backend-5xx.dql` |
| [ ] | % respuestas M al canal | `custom.nexus.log.mngr.soap_responses` | estático, ABOVE (después, línea base estacional) | 40 % (a calibrar) | `channel-rejection-pct.dql` |
| [ ] | Errores del mngr | `custom.nexus.log.mngr.errors` | auto-adaptativo | | `mngr-errors.dql` |
| [ ] | % llamadas al backend de más de 5 s | `custom.nexus.log.adapter.backend_calls` | estático, ABOVE | 5 % | `mngr-latency-p90.dql` (ver nota) |
| [ ] | Respuestas tardías de Stratus | `custom.nexus.log.adapter.stratus_late_replies` | auto-adaptativo | | nueva |
| [ ] | Consumidor que no coincide (por 100 tx) | `custom.nexus.log.mngr.consumer_mismatch` | auto-adaptativo | | nueva |
| [ ] | Datos incompletos del backend | `custom.nexus.log.adapter.stream_issues` | auto-adaptativo | | nueva |
| [ ] | Caída de tráfico | `custom.nexus.log.adapter.responses` | línea base estacional, BELOW | | nueva |

La columna Hecho se marca a mano: `[x]` hecho, `[ ]` pendiente.

Configuración común, la misma que las alertas actuales: violating samples 3, sliding window 5, dealerting
samples 5, alert on missing data apagado (salvo la caída de tráfico, donde no tener datos es justamente la falla).
Los umbrales de hoy se calibraron para todos los clusters juntos; por cluster pueden necesitar ajuste, sobre todo
en los clusters con poco tráfico. Cada alerta trae el título y la descripción de su plantilla
de evento, listos para pegar; los dos llevan el cluster con `{dims:cluster}` (verificar el formato del placeholder
en el tenant).
Para que lleguen notificaciones hace falta un Workflow que tome estos eventos; hoy no hay ninguno.

Cada alerta va con su query graficada por cluster. Las de umbral fijo traen además "¿habría alertado?": por
cluster, los minutos sobre el umbral y los minutos en que se cumplía 3 de 5 (aproximación: no simula el
dealerting). Las que reemplazan una alerta actual traen la query actual sobre logs, para comparar con el mismo rango.
`interval: 1m` y `default: 0` hacen que los minutos sin datos cuenten como 0 y no como hueco.
