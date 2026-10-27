### 7. % llamadas al backend de más de 5 s

Estático, ABOVE, umbral 5 %.

Temporal (27/10): el corte pasó de 1 s a 5 s porque disparaba demasiado de madrugada. 5 s es el timeout del
canal, así que avisa cuando el canal ya está fallando. El objetivo acordado es 2 a 3 s sostenidos: para eso hay
que partir el tramo `1-5s` del procesador 5 en `1-3s` y `3-5s` y cambiar este filtro a `in(latency_bucket, array("3-5s", "5s+"))`.

Nota: la alerta actual de latencia suma los pasos del ESB por transacción (p90 de punta a punta). Eso necesita
agrupar por rquid, y una métrica no puede hacerlo. Esta alerta mide la parte del backend; la de punta a punta
puede quedar sobre logs, pero evaluada cada 5 minutos y no cada minuto.
